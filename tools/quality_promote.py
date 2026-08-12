#!/usr/bin/env python3
"""Promote exact successful pull-request evidence to a merged main commit."""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from typing import Any, NoReturn

from quality_policy import POLICY_FILE, Policy


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "app/build/quality-gates"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SUMMARY_HEADER = (
    "policy\tmode\tstage\tstatus\tduration_seconds\tlog\tlog_sha256\torigin_run"
)
PROMOTION_FIELDS = (
    "schema",
    "authority",
    "result",
    "repository",
    "main_commit",
    "main_tree",
    "base_commit",
    "head_commit",
    "tested_commit",
    "tested_tree",
    "pull_request",
    "merged_at",
    "source_run",
    "source_run_attempt",
    "source_run_url",
    "source_artifact",
    "source_manifest_sha256",
)
PROMOTION_KEYS = set(PROMOTION_FIELDS)
PR_ASSOCIATION_ATTEMPTS = 4
PR_ASSOCIATION_RETRY_SECONDS = 2.0


class PromotionError(Exception):
    """Evidence cannot be promoted without weakening provenance."""


def fail(message: str) -> NoReturn:
    print(f"quality-promote: {message}", file=sys.stderr)
    raise SystemExit(2)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_file(path: Path, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        raise PromotionError(f"{label} is missing or unsafe")
    return path


def safe_relative_file(root: Path, relative: str, label: str) -> Path:
    value = Path(relative)
    if value.is_absolute() or ".." in value.parts or not relative:
        raise PromotionError(f"{label} path is unsafe")
    path = safe_file(root / value, label)
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError as error:
        raise PromotionError(f"{label} path escapes its evidence root") from error
    return path


def read_tsv(path: Path, label: str) -> dict[str, str]:
    safe_file(path, label)
    values: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 2 or not fields[0] or fields[0] in values:
            raise PromotionError(f"{label} has a malformed record at line {number}")
        values[fields[0]] = fields[1]
    return values


def parse_json(raw: str, label: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise PromotionError(f"{label} response is malformed: {error}") from error


def command(executable: str, arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            [executable, *arguments],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise PromotionError(f"cannot start {executable}: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise PromotionError(f"{Path(executable).name} failed: {detail}")
    return result.stdout


def git_info(executable: str, commit: str) -> tuple[str, str, list[str]]:
    lines = command(
        executable,
        ["show", "-s", "--format=%H%n%T%n%P", f"{commit}^{{commit}}"],
    ).splitlines()
    if (
        len(lines) != 3
        or not COMMIT.fullmatch(lines[0])
        or not COMMIT.fullmatch(lines[1])
    ):
        raise PromotionError("main commit metadata is malformed")
    parents = lines[2].split()
    if any(not COMMIT.fullmatch(parent) for parent in parents):
        raise PromotionError("main commit parents are malformed")
    return lines[0], lines[1], parents


def gh(executable: str, path: str) -> Any:
    return parse_json(command(executable, ["api", path]), "GitHub API")


def merged_pull_request(
    executable: str, repository: str, main_commit: str, parents: list[str]
) -> dict[str, Any]:
    retry_seconds = PR_ASSOCIATION_RETRY_SECONDS
    if os.environ.get("DETACH_QUALITY_PROMOTE_TEST_MODE") == "1":
        retry_seconds = float(os.environ.get(
            "DETACH_QUALITY_PROMOTE_RETRY_SECONDS", "0"
        ))
        if retry_seconds < 0:
            raise PromotionError("promotion retry interval must be non-negative")
    for attempt in range(1, PR_ASSOCIATION_ATTEMPTS + 1):
        records = gh(executable, f"repos/{repository}/commits/{main_commit}/pulls")
        if not isinstance(records, list):
            raise PromotionError("associated pull-request response is malformed")
        matches = [
            record
            for record in records
            if isinstance(record, dict)
            and record.get("state") == "closed"
            and record.get("merge_commit_sha") == main_commit
            and isinstance(record.get("merged_at"), str)
            and isinstance(record.get("base"), dict)
            and isinstance(record.get("head"), dict)
            and record["base"].get("sha") == parents[0]
            and record["head"].get("sha") == parents[1]
        ]
        if len(matches) == 1 and isinstance(matches[0].get("number"), int):
            return matches[0]
        if attempt < PR_ASSOCIATION_ATTEMPTS:
            time.sleep(retry_seconds)
    raise PromotionError("main commit has no unique exact merged pull request")


def successful_run(
    executable: str, repository: str, head_commit: str, merged_at: str
) -> tuple[int, int, str]:
    response = gh(
        executable,
        f"repos/{repository}/actions/workflows/quality-gates.yml/runs"
        f"?event=pull_request&status=success&head_sha={head_commit}&per_page=20",
    )
    if not isinstance(response, dict) or not isinstance(response.get("workflow_runs"), list):
        raise PromotionError("quality workflow response is malformed")
    candidates: list[tuple[str, int, int, str]] = []
    for run in response["workflow_runs"]:
        if not isinstance(run, dict):
            continue
        run_id = run.get("id")
        attempt = run.get("run_attempt")
        updated_at = run.get("updated_at")
        url = run.get("html_url")
        if (
            isinstance(run_id, int)
            and run_id > 0
            and isinstance(attempt, int)
            and attempt > 0
            and run.get("event") == "pull_request"
            and run.get("conclusion") == "success"
            and run.get("head_sha") == head_commit
            and isinstance(updated_at, str)
            and updated_at <= merged_at
            and isinstance(url, str)
        ):
            candidates.append((updated_at, run_id, attempt, url))
    if not candidates:
        raise PromotionError("no successful pre-merge pull-request run is available")
    _, run_id, attempt, url = max(candidates)
    return run_id, attempt, url


def artifact_name(executable: str, repository: str, run_id: int, attempt: int) -> str:
    response = gh(executable, f"repos/{repository}/actions/runs/{run_id}/artifacts")
    if not isinstance(response, dict) or not isinstance(response.get("artifacts"), list):
        raise PromotionError("quality artifact response is malformed")
    expected = f"quality-gate-evidence-{run_id}-{attempt}"
    matches = [
        artifact.get("name")
        for artifact in response["artifacts"]
        if isinstance(artifact, dict)
        and artifact.get("name") == expected
        and artifact.get("expired") is False
    ]
    if matches != [expected]:
        raise PromotionError("pull-request run has no unique exact evidence artifact")
    return expected


def artifact_inventory(run_dir: Path, manifest: dict[str, str]) -> dict[str, str]:
    inventory = safe_file(run_dir / "artifacts.tsv", "artifact inventory")
    if sha256(inventory) != manifest.get("artifacts_sha256"):
        raise PromotionError("artifact inventory digest does not match the manifest")
    lines = inventory.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "schema\t1":
        raise PromotionError("artifact inventory schema is invalid")
    values: dict[str, str] = {}
    for line in lines[1:]:
        fields = line.split("\t")
        if (
            len(fields) != 3
            or fields[0] != "file"
            or not fields[1]
            or fields[1] in values
            or not DIGEST.fullmatch(fields[2])
        ):
            raise PromotionError("artifact inventory contains an invalid record")
        artifact = safe_relative_file(run_dir, fields[1], "evidence artifact")
        if sha256(artifact) != fields[2]:
            raise PromotionError(f"evidence artifact digest does not match: {fields[1]}")
        values[fields[1]] = fields[2]
    for required in ("quality-metrics.json", "scenarios.jsonl", "scenarios.junit.xml"):
        if required not in values:
            raise PromotionError(f"required evidence artifact is missing: {required}")
    return values


def validate_summary(run_dir: Path, manifest: dict[str, str], policy: Policy) -> None:
    summary = safe_file(run_dir / "summary.tsv", "quality summary")
    if sha256(summary) != manifest.get("summary_sha256"):
        raise PromotionError("quality summary digest does not match the manifest")
    lines = summary.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != SUMMARY_HEADER:
        raise PromotionError("quality summary schema is invalid")
    expected_stages = [stage.name for stage in policy.stages if stage.name != "release-budget"]
    seen: list[str] = []
    for line in lines[1:]:
        fields = line.split("\t")
        if (
            len(fields) != 8
            or fields[0] != str(policy.version)
            or fields[1] != "repository"
            or fields[3] != "passed"
            or not fields[4].isdigit()
            or not DIGEST.fullmatch(fields[6])
            or fields[7] != "-"
        ):
            raise PromotionError("quality summary contains non-passing or malformed evidence")
        log = safe_relative_file(run_dir, fields[5], "stage log")
        if sha256(log) != fields[6]:
            raise PromotionError(f"stage log digest does not match: {fields[2]}")
        seen.append(fields[2])
    if seen != expected_stages:
        raise PromotionError("quality summary is not the complete repository plan")


def validate_evidence(
    run_dir: Path, policy: Policy, base_commit: str
) -> tuple[dict[str, str], str]:
    manifest_path = safe_file(run_dir / "manifest.tsv", "quality manifest")
    manifest = read_tsv(manifest_path, "quality manifest")
    expected = {
        "schema": "4",
        "policy": str(policy.version),
        "mode": "repository",
        "authority": "ci-merge",
        "result": "passed",
        "base_commit": base_commit,
        "stages": ",".join(
            stage.name for stage in policy.stages if stage.name != "release-budget"
        ),
        "specs": ",".join(policy.specs),
        "capabilities": ",".join(policy.capabilities),
        "journeys": ",".join(policy.journeys),
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise PromotionError(f"quality manifest {key} is not exact")
    tested_commit = manifest.get("source_commit", "")
    if not COMMIT.fullmatch(tested_commit):
        raise PromotionError("tested source commit is invalid")
    for name in ("environment", "artifacts", "summary"):
        evidence = safe_file(run_dir / f"{name}.tsv", f"{name} evidence")
        if sha256(evidence) != manifest.get(f"{name}_sha256"):
            raise PromotionError(f"{name} evidence digest does not match the manifest")
    validate_summary(run_dir, manifest, policy)
    artifact_inventory(run_dir, manifest)
    from quality_metrics import read_json, validate_metrics

    metrics = validate_metrics(
        read_json(run_dir / "quality-metrics.json", "quality metrics"),
        expected_policy=policy.version,
    )
    if metrics["source_commit"] != tested_commit or metrics["comparison"]["status"] != "passed":
        raise PromotionError("quality metrics are not passing evidence for the tested commit")
    return manifest, sha256(manifest_path)


def github_commit(
    executable: str, repository: str, commit: str
) -> tuple[str, list[str]]:
    value = gh(executable, f"repos/{repository}/git/commits/{commit}")
    if not isinstance(value, dict) or value.get("sha") != commit:
        raise PromotionError("tested commit response is malformed")
    tree = value.get("tree")
    parents = value.get("parents")
    if (
        not isinstance(tree, dict)
        or not COMMIT.fullmatch(tree.get("sha", ""))
        or not isinstance(parents, list)
        or any(not isinstance(parent, dict) for parent in parents)
    ):
        raise PromotionError("tested commit provenance is malformed")
    parent_ids = [parent.get("sha", "") for parent in parents]
    if any(not COMMIT.fullmatch(parent) for parent in parent_ids):
        raise PromotionError("tested commit parents are malformed")
    return tree["sha"], parent_ids


def write_promotion(run_dir: Path, values: dict[str, str]) -> None:
    target = run_dir / "promotion.tsv"
    temporary = run_dir / f".promotion.{os.getpid()}"
    temporary.write_text(
        "".join(f"{key}\t{values[key]}\n" for key in PROMOTION_FIELDS),
        encoding="utf-8",
    )
    temporary.chmod(0o600)
    os.replace(temporary, target)
    markdown = run_dir / "promotion.md"
    markdown.write_text(
        "\n".join(
            (
                "# Promoted main evidence",
                "",
                f"- Main commit: `{values['main_commit']}`",
                f"- Tested merge commit: `{values['tested_commit']}`",
                f"- Pull request: `{values['pull_request']}`",
                f"- Source run: [{values['source_run']}]({values['source_run_url']})",
                "- Proof: the tested and merged commits have the same tree and parents.",
                "",
            )
        ),
        encoding="utf-8",
    )
    markdown.chmod(0o600)


def validate_promotion(run_dir: Path, manifest: dict[str, str]) -> dict[str, str] | None:
    path = run_dir / "promotion.tsv"
    if not path.exists():
        return None
    values = read_tsv(path, "promotion evidence")
    if set(values) != PROMOTION_KEYS:
        raise PromotionError("promotion evidence fields are malformed")
    for key in (
        "main_commit", "main_tree", "base_commit", "head_commit",
        "tested_commit", "tested_tree",
    ):
        if not COMMIT.fullmatch(values[key]):
            raise PromotionError(f"promotion {key} is invalid")
    if (
        values["schema"] != "1"
        or values["authority"] != "ci-main"
        or values["result"] != "passed"
        or not REPOSITORY.fullmatch(values["repository"])
        or not values["pull_request"].isdigit()
        or int(values["pull_request"]) <= 0
        or not values["source_run"].isdigit()
        or int(values["source_run"]) <= 0
        or not values["source_run_attempt"].isdigit()
        or int(values["source_run_attempt"]) <= 0
        or values["main_tree"] != values["tested_tree"]
        or values["tested_commit"] != manifest.get("source_commit")
        or values["base_commit"] != manifest.get("base_commit")
        or manifest.get("authority") != "ci-merge"
        or manifest.get("result") != "passed"
        or not DIGEST.fullmatch(values["source_manifest_sha256"])
        or sha256(run_dir / "manifest.tsv") != values["source_manifest_sha256"]
    ):
        raise PromotionError("promotion evidence does not bind the tested manifest")
    expected_artifact = (
        f"quality-gate-evidence-{values['source_run']}-{values['source_run_attempt']}"
    )
    expected_url = (
        f"https://github.com/{values['repository']}/actions/runs/{values['source_run']}"
    )
    if values["source_artifact"] != expected_artifact or values["source_run_url"] != expected_url:
        raise PromotionError("promotion source run identity is inconsistent")
    try:
        datetime.fromisoformat(values["merged_at"].replace("Z", "+00:00"))
    except ValueError as error:
        raise PromotionError("promotion merge timestamp is invalid") from error
    return values


def promote(
    repository: str,
    main_commit: str,
    output_root: Path,
    gh_executable: str,
    git_executable: str,
) -> Path:
    if not REPOSITORY.fullmatch(repository):
        raise PromotionError("repository must identify owner/repository")
    resolved, main_tree, parents = git_info(git_executable, main_commit)
    if resolved != main_commit or len(parents) != 2:
        raise PromotionError("main commit is not an exact two-parent merge")
    pull_request = merged_pull_request(gh_executable, repository, main_commit, parents)
    merged_at = pull_request["merged_at"]
    run_id, attempt, run_url = successful_run(
        gh_executable, repository, parents[1], merged_at
    )
    artifact = artifact_name(gh_executable, repository, run_id, attempt)
    if output_root.exists():
        raise PromotionError("promotion output already exists")
    output_root.mkdir(parents=True)
    try:
        command(
            gh_executable,
            [
                "run", "download", str(run_id), "--repo", repository,
                "--name", artifact, "--dir", str(output_root),
            ],
        )
        manifests = [
            path
            for path in output_root.glob("*/manifest.tsv")
            if path.is_file() and not path.is_symlink()
        ]
        if len(manifests) != 1:
            raise PromotionError("downloaded evidence has no unique quality manifest")
        run_dir = manifests[0].parent
        if (
            not run_dir.is_dir()
            or run_dir.is_symlink()
            or run_dir.resolve().parent != output_root.resolve()
        ):
            raise PromotionError("downloaded evidence run directory is unsafe")
        policy = Policy(POLICY_FILE)
        manifest, manifest_digest = validate_evidence(run_dir, policy, parents[0])
        tested_commit = manifest["source_commit"]
        tested_tree, tested_parents = github_commit(
            gh_executable, repository, tested_commit
        )
        if tested_tree != main_tree or tested_parents != parents:
            raise PromotionError("tested merge and main do not have the same tree and parents")
        values = {
            "schema": "1",
            "authority": "ci-main",
            "result": "passed",
            "repository": repository,
            "main_commit": main_commit,
            "main_tree": main_tree,
            "base_commit": parents[0],
            "head_commit": parents[1],
            "tested_commit": tested_commit,
            "tested_tree": tested_tree,
            "pull_request": str(pull_request["number"]),
            "merged_at": merged_at,
            "source_run": str(run_id),
            "source_run_attempt": str(attempt),
            "source_run_url": run_url,
            "source_artifact": artifact,
            "source_manifest_sha256": manifest_digest,
        }
        write_promotion(run_dir, values)
        validate_promotion(run_dir, manifest)
        return output_root
    except Exception:
        shutil.rmtree(output_root, ignore_errors=True)
        raise


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    result.add_argument("--commit", default=os.environ.get("GITHUB_SHA", ""))
    result.add_argument(
        "--output-root",
        type=Path,
        default=Path(os.environ.get("DETACH_QUALITY_PROMOTE_OUTPUT", DEFAULT_OUTPUT)),
    )
    return result


def main() -> int:
    arguments = parser().parse_args()
    test_mode = os.environ.get("DETACH_QUALITY_PROMOTE_TEST_MODE") == "1"
    if not test_mode:
        if (
            os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("GITHUB_EVENT_NAME") != "push"
            or os.environ.get("GITHUB_REF") != "refs/heads/main"
        ):
            raise PromotionError("promotion is restricted to a GitHub main push")
        if arguments.output_root.resolve() != DEFAULT_OUTPUT.resolve():
            raise PromotionError("promotion output must use app/build/quality-gates")
    gh_executable = os.environ.get("DETACH_QUALITY_PROMOTE_GH", "gh") if test_mode else "gh"
    git_executable = (
        os.environ.get("DETACH_QUALITY_PROMOTE_GIT", "git") if test_mode else "git"
    )
    if not COMMIT.fullmatch(arguments.commit):
        raise PromotionError("main commit is invalid")
    output = promote(
        arguments.repository,
        arguments.commit,
        arguments.output_root,
        gh_executable,
        git_executable,
    )
    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PromotionError, OSError, UnicodeError) as error:
        fail(str(error))
