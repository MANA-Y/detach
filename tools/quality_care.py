#!/usr/bin/env python3
"""Evaluate versioned quality-cycle cases with stable deterministic graders."""

from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Any, NoReturn

from quality_policy import POLICY_FILE, Policy, PolicyError


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CORPUS = ROOT / "quality/evals.json"
CASE_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
CATEGORIES = {
    "escaped-defect",
    "historical-task",
    "policy-mutant",
    "scope-violation",
}
IMPACT_KEYS = {
    "status",
    "stages",
    "specs",
    "capabilities",
    "journeys",
    "release_gates",
    "unknown",
}


class CareError(Exception):
    """The quality-care corpus or its outcome is invalid."""


def fail(message: str) -> NoReturn:
    print(f"quality-care: {message}", file=sys.stderr)
    raise SystemExit(2)


def read_json(path: Path, label: str) -> Any:
    if not path.is_file() or path.is_symlink():
        raise CareError(f"{label} is missing or unsafe: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeError, OSError) as error:
        raise CareError(f"{label} is invalid: {error}") from error


def valid_path(value: Any) -> bool:
    if not isinstance(value, str) or not value or "\t" in value or "\n" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts and str(path) == value


def validate_impact(value: Any, case_id: str) -> None:
    if not isinstance(value, dict) or set(value) != IMPACT_KEYS:
        raise CareError(f"case {case_id} has an invalid impact expectation")
    if value["status"] not in ("known", "unknown") or not isinstance(value["unknown"], bool):
        raise CareError(f"case {case_id} has an invalid impact status")
    if value["unknown"] != (value["status"] == "unknown"):
        raise CareError(f"case {case_id} has inconsistent unknown impact")
    for key in IMPACT_KEYS - {"status", "unknown"}:
        values = value[key]
        if (
            not isinstance(values, list)
            or any(not isinstance(item, str) or not item for item in values)
            or len(values) != len(set(values))
        ):
            raise CareError(f"case {case_id} has an invalid {key} expectation")


def load_corpus(path: Path) -> list[dict[str, Any]]:
    value = read_json(path, "eval corpus")
    if not isinstance(value, dict) or set(value) != {"schema", "cases"}:
        raise CareError("eval corpus schema is invalid")
    if value["schema"] != 1 or not isinstance(value["cases"], list) or not value["cases"]:
        raise CareError("eval corpus must contain schema 1 cases")
    cases: list[dict[str, Any]] = []
    seen: set[str] = set()
    seen_categories: set[str] = set()
    for raw_case in value["cases"]:
        if not isinstance(raw_case, dict) or set(raw_case) != {
            "id", "category", "grader", "paths", "expected"
        }:
            raise CareError("eval case schema is invalid")
        case_id = raw_case["id"]
        category = raw_case["category"]
        grader = raw_case["grader"]
        paths = raw_case["paths"]
        if not isinstance(case_id, str) or not CASE_ID.fullmatch(case_id) or case_id in seen:
            raise CareError(f"eval case id is invalid or duplicate: {case_id}")
        if category not in CATEGORIES:
            raise CareError(f"case {case_id} has an invalid category")
        if grader not in ("impact", "ignored"):
            raise CareError(f"case {case_id} has an invalid grader")
        if category == "scope-violation" and grader != "ignored":
            raise CareError(f"scope case {case_id} must use the ignored grader")
        if category != "scope-violation" and grader != "impact":
            raise CareError(f"impact case {case_id} must use the impact grader")
        if (
            not isinstance(paths, list)
            or not paths
            or any(not valid_path(item) for item in paths)
            or len(paths) != len(set(paths))
        ):
            raise CareError(f"case {case_id} has invalid paths")
        if grader == "impact":
            validate_impact(raw_case["expected"], case_id)
        elif raw_case["expected"] != {"ignored": True}:
            raise CareError(f"case {case_id} must expect ignored paths")
        seen.add(case_id)
        seen_categories.add(category)
        cases.append(raw_case)
    missing = CATEGORIES - seen_categories
    if missing:
        raise CareError(f"eval corpus is missing category: {sorted(missing)[0]}")
    return cases


def in_policy_order(values: set[str], order: list[str]) -> list[str]:
    return [value for value in order if value in values]


def impact(policy: Policy, paths: list[str]) -> dict[str, Any]:
    classifications = [policy.classify(path) for path in paths]
    unknown = any(classification.status == "unknown" for classification in classifications)
    if unknown:
        return {
            "status": "unknown",
            "stages": [stage.name for stage in policy.stages],
            "specs": list(policy.specs),
            "capabilities": list(policy.capabilities),
            "journeys": list(policy.journeys),
            "release_gates": ["install", "lid"],
            "unknown": True,
        }
    stages = {
        stage
        for classification in classifications
        for stage in classification.stages.split(",")
    }
    changed = True
    while changed:
        changed = False
        for prerequisite, dependent in policy.dependencies:
            if prerequisite in stages and dependent not in stages:
                stages.add(dependent)
                changed = True
    spec_paths = {classification.spec for classification in classifications}
    capabilities = {
        capability
        for classification in classifications
        for capability in classification.capabilities.split(",")
    }
    journeys = {
        journey
        for classification in classifications
        for journey in classification.journeys.split(",")
    }
    gates = {
        gate
        for classification in classifications
        for gate in classification.release_gates.split(",")
        if gate != "-"
    }
    return {
        "status": "known",
        "stages": [stage.name for stage in policy.stages if stage.name in stages],
        "specs": [identifier for identifier, (path, _) in policy.specs.items() if path in spec_paths],
        "capabilities": in_policy_order(capabilities, list(policy.capabilities)),
        "journeys": in_policy_order(journeys, list(policy.journeys)),
        "release_gates": in_policy_order(gates, ["install", "lid"]),
        "unknown": False,
    }


def ignored(paths: list[str]) -> dict[str, bool]:
    results = []
    for path in paths:
        try:
            result = subprocess.run(
                ("git", "-C", str(ROOT), "check-ignore", "--quiet", "--no-index", "--", path),
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        except OSError as error:
            raise CareError(f"cannot inspect ignored paths: {error}") from error
        if result.returncode not in (0, 1):
            raise CareError(f"cannot inspect ignored path: {path}")
        results.append(result.returncode == 0)
    return {"ignored": all(results)}


def evaluate(cases: list[dict[str, Any]], policy: Policy) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for case in cases:
        actual = (
            impact(policy, case["paths"])
            if case["grader"] == "impact"
            else ignored(case["paths"])
        )
        passed = actual == case["expected"]
        results.append(
            {
                "id": case["id"],
                "category": case["category"],
                "grader": case["grader"],
                "passed": passed,
                "expected": case["expected"],
                "actual": actual,
            }
        )
    passed_count = sum(result["passed"] for result in results)
    return {
        "schema": 1,
        "policy": policy.version,
        "status": "passed" if passed_count == len(results) else "failed",
        "passed": passed_count,
        "total": len(results),
        "categories": {
            category: sum(
                result["passed"]
                for result in results
                if result["category"] == category
            )
            for category in sorted(CATEGORIES)
        },
        "results": results,
    }


def assess(eval_path: Path, history_path: Path, policy: Policy) -> dict[str, Any]:
    eval_summary = read_json(eval_path, "eval summary")
    history = read_json(history_path, "history summary")
    if (
        not isinstance(eval_summary, dict)
        or set(eval_summary) != {
            "schema", "policy", "status", "passed", "total", "categories", "results"
        }
        or eval_summary.get("schema") != 1
        or eval_summary.get("policy") != policy.version
        or eval_summary.get("status") not in ("passed", "failed")
        or not isinstance(eval_summary.get("passed"), int)
        or not isinstance(eval_summary.get("total"), int)
        or not isinstance(eval_summary.get("categories"), dict)
        or not isinstance(eval_summary.get("results"), list)
    ):
        raise CareError("eval summary schema or policy is invalid")
    if (
        eval_summary["passed"] < 0
        or eval_summary["total"] < 1
        or eval_summary["passed"] > eval_summary["total"]
        or len(eval_summary["results"]) != eval_summary["total"]
        or set(eval_summary["categories"]) != CATEGORIES
        or any(
            not isinstance(value, int) or value < 0
            for value in eval_summary["categories"].values()
        )
    ):
        raise CareError("eval summary counts are invalid")
    if (
        not isinstance(history, dict)
        or set(history) != {
            "schema", "runs", "passed", "failed_or_interrupted",
            "invalid_evidence", "wall", "stages"
        }
        or history.get("schema") != 1
        or not isinstance(history.get("wall"), dict)
        or set(history["wall"]) != {"samples", "p50_seconds", "p95_seconds"}
        or not isinstance(history["wall"].get("p95_seconds"), int)
        or not isinstance(history.get("invalid_evidence"), int)
        or not isinstance(history.get("stages"), list)
    ):
        raise CareError("history summary schema is invalid")
    for key in ("runs", "passed", "failed_or_interrupted", "invalid_evidence"):
        if not isinstance(history[key], int) or history[key] < 0:
            raise CareError("history summary counts are invalid")
    for key in ("samples", "p50_seconds", "p95_seconds"):
        if not isinstance(history["wall"][key], int) or history["wall"][key] < 0:
            raise CareError("history summary timing is invalid")
    if (
        history["passed"] + history["failed_or_interrupted"] != history["runs"]
        or history["wall"]["samples"] != history["runs"]
        or history["wall"]["p50_seconds"] > history["wall"]["p95_seconds"]
    ):
        raise CareError("history summary totals are inconsistent")
    stage_keys = {
        "stage", "samples", "failures", "environment_failures",
        "p50_seconds", "p95_seconds"
    }
    for stage in history["stages"]:
        if (
            not isinstance(stage, dict)
            or set(stage) != stage_keys
            or not isinstance(stage["stage"], str)
            or any(
                not isinstance(stage[key], int) or stage[key] < 0
                for key in stage_keys - {"stage"}
            )
        ):
            raise CareError("history stage summary is invalid")
        if (
            stage["failures"] > stage["samples"]
            or stage["environment_failures"] > stage["failures"]
            or stage["p50_seconds"] > stage["p95_seconds"]
        ):
            raise CareError("history stage totals are inconsistent")
    slo = policy.limits["pr_feedback_seconds"]
    alert = slo * 80 // 100
    p95 = history["wall"]["p95_seconds"]
    if p95 >= slo:
        latency_status = "breached"
    elif p95 >= alert:
        latency_status = "attention"
    else:
        latency_status = "healthy"
    environment_failures = sum(
        stage.get("environment_failures", 0)
        for stage in history["stages"]
        if isinstance(stage, dict)
    )
    status = "passed"
    reasons: list[str] = []
    if eval_summary["status"] != "passed":
        status = "attention"
        reasons.append("workflow eval regression")
    if latency_status != "healthy":
        status = "attention"
        reasons.append(f"pull-request wall p95 is {latency_status}")
    if history["invalid_evidence"]:
        status = "attention"
        reasons.append("invalid current-schema evidence was skipped")
    if history["failed_or_interrupted"]:
        status = "attention"
        reasons.append("a retained gate run failed or was interrupted")
    if environment_failures:
        status = "attention"
        reasons.append("a retained stage had an environment failure")
    return {
        "schema": 1,
        "policy": policy.version,
        "status": status,
        "reasons": reasons,
        "evals": {
            "passed": eval_summary.get("passed", 0),
            "total": eval_summary.get("total", 0),
            "categories": eval_summary.get("categories", {}),
        },
        "latency": {
            "status": latency_status,
            "wall_p95_seconds": p95,
            "alert_seconds": alert,
            "slo_seconds": slo,
        },
        "runs": {
            "total": history.get("runs", 0),
            "failed_or_interrupted": history.get("failed_or_interrupted", 0),
            "environment_failures": environment_failures,
            "invalid_evidence": history["invalid_evidence"],
        },
        "autonomy": {
            "review": "not-configured",
            "repair_loops": "not-yet-emitted",
        },
    }


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    if path.exists() and path.is_symlink():
        raise CareError(f"output target is a symlink: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="scripts/quality-care")
    result.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("validate")
    evaluate_parser = commands.add_parser("evaluate")
    evaluate_parser.add_argument("--output", type=Path)
    evaluate_parser.add_argument("--json", action="store_true")
    assess_parser = commands.add_parser("assess")
    assess_parser.add_argument("--eval-summary", type=Path, required=True)
    assess_parser.add_argument("--history-summary", type=Path, required=True)
    assess_parser.add_argument("--output", type=Path, required=True)
    assess_parser.add_argument("--json", action="store_true")
    return result


def main() -> int:
    arguments = parser().parse_args()
    policy = Policy(POLICY_FILE)
    if arguments.command == "assess":
        document = assess(
            arguments.eval_summary.resolve(), arguments.history_summary.resolve(), policy
        )
        atomic_write(arguments.output.resolve(), document)
        if arguments.json:
            print(json.dumps(document, indent=2, sort_keys=True))
        else:
            print(
                f"quality-care: {document['status']} policy={document['policy']} "
                f"wall-p95={document['latency']['wall_p95_seconds']}s"
            )
        return 0 if document["status"] == "passed" else 1
    cases = load_corpus(arguments.corpus.resolve())
    if arguments.command == "validate":
        print(f"quality-care: valid corpus with {len(cases)} cases")
        return 0
    document = evaluate(cases, policy)
    if arguments.output:
        atomic_write(arguments.output.resolve(), document)
    if arguments.json:
        print(json.dumps(document, indent=2, sort_keys=True))
    else:
        print(
            f"quality-care: {document['status']} policy={document['policy']} "
            f"cases={document['passed']}/{document['total']}"
        )
        for result in document["results"]:
            if not result["passed"]:
                print(f"quality-care: failed case {result['id']}", file=sys.stderr)
    return 0 if document["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CareError, PolicyError) as error:
        fail(str(error))
