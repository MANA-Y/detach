#!/usr/bin/env python3
"""Contract tests for hosted quality baseline restoration."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
from typing import Optional


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/quality-baseline"


def invoke(
    fake_gh: Path,
    output_root: Path,
    *,
    mode: str = "success",
    expected: int = 0,
    test_mode: bool = True,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["DETACH_QUALITY_BASELINE_GH"] = str(fake_gh)
    environment["FAKE_GH_MODE"] = mode
    if test_mode:
        environment["DETACH_QUALITY_BASELINE_TEST_MODE"] = "1"
    else:
        environment.pop("DETACH_QUALITY_BASELINE_TEST_MODE", None)
    result = subprocess.run(
        [
            str(SCRIPT), "--repository", "owner/repository",
            "--output-root", str(output_root),
        ],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"unexpected exit {result.returncode}, expected {expected}\n{result.stdout}")
    return result


def require(result: subprocess.CompletedProcess[str], value: str) -> None:
    if value not in result.stdout:
        raise AssertionError(f"missing diagnostic {value!r}:\n{result.stdout}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="detach-quality-baseline-") as raw:
        root = Path(raw)
        fake_gh = root / "fake-gh"
        fake_gh.write_text(
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
arguments = sys.argv[1:]
mode = os.environ.get("FAKE_GH_MODE", "success")
if arguments[0] == "api" and "workflows/quality-gates.yml/runs" in arguments[1]:
    if mode == "malformed": print("{")
    elif mode == "no-runs": print(json.dumps({"workflow_runs": []}))
    else: print(json.dumps({"workflow_runs": [{"id": 123}]}))
elif arguments[0] == "api" and "/artifacts" in arguments[1]:
    values = [{"expired": False, "name": "quality-gate-evidence-123-1"}]
    if mode == "duplicate":
        values.append({"expired": False, "name": "quality-gate-evidence-123-2"})
    print(json.dumps({"artifacts": values}))
elif arguments[:2] == ["run", "download"]:
    if mode != "missing-manifest":
        destination = Path(arguments[arguments.index("--dir") + 1]) / "run"
        destination.mkdir()
        (destination / "manifest.tsv").write_text("schema\\t4\\n")
else:
    raise SystemExit(3)
""",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)

        success_root = root / "success"
        success = invoke(fake_gh, success_root)
        restored = Path(success.stdout.strip())
        if restored != success_root / "123" or not (restored / "run/manifest.tsv").is_file():
            raise AssertionError("baseline artifact was not restored deterministically")
        collision = invoke(fake_gh, success_root, expected=2)
        require(collision, "destination already exists")

        malformed = invoke(fake_gh, root / "malformed", mode="malformed", expected=2)
        require(malformed, "response is malformed")
        missing = invoke(fake_gh, root / "no-runs", mode="no-runs", expected=2)
        require(missing, "no successful main quality run")
        duplicate = invoke(fake_gh, root / "duplicate", mode="duplicate", expected=2)
        require(duplicate, "no unique evidence artifact")
        no_manifest = invoke(
            fake_gh, root / "missing-manifest", mode="missing-manifest", expected=2)
        require(no_manifest, "no unique quality manifest")
        override = invoke(
            fake_gh, root / "production-override", expected=2, test_mode=False)
        require(override, "baseline output must use")

    print("Quality baseline contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
