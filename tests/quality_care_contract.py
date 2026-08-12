#!/usr/bin/env python3
"""Contract tests for quality-cycle evals and scheduled care."""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/quality-care"
CORPUS = ROOT / "quality/evals.json"
CARE_WORKFLOW = ROOT / ".github/workflows/quality-care.yml"
DOC_WORKFLOW = ROOT / ".github/workflows/documentation-care.yml"


def invoke(
    arguments: list[str], *, expected: int = 0
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(SCRIPT), *arguments],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"unexpected exit {result.returncode}, expected {expected}: "
            f"{' '.join(arguments)}\n{result.stdout}"
        )
    return result


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def assert_workflows() -> None:
    care = CARE_WORKFLOW.read_text(encoding="utf-8")
    docs = DOC_WORKFLOW.read_text(encoding="utf-8")
    for required in (
        "schedule:",
        "timeout-minutes: 5",
        "scripts/quality-care evaluate",
        "scripts/quality-history --format json",
        "scripts/quality-care assess",
        "cancel-in-progress: true",
        "--created \">=$since\"",
        "timeout 20s gh run download",
        "timeout 20s gh issue create",
        "issues: write",
    ):
        if required not in care:
            raise AssertionError(f"quality-care workflow is missing: {required}")
    for required in (
        "schedule:",
        "timeout-minutes: 5",
        "scripts/quality-policy generate",
        "scripts/quality-care validate",
        "pull-requests: write",
        "--force-with-lease=",
        "timeout 20s git ls-remote",
        "timeout 20s gh pr create",
        "quality/generated/(policy\\.json|spec-traceability\\.md)",
    ):
        if required not in docs:
            raise AssertionError(f"documentation-care workflow is missing: {required}")
    for workflow in (care, docs):
        if re.search(r"uses:\s+\S+@v[0-9]", workflow):
            raise AssertionError("care workflow contains a mutable Action tag")
        if re.search(r"release-version|notary|tag |upload release", workflow, re.IGNORECASE):
            raise AssertionError("care workflow can enter a release path")


def history(wall_p95: int) -> dict[str, object]:
    return {
        "schema": 1,
        "runs": 4,
        "passed": 4,
        "failed_or_interrupted": 0,
        "invalid_evidence": 0,
        "wall": {"samples": 4, "p50_seconds": 300, "p95_seconds": wall_p95},
        "stages": [
            {
                "stage": "codex",
                "samples": 4,
                "failures": 0,
                "environment_failures": 0,
                "p50_seconds": 120,
                "p95_seconds": 150,
            }
        ],
    }


def main() -> int:
    assert_workflows()
    invoke(["validate"])
    result = json.loads(invoke(["evaluate", "--json"]).stdout)
    assert result["schema"] == 1
    assert result["status"] == "passed"
    assert result["passed"] == result["total"] == 8
    assert set(result["categories"]) == {
        "escaped-defect", "historical-task", "policy-mutant", "scope-violation"
    }

    with tempfile.TemporaryDirectory(prefix="detach-quality-care-") as raw:
        root = Path(raw)
        corpus = json.loads(CORPUS.read_text(encoding="utf-8"))

        wrong_impact = json.loads(json.dumps(corpus))
        wrong_impact["cases"][0]["expected"]["stages"].remove("gate-contract")
        wrong_impact_path = root / "wrong-impact.json"
        write_json(wrong_impact_path, wrong_impact)
        failed = json.loads(
            invoke(
                ["--corpus", str(wrong_impact_path), "evaluate", "--json"],
                expected=1,
            ).stdout
        )
        assert failed["status"] == "failed"
        assert failed["results"][0]["id"] == "historical-quality-tool"

        scope_escape = json.loads(json.dumps(corpus))
        scope_escape["cases"][-1]["paths"] = ["public/not-ignored.txt"]
        scope_escape_path = root / "scope-escape.json"
        write_json(scope_escape_path, scope_escape)
        escaped = json.loads(
            invoke(
                ["--corpus", str(scope_escape_path), "evaluate", "--json"],
                expected=1,
            ).stdout
        )
        assert escaped["results"][-1]["actual"] == {"ignored": False}

        missing_category = json.loads(json.dumps(corpus))
        missing_category["cases"] = [
            case for case in missing_category["cases"]
            if case["category"] != "escaped-defect"
        ]
        missing_path = root / "missing-category.json"
        write_json(missing_path, missing_category)
        output = invoke(
            ["--corpus", str(missing_path), "validate"], expected=2
        ).stdout
        assert "missing category: escaped-defect" in output

        eval_path = root / "evals.json"
        write_json(eval_path, result)
        healthy_history = root / "healthy-history.json"
        write_json(healthy_history, history(420))
        healthy_summary = root / "healthy-summary.json"
        invoke(
            [
                "assess", "--eval-summary", str(eval_path),
                "--history-summary", str(healthy_history),
                "--output", str(healthy_summary),
            ]
        )
        healthy = json.loads(healthy_summary.read_text(encoding="utf-8"))
        assert healthy["status"] == "passed"
        assert healthy["latency"]["alert_seconds"] == 480

        slow_history = root / "slow-history.json"
        write_json(slow_history, history(481))
        slow_summary = root / "slow-summary.json"
        invoke(
            [
                "assess", "--eval-summary", str(eval_path),
                "--history-summary", str(slow_history),
                "--output", str(slow_summary),
            ],
            expected=1,
        )
        slow = json.loads(slow_summary.read_text(encoding="utf-8"))
        assert slow["status"] == "attention"
        assert slow["latency"]["status"] == "attention"

        failed_history_value = history(420)
        failed_history_value["passed"] = 3
        failed_history_value["failed_or_interrupted"] = 1
        failed_history = root / "failed-history.json"
        write_json(failed_history, failed_history_value)
        failed_summary = root / "failed-summary.json"
        invoke(
            [
                "assess", "--eval-summary", str(eval_path),
                "--history-summary", str(failed_history),
                "--output", str(failed_summary),
            ],
            expected=1,
        )
        failed_care = json.loads(failed_summary.read_text(encoding="utf-8"))
        assert "a retained gate run failed or was interrupted" in failed_care["reasons"]

    print("Quality care contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
