#!/usr/bin/env python3
"""Create, validate, and restore bounded CodeQL result evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, NoReturn

from quality_policy import POLICY_FILE, Policy, PolicyError


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BASELINE = ROOT / "app/build/quality-security-baseline"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
RUN_URL = re.compile(
    r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[1-9][0-9]*$"
)
JOB_RESULTS = {"success", "failure", "cancelled", "skipped"}
RESULT_STATUS = {
    "success": "passed",
    "failure": "failed",
    "cancelled": "cancelled",
    "skipped": "skipped",
}
LATEST_RUN_LIMIT = 5
GH_TIMEOUT_SECONDS = 20
LATEST_DEADLINE_SECONDS = 60


class SecurityError(Exception):
    """Security result evidence is invalid or unavailable."""


def fail(message: str) -> NoReturn:
    print(f"quality-security: {message}", file=sys.stderr)
    raise SystemExit(2)


def positive_integer(value: Any) -> bool:
    return type(value) is int and value > 0


def evidence_fingerprint(value: dict[str, Any]) -> str:
    identity = {
        key: value[key]
        for key in (
            "schema", "policy", "source_commit", "run_id", "run_attempt",
            "run_url", "status", "jobs"
        )
    }
    payload = json.dumps(
        identity, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def create_summary(
    policy: Policy,
    source_commit: str,
    run_id: int,
    run_attempt: int,
    run_url: str,
    actions_result: str,
    swift_result: str,
) -> dict[str, Any]:
    jobs = {
        "actions": RESULT_STATUS.get(actions_result),
        "swift": RESULT_STATUS.get(swift_result),
    }
    if (
        not COMMIT.fullmatch(source_commit)
        or not positive_integer(run_id)
        or not positive_integer(run_attempt)
        or not RUN_URL.fullmatch(run_url)
        or actions_result not in JOB_RESULTS
        or swift_result not in JOB_RESULTS
    ):
        raise SecurityError("security result identity is invalid")
    summary = {
        "schema": 1,
        "policy": policy.version,
        "source_commit": source_commit,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "run_url": run_url,
        "status": "passed" if set(jobs.values()) == {"passed"} else "failed",
        "jobs": jobs,
    }
    summary["fingerprint"] = evidence_fingerprint(summary)
    return summary


def validate_summary(value: Any, expected_policy: int) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "schema", "policy", "source_commit", "run_id", "run_attempt",
        "run_url", "status", "jobs", "fingerprint"
    }:
        raise SecurityError("security summary schema is invalid")
    jobs = value["jobs"]
    if (
        value["schema"] != 1
        or value["policy"] != expected_policy
        or not isinstance(value["source_commit"], str)
        or not COMMIT.fullmatch(value["source_commit"])
        or not positive_integer(value["run_id"])
        or not positive_integer(value["run_attempt"])
        or not isinstance(value["run_url"], str)
        or not RUN_URL.fullmatch(value["run_url"])
        or value["run_url"].rsplit("/", 1)[-1] != str(value["run_id"])
        or value["status"] not in ("passed", "failed")
        or not isinstance(value["fingerprint"], str)
        or not re.fullmatch(r"[0-9a-f]{64}", value["fingerprint"])
        or not isinstance(jobs, dict)
        or set(jobs) != {"actions", "swift"}
        or any(result not in RESULT_STATUS.values() for result in jobs.values())
    ):
        raise SecurityError("security summary identity is invalid")
    expected_status = "passed" if set(jobs.values()) == {"passed"} else "failed"
    if value["status"] != expected_status:
        raise SecurityError("security summary status is inconsistent")
    if value["fingerprint"] != evidence_fingerprint(value):
        raise SecurityError("security summary fingerprint is invalid")
    return value


def read_summary(path: Path, expected_policy: int) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise SecurityError(f"security summary is missing or unsafe: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeError, OSError) as error:
        raise SecurityError(f"security summary is invalid: {error}") from error
    return validate_summary(value, expected_policy)


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    if path.exists() and path.is_symlink():
        raise SecurityError(f"output target is a symlink: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def gh_output(executable: str, arguments: list[str], deadline: float) -> str:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise SecurityError(
            f"security restore exceeded its {LATEST_DEADLINE_SECONDS}-second deadline"
        )
    try:
        result = subprocess.run(
            [executable, *arguments],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=min(GH_TIMEOUT_SECONDS, remaining),
        )
    except subprocess.TimeoutExpired as error:
        raise SecurityError(
            "gh did not finish before the bounded security restore deadline"
        ) from error
    except OSError as error:
        raise SecurityError(f"cannot start gh: {error}") from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise SecurityError(f"gh failed: {detail}")
    return result.stdout.strip()


def latest_summary(
    repository: str,
    output_root: Path,
    optional: bool,
    policy: Policy,
    test_mode: bool,
) -> Path | None:
    if not REPOSITORY.fullmatch(repository):
        if optional and not repository:
            return None
        raise SecurityError("repository must identify owner/repository")
    if not test_mode and output_root.resolve() != DEFAULT_BASELINE.resolve():
        raise SecurityError(
            "security baseline output must use app/build/quality-security-baseline"
        )
    if output_root.exists() and (not output_root.is_dir() or output_root.is_symlink()):
        raise SecurityError("security baseline output is unsafe")
    output_root.mkdir(parents=True, exist_ok=True)
    executable = os.environ.get("DETACH_QUALITY_SECURITY_GH", "gh") if test_mode else "gh"
    deadline_seconds = LATEST_DEADLINE_SECONDS
    if test_mode and os.environ.get("DETACH_QUALITY_SECURITY_LATEST_SECONDS"):
        raw_deadline = os.environ["DETACH_QUALITY_SECURITY_LATEST_SECONDS"]
        if not raw_deadline.isdigit() or int(raw_deadline) < 1:
            raise SecurityError("test security restore deadline must be a positive integer")
        deadline_seconds = int(raw_deadline)
    deadline = time.monotonic() + deadline_seconds
    run_output = gh_output(
        executable,
        [
            "api",
            f"repos/{repository}/actions/workflows/security.yml/runs"
            f"?branch=main&status=completed&per_page={LATEST_RUN_LIMIT}",
            "--jq",
            ".workflow_runs[].id",
        ],
        deadline,
    )
    run_ids = run_output.splitlines()
    if not run_ids:
        if optional:
            return None
        raise SecurityError("no completed main security run is available")
    if len(run_ids) > LATEST_RUN_LIMIT or any(
        not re.fullmatch(r"[1-9][0-9]*", run_id) for run_id in run_ids
    ):
        raise SecurityError("security run list is invalid")
    for run_id in run_ids:
        artifact_name = gh_output(
            executable,
            [
                "api",
                f"repos/{repository}/actions/runs/{run_id}/artifacts",
                "--jq",
                ".artifacts | map(select(.expired == false and "
                "(.name | startswith(\"quality-security-\")))) | "
                "if length == 0 then \"missing\" elif length == 1 then "
                ".[0].name else \"ambiguous\" end",
            ],
            deadline,
        )
        if artifact_name == "missing":
            continue
        if (
            artifact_name == "ambiguous"
            or not re.fullmatch(rf"quality-security-{run_id}-[1-9][0-9]*", artifact_name)
        ):
            raise SecurityError(f"security run {run_id} has ambiguous artifacts")
        destination = output_root / run_id
        if destination.exists():
            raise SecurityError(f"security baseline destination already exists: {destination}")
        destination.mkdir()
        gh_output(
            executable,
            [
                "run", "download", run_id, "--repo", repository,
                "--name", artifact_name, "--dir", str(destination),
            ],
            deadline,
        )
        candidates = [
            path for path in destination.rglob("summary.json")
            if path.is_file() and not path.is_symlink()
        ]
        if len(candidates) != 1:
            raise SecurityError("downloaded security evidence has no unique summary")
        try:
            value = json.loads(candidates[0].read_text(encoding="utf-8"))
        except (json.JSONDecodeError, UnicodeError, OSError) as error:
            raise SecurityError(f"security summary is invalid: {error}") from error
        if isinstance(value, dict) and value.get("policy") != policy.version:
            continue
        validate_summary(value, policy.version)
        print(candidates[0])
        return candidates[0]
    if optional:
        return None
    raise SecurityError(
        f"no valid policy {policy.version} security artifact exists in the latest "
        f"{LATEST_RUN_LIMIT} completed runs"
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="scripts/quality-security")
    commands = result.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("--source-commit", required=True)
    create.add_argument("--run-id", required=True, type=int)
    create.add_argument("--run-attempt", required=True, type=int)
    create.add_argument("--run-url", required=True)
    create.add_argument("--actions-result", required=True)
    create.add_argument("--swift-result", required=True)
    create.add_argument("--output", required=True, type=Path)
    validate = commands.add_parser("validate")
    validate.add_argument("summary", type=Path)
    validate.add_argument("--require-pass", action="store_true")
    latest = commands.add_parser("latest")
    latest.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    latest.add_argument("--output-root", type=Path, default=DEFAULT_BASELINE)
    latest.add_argument("--optional", action="store_true")
    return result


def main() -> int:
    arguments = parser().parse_args()
    policy = Policy(POLICY_FILE)
    if arguments.command == "create":
        summary = create_summary(
            policy,
            arguments.source_commit,
            arguments.run_id,
            arguments.run_attempt,
            arguments.run_url,
            arguments.actions_result,
            arguments.swift_result,
        )
        validate_summary(summary, policy.version)
        atomic_write(arguments.output.resolve(), summary)
        print(
            f"quality-security: {summary['status']} policy={policy.version} "
            f"run={summary['run_id']}"
        )
        return 0
    if arguments.command == "validate":
        summary = read_summary(arguments.summary.resolve(), policy.version)
        print(
            f"quality-security: {summary['status']} policy={policy.version} "
            f"run={summary['run_id']}"
        )
        return 1 if arguments.require_pass and summary["status"] != "passed" else 0
    latest_summary(
        arguments.repository,
        arguments.output_root,
        arguments.optional,
        policy,
        os.environ.get("DETACH_QUALITY_SECURITY_TEST_MODE") == "1",
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PolicyError, SecurityError) as error:
        fail(str(error))
