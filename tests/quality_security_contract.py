#!/usr/bin/env python3
"""Contracts for typed and bounded CodeQL result evidence."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from quality_policy import POLICY_FILE, Policy  # noqa: E402
from quality_security import SecurityError, create_summary, validate_summary  # noqa: E402


COMMIT = "0123456789abcdef0123456789abcdef01234567"
RUN_URL = "https://github.com/owner/repository/actions/runs/901"


def invoke(
    *arguments: str,
    environment: dict[str, str] | None = None,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(ROOT / "scripts/quality-security"), *arguments],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=timeout,
    )


def main() -> None:
    policy = Policy(POLICY_FILE)
    passed = create_summary(policy, COMMIT, 901, 2, RUN_URL, "success", "success")
    assert validate_summary(passed, policy.version) == passed
    assert passed["status"] == "passed"
    failed = create_summary(policy, COMMIT, 901, 2, RUN_URL, "failure", "cancelled")
    assert failed["status"] == "failed"
    inconsistent = {**passed, "status": "failed"}
    try:
        validate_summary(inconsistent, policy.version)
    except SecurityError:
        pass
    else:
        raise AssertionError("security evidence accepted an inconsistent result")

    with tempfile.TemporaryDirectory(prefix="detach-quality-security.") as directory:
        root = Path(directory)
        summary = root / "summary.json"
        created = invoke(
            "create",
            "--source-commit", COMMIT,
            "--run-id", "901",
            "--run-attempt", "2",
            "--run-url", RUN_URL,
            "--actions-result", "success",
            "--swift-result", "success",
            "--output", str(summary),
        )
        assert created.returncode == 0, created.stderr
        assert json.loads(summary.read_text(encoding="utf-8")) == passed
        assert invoke("validate", str(summary), "--require-pass").returncode == 0

        summary.write_text(json.dumps(failed), encoding="utf-8")
        assert invoke("validate", str(summary), "--require-pass").returncode == 1

        fixture = root / "fixture.json"
        fixture.write_text(json.dumps(passed), encoding="utf-8")
        fake_gh = root / "fake-gh"
        fake_gh.write_text(
            """#!/usr/bin/env python3
import os,pathlib,shutil,sys,time
args=sys.argv[1:]
if os.environ.get('FAKE_SECURITY_SLEEP'):
    time.sleep(float(os.environ['FAKE_SECURITY_SLEEP']))
    marker=os.environ.get('FAKE_SECURITY_COMPLETION_MARKER')
    if marker:
        pathlib.Path(marker).write_text('completed', encoding='utf-8')
if args[:1] == ['api'] and '/artifacts' not in args[1]:
    print('901')
elif args[:1] == ['api']:
    print('quality-security-901-2')
elif args[:2] == ['run', 'download']:
    destination=pathlib.Path(args[args.index('--dir') + 1])
    shutil.copyfile(os.environ['FAKE_SECURITY_FIXTURE'], destination / 'summary.json')
else:
    raise SystemExit(3)
""",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        environment = {
            **os.environ,
            "DETACH_QUALITY_SECURITY_TEST_MODE": "1",
            "DETACH_QUALITY_SECURITY_GH": str(fake_gh),
            "FAKE_SECURITY_FIXTURE": str(fixture),
        }
        restored = invoke(
            "latest",
            "--repository", "owner/repository",
            "--output-root", str(root / "baseline"),
            environment=environment,
        )
        assert restored.returncode == 0, restored.stderr
        restored_path = Path(restored.stdout.strip())
        assert restored_path.is_file()
        assert json.loads(restored_path.read_text(encoding="utf-8")) == passed

        completion_marker = root / "slow-gh-completed"
        slow_environment = {
            **environment,
            "DETACH_QUALITY_SECURITY_LATEST_SECONDS": "1",
            "FAKE_SECURITY_SLEEP": "2",
            "FAKE_SECURITY_COMPLETION_MARKER": str(completion_marker),
        }
        timed = invoke(
            "latest",
            "--repository", "owner/repository",
            "--output-root", str(root / "timed"),
            environment=slow_environment,
            timeout=5,
        )
        assert timed.returncode == 2
        assert not completion_marker.exists()
        assert "bounded security restore deadline" in timed.stderr

    print("Quality security evidence contracts passed")


if __name__ == "__main__":
    main()
