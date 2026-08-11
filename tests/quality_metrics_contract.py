#!/usr/bin/env python3
"""Negative contracts for automatic green-main quality metrics."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Optional, Tuple


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from quality_policy import POLICY_FILE, Policy  # noqa: E402


POLICY = Policy(POLICY_FILE)
BASE_COMMIT = "a" * 40
SOURCE_COMMIT = "b" * 40


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def segments(covered: int, total: int) -> list[list[Any]]:
    result: list[list[Any]] = [[1, 1, 1, True, True, False]]
    if covered < total:
        result.append([covered + 1, 1, 0, True, True, False])
    result.append([total + 1, 1, 0, False, False, False])
    return result


def coverage_document(
    *, ui_covered: int = 9, critical_override: Optional[Tuple[str, int]] = None
) -> dict[str, Any]:
    files = []
    sources = [("app/Sources/DetachApp/Synthetic.swift", ui_covered)]
    sources.extend((path, 9) for path, _ in POLICY.critical)
    for path, covered in sources:
        if critical_override and path == critical_override[0]:
            covered = critical_override[1]
        files.append(
            {
                "filename": f"/fixture/{path}",
                "segments": segments(covered, 10),
                "summary": {
                    "lines": {"count": 10, "covered": covered, "percent": covered * 10.0}
                },
            }
        )
    return {"type": "llvm.coverage.json.export", "version": "2.0.1", "data": [{"files": files}]}


def test_lines(*, remove: str = "") -> list[str]:
    values = [f"{suite}/testEvidence" for suite in POLICY.required_suites if suite != remove]
    values.append("DetachKitTests.SessionHealthTests/testSecondEvidence")
    return values


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def create_baseline(root: Path, metrics: Path, *, include_metrics: bool = True) -> Path:
    run_dir = root / "run"
    run_dir.mkdir(parents=True)
    artifacts = run_dir / "artifacts.tsv"
    if include_metrics:
        shutil.copyfile(metrics, run_dir / "quality-metrics.json")
        artifacts.write_text(
            "schema\t1\n"
            f"file\tquality-metrics.json\t{digest(run_dir / 'quality-metrics.json')}\n",
            encoding="utf-8",
        )
    else:
        artifacts.write_text("schema\t1\n", encoding="utf-8")
    (run_dir / "manifest.tsv").write_text(
        "schema\t4\n"
        f"policy\t{POLICY.version}\n"
        "authority\tci-main\n"
        "result\tpassed\n"
        f"source_commit\t{BASE_COMMIT}\n"
        f"artifacts_sha256\t{digest(artifacts)}\n",
        encoding="utf-8",
    )
    return run_dir


def invoke(arguments: list[str], *, expected: int = 0, test_mode: bool = True) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    if test_mode:
        environment["DETACH_QUALITY_METRICS_TEST_MODE"] = "1"
    else:
        environment.pop("DETACH_QUALITY_METRICS_TEST_MODE", None)
    result = subprocess.run(
        [str(ROOT / "scripts/quality-metrics"), *arguments],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"quality metrics returned {result.returncode}, expected {expected}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def evaluate_arguments(
    coverage: Path,
    tests: Path,
    output: Path,
    changed: Path,
    *,
    baseline: Optional[Path] = None,
    authority: str = "local-diagnostic",
    source_commit: str = SOURCE_COMMIT,
) -> list[str]:
    arguments = [
        "evaluate",
        "--coverage-json",
        str(coverage),
        "--tests",
        str(tests),
        "--output",
        str(output),
        "--source-commit",
        source_commit,
        "--authority",
        authority,
        "--test-changed-lines",
        str(changed),
    ]
    if baseline is not None:
        arguments.extend(("--baseline-root", str(baseline)))
    return arguments


def require_text(result: subprocess.CompletedProcess[str], text: str) -> None:
    if text not in result.stderr and text not in result.stdout:
        raise AssertionError(f"missing diagnostic: {text}")


def main() -> None:
    if sys.version_info < (3, 9):
        raise AssertionError("quality metrics require Python 3.9 or newer")
    with tempfile.TemporaryDirectory(prefix="detach-quality-metrics-contract.") as temporary:
        root = Path(temporary)
        coverage = root / "coverage.json"
        tests = root / "tests.txt"
        changed = root / "changed.json"
        baseline_metrics = root / "baseline-metrics.json"
        baseline_root = root / "baseline"

        write_json(coverage, coverage_document())
        tests.write_text("\n".join(test_lines()) + "\n", encoding="utf-8")
        write_json(changed, {})
        invoke(
            evaluate_arguments(
                coverage,
                tests,
                baseline_metrics,
                changed,
                source_commit=BASE_COMMIT,
            )
        )
        invoke(["validate", str(baseline_metrics)])
        run_dir = create_baseline(baseline_root, baseline_metrics)

        write_json(changed, {"app/Sources/DetachApp/Synthetic.swift": list(range(1, 11))})
        current = root / "current.json"
        invoke(
            evaluate_arguments(
                coverage,
                tests,
                current,
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            )
        )
        document = json.loads(current.read_text(encoding="utf-8"))
        assert document["comparison"]["status"] == "passed"
        assert document["changed_lines"]["status"] == "passed"
        assert document["changed_lines"]["line_coverage"]["percent"] == 90.0

        missing = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "missing.json",
                changed,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(missing, "require last green main evidence")

        test_only = invoke(
            evaluate_arguments(coverage, tests, root / "test-only.json", changed),
            expected=2,
            test_mode=False,
        )
        require_text(test_only, "test changed-line evidence is test-only")

        metrics_path = run_dir / "quality-metrics.json"
        original_metrics = metrics_path.read_bytes()
        metrics_path.write_bytes(original_metrics + b" ")
        tampered = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "tampered.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(tampered, "digest does not match")
        metrics_path.write_bytes(original_metrics)

        exact_tests = root / "exact-tests.txt"
        exact_tests.write_text(
            "\n".join(
                test for test in test_lines()
                if test != "DetachKitTests.SessionHealthTests/testSecondEvidence"
            ) + "\n",
            encoding="utf-8",
        )
        exact_removed = invoke(
            evaluate_arguments(
                coverage,
                exact_tests,
                root / "exact-removed.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=1,
        )
        require_text(exact_removed, "business test was removed")

        wrong_policy = json.loads(original_metrics)
        wrong_policy["policy"] = 13
        write_json(metrics_path, wrong_policy)
        artifacts = run_dir / "artifacts.tsv"
        artifacts.write_text(
            "schema\t1\n"
            f"file\tquality-metrics.json\t{digest(metrics_path)}\n",
            encoding="utf-8",
        )
        manifest = run_dir / "manifest.tsv"
        manifest_lines = manifest.read_text(encoding="utf-8").splitlines()
        manifest.write_text(
            "\n".join(
                f"artifacts_sha256\t{digest(artifacts)}"
                if line.startswith("artifacts_sha256\t") else line
                for line in manifest_lines
            ) + "\n",
            encoding="utf-8",
        )
        policy_mismatch = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "policy-mismatch.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(policy_mismatch, "policy does not match")
        metrics_path.write_bytes(original_metrics)
        artifacts.write_text(
            "schema\t1\n"
            f"file\tquality-metrics.json\t{digest(metrics_path)}\n",
            encoding="utf-8",
        )
        manifest_lines = manifest.read_text(encoding="utf-8").splitlines()
        manifest.write_text(
            "\n".join(
                f"artifacts_sha256\t{digest(artifacts)}"
                if line.startswith("artifacts_sha256\t") else line
                for line in manifest_lines
            ) + "\n",
            encoding="utf-8",
        )

        missing_suite = POLICY.required_suites[0]
        removed_tests = root / "removed-tests.txt"
        removed_tests.write_text("\n".join(test_lines(remove=missing_suite)) + "\n", encoding="utf-8")
        removed = invoke(
            evaluate_arguments(
                coverage,
                removed_tests,
                root / "removed.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(removed, "required Swift suite is missing")

        write_json(changed, {})
        regressed_coverage = root / "coverage-regressed.json"
        write_json(regressed_coverage, coverage_document(ui_covered=8))
        aggregate = invoke(
            evaluate_arguments(
                regressed_coverage,
                tests,
                root / "aggregate.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=1,
        )
        require_text(aggregate, "ui line coverage regressed")

        critical_path = POLICY.critical[0][0]
        critical_coverage = root / "critical-regressed.json"
        write_json(
            critical_coverage,
            coverage_document(critical_override=(critical_path, 8)),
        )
        critical = invoke(
            evaluate_arguments(
                critical_coverage,
                tests,
                root / "critical.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=1,
        )
        require_text(critical, "critical line coverage regressed")

        write_json(changed, {"app/Sources/DetachApp/Synthetic.swift": [10]})
        changed_loss = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "changed-loss.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=1,
        )
        require_text(changed_loss, "changed-line coverage regressed")

        no_metrics_root = root / "no-metrics"
        create_baseline(no_metrics_root, baseline_metrics, include_metrics=False)
        no_metrics = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "no-metrics.json",
                changed,
                baseline=no_metrics_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(no_metrics, "has no quality metrics")

        malformed = root / "malformed.json"
        write_json(malformed, {"schema": 999})
        malformed_result = invoke(["validate", str(malformed)], expected=2)
        require_text(malformed_result, "schema is unsupported")

        extra = json.loads(current.read_text(encoding="utf-8"))
        extra["manual_floor"] = 1
        extra_path = root / "extra.json"
        write_json(extra_path, extra)
        extra_result = invoke(["validate", str(extra_path)], expected=2)
        require_text(extra_result, "schema is unsupported")

    print("Quality metrics contracts passed")


if __name__ == "__main__":
    main()
