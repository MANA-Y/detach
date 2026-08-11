#!/usr/bin/env python3
"""Restore the last successful main quality artifact through GitHub CLI."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, NoReturn


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "app/build/quality-baseline"
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class BaselineError(Exception):
    """Missing, malformed, or unsafe remote baseline evidence."""


def fail(message: str) -> NoReturn:
    print(f"quality-baseline: {message}", file=sys.stderr)
    raise SystemExit(2)


def gh(executable: str, arguments: list[str]) -> str:
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
        raise BaselineError(f"cannot start gh: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise BaselineError(f"gh failed: {detail}")
    return result.stdout


def document(raw: str, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise BaselineError(f"{label} response is malformed: {error}") from error
    if not isinstance(value, dict):
        raise BaselineError(f"{label} response is malformed")
    return value


def successful_run(value: dict[str, Any]) -> int:
    runs = value.get("workflow_runs")
    if not isinstance(runs, list) or not runs:
        raise BaselineError("no successful main quality run is available")
    first = runs[0]
    if not isinstance(first, dict) or not isinstance(first.get("id"), int) or first["id"] <= 0:
        raise BaselineError("successful main quality run id is invalid")
    return first["id"]


def evidence_artifact(value: dict[str, Any], run_id: int) -> str:
    artifacts = value.get("artifacts")
    if not isinstance(artifacts, list):
        raise BaselineError("quality artifact response is malformed")
    matches: list[str] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise BaselineError("quality artifact record is malformed")
        name = artifact.get("name")
        expired = artifact.get("expired")
        if not isinstance(name, str) or not isinstance(expired, bool):
            raise BaselineError("quality artifact record is malformed")
        if not expired and name.startswith("quality-gate-evidence-"):
            matches.append(name)
    if len(matches) != 1:
        raise BaselineError(f"main quality run {run_id} has no unique evidence artifact")
    return matches[0]


def restore(
    repository: str, output_root: Path, executable: str, *, test_mode: bool
) -> Path:
    if not REPOSITORY.fullmatch(repository):
        raise BaselineError("repository must identify owner/repository")
    if not test_mode and output_root.resolve() != DEFAULT_OUTPUT.resolve():
        raise BaselineError("baseline output must use app/build/quality-baseline")
    if output_root.exists() and (not output_root.is_dir() or output_root.is_symlink()):
        raise BaselineError("baseline output is unsafe")
    output_root.mkdir(parents=True, exist_ok=True)
    run_id = successful_run(document(
        gh(
            executable,
            [
                "api",
                f"repos/{repository}/actions/workflows/quality-gates.yml/runs"
                "?branch=main&status=success&event=push&per_page=1",
            ],
        ),
        "workflow run",
    ))
    artifact = evidence_artifact(document(
        gh(executable, ["api", f"repos/{repository}/actions/runs/{run_id}/artifacts"]),
        "artifact",
    ), run_id)
    destination = output_root / str(run_id)
    if destination.exists():
        raise BaselineError(f"baseline destination already exists: {destination}")
    destination.mkdir()
    gh(
        executable,
        [
            "run", "download", str(run_id), "--repo", repository, "--name", artifact,
            "--dir", str(destination),
        ],
    )
    manifests = [
        path for path in destination.glob("*/manifest.tsv")
        if path.is_file() and not path.is_symlink()
    ]
    if len(manifests) != 1:
        raise BaselineError("downloaded evidence has no unique quality manifest")
    print(destination)
    return destination


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "--repository",
        default=os.environ.get("DETACH_QUALITY_REPOSITORY", os.environ.get("GITHUB_REPOSITORY", "")),
    )
    result.add_argument(
        "--output-root",
        type=Path,
        default=Path(os.environ.get("DETACH_QUALITY_BASELINE_OUTPUT", DEFAULT_OUTPUT)),
    )
    return result


def main() -> int:
    arguments = parser().parse_args()
    test_mode = os.environ.get("DETACH_QUALITY_BASELINE_TEST_MODE") == "1"
    executable = (
        os.environ.get("DETACH_QUALITY_BASELINE_GH", "gh") if test_mode else "gh"
    )
    restore(
        arguments.repository,
        arguments.output_root,
        executable,
        test_mode=test_mode,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BaselineError, OSError) as error:
        fail(str(error))
