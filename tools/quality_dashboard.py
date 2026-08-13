#!/usr/bin/env python3
"""Generate and serve the deterministic Detach quality dashboard."""

from __future__ import annotations

import argparse
import hashlib
import html
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import threading
from typing import Any, NoReturn, Optional

from quality_care import (
    CareError,
    validate_input_bindings as validate_care_inputs,
    validate_summary as validate_care_summary,
)
from quality_metrics import MetricsError, validate_metrics
from quality_mutation import MutationError, validate_summary
from quality_promote import PromotionError, validate_promotion


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RESULT_ROOT = ROOT / "app/build/quality-gates"
DEFAULT_OUTPUT = ROOT / "app/build/quality-dashboard"
POLICY_JSON = ROOT / "quality/generated/policy.json"
SECURITY_WORKFLOW = ROOT / ".github/workflows/security.yml"
MANIFEST_SCHEMA = "4"
SUMMARY_HEADER = [
    "policy",
    "mode",
    "stage",
    "status",
    "duration_seconds",
    "log",
    "log_sha256",
    "origin_run",
]
FAILURE_STATUSES = {"failed", "environment-failed", "timeout", "interrupted"}
PASS_STATUSES = {"passed", "reused"}
MERGE_POLICY = re.compile(r"^Quality-Policy: ([1-9][0-9]*)$", re.MULTILINE)
MERGE_REPAIR = re.compile(r"^Quality-Repair-Attempt: ([0-9]+)$", re.MULTILINE)


class DashboardError(Exception):
    """Invalid, unsafe, or incomplete dashboard evidence."""


def fail(message: str) -> NoReturn:
    print(f"quality-dashboard: {message}", file=sys.stderr)
    raise SystemExit(2)


def safe_file(path: Path, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        raise DashboardError(f"{label} is missing or unsafe: {path}")
    return path


def read_manifest(
    run_dir: Path, *, require_dashboard_fields: bool = True
) -> dict[str, str]:
    manifest_path = safe_file(run_dir / "manifest.tsv", "manifest")
    values: dict[str, str] = {}
    for line_number, line in enumerate(manifest_path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 2 or not fields[0] or fields[0] in values:
            raise DashboardError(f"manifest has a malformed or duplicate record at line {line_number}")
        values[fields[0]] = fields[1]
    required = {
        "schema",
        "policy",
        "mode",
        "authority",
        "source_commit",
        "fingerprint",
        "stages",
        "capabilities",
        "journeys",
        "started_at",
        "finished_at",
        "duration_seconds",
        "timing_wall_seconds",
        "summary_sha256",
        "result",
    }
    missing = required - values.keys()
    if missing:
        raise DashboardError(f"manifest is missing: {sorted(missing)[0]}")
    if values["schema"] != MANIFEST_SCHEMA:
        raise DashboardError("manifest schema is unsupported")
    if not values["policy"].isdigit():
        raise DashboardError("manifest policy is invalid")
    if require_dashboard_fields and not values.get("specs"):
        raise DashboardError("manifest is missing: specs")
    if values["authority"] not in ("local-diagnostic", "ci-merge", "ci-main", "release"):
        raise DashboardError("manifest authority is invalid")
    if values["result"] not in ("passed", "failed", "interrupted", "diagnostic"):
        raise DashboardError("manifest result is invalid")
    for key in ("duration_seconds", "timing_wall_seconds"):
        if not values[key].isdigit():
            raise DashboardError(f"manifest {key} is invalid")
    if not values["finished_at"]:
        raise DashboardError("manifest describes an unfinished run")
    return values


def read_summary(run_dir: Path, manifest: dict[str, str]) -> list[dict[str, Any]]:
    summary_path = safe_file(run_dir / "summary.tsv", "summary")
    digest = hashlib.sha256(summary_path.read_bytes()).hexdigest()
    if digest != manifest["summary_sha256"]:
        raise DashboardError("summary digest does not match the manifest")
    lines = summary_path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].split("\t") != SUMMARY_HEADER:
        raise DashboardError("summary schema is invalid")
    stages: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line_number, line in enumerate(lines[1:], 2):
        fields = line.split("\t")
        if len(fields) != len(SUMMARY_HEADER):
            raise DashboardError(f"summary line {line_number} is malformed")
        record = dict(zip(SUMMARY_HEADER, fields))
        stage = record["stage"]
        if stage in seen or not record["duration_seconds"].isdigit():
            raise DashboardError(f"summary line {line_number} is duplicate or invalid")
        seen.add(stage)
        record["duration_seconds"] = int(record["duration_seconds"])
        stages.append(record)
    expected = [stage for stage in manifest["stages"].split(",") if stage]
    if [record["stage"] for record in stages] != expected:
        raise DashboardError("summary stages do not match the manifest plan")
    return stages


def read_metrics(run_dir: Path, manifest: dict[str, str]) -> Optional[dict[str, Any]]:
    metrics_path = run_dir / "quality-metrics.json"
    if not metrics_path.exists():
        return None
    artifacts_path = safe_file(run_dir / "artifacts.tsv", "artifact inventory")
    artifacts_digest = hashlib.sha256(artifacts_path.read_bytes()).hexdigest()
    if artifacts_digest != manifest["artifacts_sha256"]:
        raise DashboardError("artifact inventory digest does not match the manifest")
    metric_digests: list[str] = []
    for line_number, line in enumerate(
        artifacts_path.read_text(encoding="utf-8").splitlines(), 1
    ):
        fields = line.split("\t")
        if fields == ["schema", "1"]:
            continue
        if len(fields) != 3 or fields[0] != "file":
            raise DashboardError(f"artifact inventory line {line_number} is malformed")
        if fields[1] == "quality-metrics.json":
            metric_digests.append(fields[2])
    if len(metric_digests) != 1:
        raise DashboardError("quality metrics digest is missing or duplicated")
    actual_digest = hashlib.sha256(safe_file(metrics_path, "quality metrics").read_bytes()).hexdigest()
    if actual_digest != metric_digests[0]:
        raise DashboardError("quality metrics digest does not match the inventory")
    try:
        metrics = validate_metrics(json.loads(metrics_path.read_text(encoding="utf-8")))
    except (MetricsError, json.JSONDecodeError, UnicodeError) as error:
        raise DashboardError(f"quality metrics are invalid: {error}") from error
    if metrics["policy"] != int(manifest["policy"]):
        raise DashboardError("quality metrics policy does not match the run")
    if metrics["source_commit"] != manifest["source_commit"]:
        raise DashboardError("quality metrics source does not match the run")
    return metrics


def read_policy() -> dict[str, Any]:
    policy_path = safe_file(POLICY_JSON, "generated policy")
    try:
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeError) as error:
        raise DashboardError(f"generated policy JSON is invalid: {error}") from error
    if policy.get("schema") != 1 or not isinstance(policy.get("policy"), int):
        raise DashboardError("generated policy schema is invalid")
    return policy


def read_mutation_summary(
    path: Optional[Path], expected_policy: int
) -> Optional[dict[str, Any]]:
    if path is None:
        return None
    try:
        document = json.loads(safe_file(path, "mutation summary").read_text(encoding="utf-8"))
        return validate_summary(document, expected_policy)
    except (MutationError, json.JSONDecodeError, UnicodeError) as error:
        raise DashboardError(f"mutation summary is invalid: {error}") from error


def read_care_summary(
    path: Optional[Path], expected_policy: int, expected_slo_seconds: int
) -> Optional[dict[str, Any]]:
    if path is None:
        return None
    try:
        care_path = safe_file(path, "care summary")
        document = json.loads(care_path.read_text(encoding="utf-8"))
        summary = validate_care_summary(
            document, expected_policy, expected_slo_seconds
        )
        validate_care_inputs(care_path, summary)
        return summary
    except (CareError, json.JSONDecodeError, UnicodeError) as error:
        raise DashboardError(f"care summary is invalid: {error}") from error


def split_csv(value: str) -> list[str]:
    return [item for item in value.split(",") if item]


def effective_identity(
    run_dir: Path, manifest: dict[str, str]
) -> tuple[str, str, Optional[dict[str, str]]]:
    try:
        promotion = validate_promotion(run_dir, manifest)
    except PromotionError as error:
        raise DashboardError(str(error)) from error
    if promotion is None:
        return manifest["source_commit"], manifest["authority"], None
    return promotion["main_commit"], promotion["authority"], promotion


def percentile(values: list[int], percent: int) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = (len(ordered) * percent + 99) // 100
    return ordered[max(0, index - 1)]


def collect_trends(result_root: Path, current: Path) -> list[dict[str, Any]]:
    trends: list[dict[str, Any]] = []
    if not result_root.is_dir() or result_root.is_symlink():
        return trends
    for candidate in sorted(result_root.iterdir())[-20:]:
        if not candidate.is_dir() or candidate.is_symlink():
            continue
        try:
            manifest = read_manifest(candidate)
            commit, authority, _ = effective_identity(candidate, manifest)
        except DashboardError:
            continue
        trends.append(
            {
                "run": candidate.name,
                "current": candidate.resolve() == current.resolve(),
                "commit": commit,
                "authority": authority,
                "result": manifest["result"],
                "finished_at": manifest["finished_at"],
                "duration_seconds": int(manifest["duration_seconds"]),
                "wall_seconds": int(manifest["timing_wall_seconds"]),
            }
        )
    return trends


def latest_run(result_root: Path) -> Path:
    if not result_root.is_dir() or result_root.is_symlink():
        raise DashboardError("quality result root is missing or unsafe")
    candidates = [
        path for path in sorted(result_root.iterdir())
        if path.is_dir() and not path.is_symlink() and (path / "manifest.tsv").is_file()
    ]
    if not candidates:
        raise DashboardError("no quality run evidence exists")
    return candidates[-1]


def parse_merge_evidence(message: str, policy: int, maximum_repairs: int) -> Any:
    policy_match = MERGE_POLICY.search(message)
    repair_match = MERGE_REPAIR.search(message)
    if policy_match is None and repair_match is None:
        return "not-yet-emitted"
    if policy_match is None or repair_match is None:
        raise DashboardError("merge evidence trailers are incomplete")
    merge_policy = int(policy_match.group(1))
    repair_attempt = int(repair_match.group(1))
    if merge_policy != policy or repair_attempt > maximum_repairs:
        raise DashboardError("merge evidence trailers violate the current policy")
    return {
        "policy": merge_policy,
        "repair_attempt": repair_attempt,
        "maximum_repair_loops": maximum_repairs,
        "status": "passed",
    }


def merge_evidence(commit: str, policy: int, maximum_repairs: int) -> Any:
    try:
        result = subprocess.run(
            ["git", "show", "-s", "--format=%B", f"{commit}^{{commit}}"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "not-yet-emitted"
    if result.returncode:
        return "not-yet-emitted"
    return parse_merge_evidence(result.stdout, policy, maximum_repairs)


def security_automation() -> dict[str, Any]:
    workflow = safe_file(SECURITY_WORKFLOW, "security workflow").read_text(
        encoding="utf-8"
    )
    try:
        trigger_block = workflow[workflow.index("on:\n"):workflow.index("\npermissions:")]
    except ValueError as error:
        raise DashboardError("security workflow triggers are invalid") from error
    if (
        "workflow_dispatch:" not in trigger_block
        or "schedule:" not in trigger_block
        or "push:" in trigger_block
        or "pull_request:" in trigger_block
    ):
        raise DashboardError("security workflow cadence is not weekly and manual")
    languages = sorted(set(re.findall(r"(?m)^\s+languages:\s+([a-z]+)$", workflow)))
    if languages != ["actions", "swift"]:
        raise DashboardError("security workflow CodeQL languages are invalid")
    return {
        "status": "configured",
        "codeql_languages": languages,
        "cadence": "weekly-and-manual",
        "pull_request_feedback": "not-selected",
    }


def build_data(
    run_dir: Path,
    result_root: Path,
    run_url: str,
    mutation_summary: Optional[Path] = None,
    care_summary: Optional[Path] = None,
) -> dict[str, Any]:
    manifest = read_manifest(run_dir)
    effective_commit, effective_authority, promotion = effective_identity(
        run_dir, manifest
    )
    stages = read_summary(run_dir, manifest)
    policy = read_policy()
    if int(manifest["policy"]) != policy["policy"]:
        raise DashboardError("run policy does not match the generated policy view")
    stage_by_id = {stage["stage"]: stage for stage in stages}
    journeys_by_id = {journey["id"]: journey for journey in policy["journeys"]}
    scenarios_by_id = {scenario["id"]: scenario for scenario in policy["scenarios"]}
    specs_by_id = {spec["id"]: spec for spec in policy["specifications"]}
    impacted_specs: list[dict[str, Any]] = []
    for spec_id in split_csv(manifest["specs"]):
        spec = specs_by_id.get(spec_id)
        if spec is None:
            raise DashboardError(f"manifest references an unknown spec: {spec_id}")
        impacted_specs.append(spec)
    impacted_journeys = split_csv(manifest["journeys"])
    journey_evidence: list[dict[str, Any]] = []
    passed_scenarios = 0
    automatable_scenarios = 0
    planned_scenarios = 0
    manual_scenarios = 0
    for journey_id in impacted_journeys:
        journey = journeys_by_id.get(journey_id)
        if journey is None:
            raise DashboardError(f"manifest references an unknown journey: {journey_id}")
        scenario_evidence: list[dict[str, Any]] = []
        for scenario_id in journey["scenarios"]:
            scenario = scenarios_by_id[scenario_id]
            stage = stage_by_id.get(scenario["stage"])
            if scenario["status"] == "planned":
                status = "planned"
                planned_scenarios += 1
                automatable_scenarios += 1
            elif scenario["status"] == "manual-release":
                status = "manual-release"
                manual_scenarios += 1
            elif stage is None:
                status = "not-selected"
                automatable_scenarios += 1
            elif stage["status"] in PASS_STATUSES:
                status = "passed"
                passed_scenarios += 1
                automatable_scenarios += 1
            elif stage["status"] in FAILURE_STATUSES:
                status = "failed"
                automatable_scenarios += 1
            else:
                status = stage["status"]
                automatable_scenarios += 1
            scenario_evidence.append({**scenario, "evidence_status": status})
        statuses = {scenario["evidence_status"] for scenario in scenario_evidence}
        if "failed" in statuses:
            journey_status = "failed"
        elif "planned" in statuses or "not-selected" in statuses:
            journey_status = "incomplete"
        elif statuses == {"manual-release"}:
            journey_status = "manual-release"
        else:
            journey_status = "passed"
        journey_evidence.append({**journey, "status": journey_status, "scenario_evidence": scenario_evidence})
    durations = [stage["duration_seconds"] for stage in stages]
    trends = collect_trends(result_root, run_dir)
    trend_walls = [trend["wall_seconds"] for trend in trends]
    slowest = max(stages, key=lambda stage: stage["duration_seconds"], default=None)
    metrics = read_metrics(run_dir, manifest)
    mutation = read_mutation_summary(mutation_summary, int(manifest["policy"]))
    care = read_care_summary(
        care_summary,
        int(manifest["policy"]),
        int(policy["limits"]["pr_feedback_seconds"]),
    )
    return {
        "schema": 2,
        "run": {
            "id": run_dir.name,
            "commit": effective_commit,
            "tested_commit": manifest["source_commit"],
            "fingerprint": manifest["fingerprint"],
            "policy": int(manifest["policy"]),
            "authority": effective_authority,
            "mode": manifest["mode"],
            "result": manifest["result"],
            "started_at": manifest["started_at"],
            "finished_at": manifest["finished_at"],
            "duration_seconds": int(manifest["duration_seconds"]),
            "wall_seconds": int(manifest["timing_wall_seconds"]),
            "url": run_url,
            "promotion": promotion if promotion is not None else "not-promoted",
        },
        "specifications": impacted_specs,
        "capabilities": split_csv(manifest["capabilities"]),
        "journeys": journey_evidence,
        "stages": stages,
        "quality": {
            "passed_scenarios": passed_scenarios,
            "automatable_scenarios": automatable_scenarios,
            "planned_scenarios": planned_scenarios,
            "manual_release_scenarios": manual_scenarios,
            "scenario_percent": round(100 * passed_scenarios / automatable_scenarios)
            if automatable_scenarios else 0,
            "slowest_stage": slowest["stage"] if slowest else "-",
            "slowest_stage_seconds": slowest["duration_seconds"] if slowest else 0,
            "stage_duration_p50_seconds": round(statistics.median(durations)) if durations else 0,
            "run_wall_p50_seconds": percentile(trend_walls, 50),
            "run_wall_p95_seconds": percentile(trend_walls, 95),
            "coverage": metrics if metrics is not None else "not-yet-emitted",
            "mutation": mutation if mutation is not None else "not-yet-emitted",
            "care": care if care is not None else "not-yet-emitted",
            "merge": merge_evidence(
                effective_commit,
                int(manifest["policy"]),
                int(policy["limits"]["max_repair_loops"]),
            ),
            "security": security_automation(),
        },
        "trends": trends,
    }


def status_class(status: str) -> str:
    if status in ("passed", "reused"):
        return "good"
    if status in (
        "planned", "not-selected", "incomplete", "manual-release", "blocked", "diagnostic"
    ):
        return "warn"
    return "bad"


def render_html(data: dict[str, Any]) -> str:
    run = data["run"]
    quality = data["quality"]
    overall_class = (
        "good" if run["result"] == "passed" else "warn" if run["result"] == "diagnostic" else "bad"
    )
    authority_label = html.escape(run["authority"])
    run_link = (
        f'<a href="{html.escape(run["url"], quote=True)}">Open exact CI run</a>'
        if run["url"] else "Local evidence"
    )
    stage_rows = "\n".join(
        f'<tr><td><code>{html.escape(stage["stage"])}</code></td>'
        f'<td><span class="status {status_class(stage["status"])}">{html.escape(stage["status"])}</span></td>'
        f'<td class="number">{stage["duration_seconds"]}</td>'
        f'<td><code>{html.escape(stage["log"])}</code></td></tr>'
        for stage in data["stages"]
    )
    journey_sections = "\n".join(
        '<article class="journey">'
        f'<div><span class="eyebrow">{html.escape(journey["capability"])}</span>'
        f'<h3>{html.escape(journey["id"])}</h3>'
        f'<p>{html.escape(journey["summary"])}</p></div>'
        f'<span class="status {status_class(journey["status"])}">{html.escape(journey["status"])}</span>'
        '<ul>'
        + "".join(
            f'<li><code>{html.escape(scenario["id"])}</code>'
            f'<span>{html.escape(scenario["evidence_status"])}</span></li>'
            for scenario in journey["scenario_evidence"]
        )
        + '</ul></article>'
        for journey in data["journeys"]
    ) or '<p class="empty">No user journey impact was recorded for this diagnostic stage.</p>'
    trend_rows = "\n".join(
        f'<tr><td><code>{html.escape(trend["commit"][:10])}</code></td>'
        f'<td>{html.escape(trend["authority"])}</td>'
        f'<td><span class="status {status_class(trend["result"])}">{html.escape(trend["result"])}</span></td>'
        f'<td class="number">{trend["wall_seconds"]}</td><td>{html.escape(trend["finished_at"])}</td></tr>'
        for trend in reversed(data["trends"])
    ) or '<tr><td colspan="5">No retained trend evidence.</td></tr>'
    capability_text = ", ".join(data["capabilities"]) or "none"
    specification_text = ", ".join(
        spec["id"] for spec in data["specifications"]
    ) or "none"
    promotion = run["promotion"]
    promotion_text = (
        f'Tested merge <code>{html.escape(run["tested_commit"])}</code> · '
        f'<a href="{html.escape(promotion["source_run_url"], quote=True)}">'
        f'PR run {html.escape(promotion["source_run"])}</a>'
        if isinstance(promotion, dict)
        else "Direct evidence for this commit"
    )
    coverage = quality["coverage"]
    if isinstance(coverage, dict):
        ui_coverage = coverage["suites"]["ui"]["line_coverage"]["percent"]
        business_coverage = coverage["suites"]["business"]["line_coverage"]["percent"]
        changed_coverage = coverage["changed_lines"]["line_coverage"]["percent"]
        coverage_text = (
            f"UI {ui_coverage:.2f}% · business {business_coverage:.2f}% · "
            f"changed lines {changed_coverage:.2f}%"
        )
    else:
        coverage_text = str(coverage)
    mutation = quality["mutation"]
    if isinstance(mutation, dict):
        mutation_text = (
            f'{mutation["score_percent"]}% · {mutation["killed"]}/{mutation["total"]} killed · '
            f'{mutation["status"]}'
        )
    else:
        mutation_text = str(mutation)
    care = quality["care"]
    if isinstance(care, dict):
        retained_failures = care["runs"]["failed_or_interrupted"]
        run_health = (
            f'{retained_failures} repaired failure'
            f'{"s" if retained_failures != 1 else ""} retained'
            if retained_failures
            else "latest run healthy"
        )
        eval_text = (
            f'{care["evals"]["passed"]}/{care["evals"]["total"]} passed · '
            f'{care["status"]} · {run_health} · source {care["source_commit"][:10]}'
        )
        latency_text = (
            f'p95 {care["latency"]["wall_p95_seconds"]}s · '
            f'alert {care["latency"]["alert_seconds"]}s · '
            f'SLO {care["latency"]["slo_seconds"]}s · '
            f'{care["latency"]["status"]}'
        )
    else:
        eval_text = latency_text = str(care)
    merge = quality["merge"]
    merge_text = (
        f'attempt {merge["repair_attempt"]} of {merge["maximum_repair_loops"]} · '
        f'{merge["status"]}'
        if isinstance(merge, dict)
        else str(merge)
    )
    security = quality["security"]
    security_text = (
        f'CodeQL {" + ".join(security["codeql_languages"])} · '
        f'{security["cadence"]} · outside PR feedback'
    )
    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light">
  <title>Detach quality — {html.escape(run["result"])}</title>
  <style>
    :root {{ --paper:#f3f0e8; --ink:#17211f; --muted:#62706b; --line:#c8cec8; --panel:#fffdf7; --accent:#d85b32; --good:#176b4b; --warn:#9a5b08; --bad:#a83232; }}
    * {{ box-sizing:border-box; }}
    body {{ margin:0; background:var(--paper); color:var(--ink); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
    a {{ color:var(--ink); text-underline-offset:3px; }}
    code,.number {{ font-family:"SFMono-Regular",Consolas,monospace; }}
    header,main,footer {{ width:min(1180px,calc(100% - 32px)); margin:auto; }}
    header {{ padding:38px 0 24px; border-bottom:2px solid var(--ink); display:grid; grid-template-columns:1fr auto; gap:24px; align-items:end; }}
    h1 {{ margin:3px 0 0; font-size:clamp(28px,5vw,58px); letter-spacing:-.045em; line-height:1; }}
    h2 {{ margin:0 0 18px; font-size:22px; }} h3 {{ margin:3px 0 6px; font-size:16px; }} p {{ margin:0; }}
    .eyebrow {{ color:var(--muted); font:700 11px/1.2 "SFMono-Regular",monospace; letter-spacing:.11em; text-transform:uppercase; }}
    .hero-status {{ text-align:right; }} .hero-status strong {{ display:block; font:700 22px/1.2 "SFMono-Regular",monospace; color:var(--{overall_class}); }}
    main {{ padding:24px 0 48px; }}
    .metrics {{ display:grid; grid-template-columns:repeat(5,minmax(0,1fr)); border:1px solid var(--line); background:var(--panel); }}
    .metric {{ padding:18px; border-right:1px solid var(--line); }} .metric:last-child {{ border:0; }} .metric strong {{ display:block; margin-top:5px; font-size:25px; }}
    section {{ margin-top:30px; }}
    .meta {{ display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px 24px; padding:18px 0; border-bottom:1px solid var(--line); }}
    .meta div {{ min-width:0; }} .meta code {{ overflow-wrap:anywhere; }}
    .status {{ font:700 11px/1 "SFMono-Regular",monospace; letter-spacing:.04em; text-transform:uppercase; }}
    .status.good {{ color:var(--good); }} .status.warn {{ color:var(--warn); }} .status.bad {{ color:var(--bad); }}
    .table-wrap {{ overflow:auto; border:1px solid var(--line); background:var(--panel); }}
    table {{ width:100%; border-collapse:collapse; }} th,td {{ padding:11px 13px; text-align:left; border-bottom:1px solid var(--line); white-space:nowrap; }} th {{ color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.07em; }} tr:last-child td {{ border-bottom:0; }} .number {{ text-align:right; }}
    .journeys {{ display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px; }}
    .journey {{ display:grid; grid-template-columns:1fr auto; gap:16px; padding:17px; background:var(--panel); border:1px solid var(--line); border-top:3px solid var(--accent); }}
    .journey ul {{ grid-column:1/-1; list-style:none; margin:4px 0 0; padding:0; border-top:1px solid var(--line); }}
    .journey li {{ display:flex; justify-content:space-between; gap:12px; padding:7px 0; border-bottom:1px solid var(--line); }} .journey li:last-child {{ border:0; }}
    .gaps {{ display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:1px; background:var(--line); border:1px solid var(--line); }} .gap {{ padding:14px; background:var(--panel); }}
    .empty {{ padding:20px; border:1px dashed var(--line); }}
    footer {{ padding:20px 0 36px; border-top:1px solid var(--line); color:var(--muted); }}
    #freshness.stale {{ color:var(--bad); font-weight:700; }}
    @media (max-width:850px) {{ .metrics {{ grid-template-columns:repeat(2,1fr); }} .metric {{ border-bottom:1px solid var(--line); }} .journeys {{ grid-template-columns:1fr; }} .gaps {{ grid-template-columns:repeat(2,1fr); }} }}
    @media (max-width:560px) {{ header {{ grid-template-columns:1fr; }} .hero-status {{ text-align:left; }} .metrics,.meta,.gaps {{ grid-template-columns:1fr; }} .metric {{ border-right:0; }} }}
    @media (prefers-reduced-motion:reduce) {{ * {{ scroll-behavior:auto!important; }} }}
  </style>
</head>
<body>
  <header>
    <div><span class="eyebrow">Quality control / policy {run["policy"]}</span><h1>Detach run evidence</h1></div>
    <div class="hero-status"><span class="eyebrow">{authority_label}</span><strong>{html.escape(run["result"]).upper()}</strong>{run_link}</div>
  </header>
  <main>
    <section class="metrics" aria-label="Run summary">
      <div class="metric"><span class="eyebrow">Wall time</span><strong>{run["wall_seconds"]}s</strong></div>
      <div class="metric"><span class="eyebrow">Scenario evidence</span><strong>{quality["scenario_percent"]}%</strong></div>
      <div class="metric"><span class="eyebrow">Verified scenarios</span><strong>{quality["passed_scenarios"]}/{quality["automatable_scenarios"]}</strong></div>
      <div class="metric"><span class="eyebrow">Planned gaps</span><strong>{quality["planned_scenarios"]}</strong></div>
      <div class="metric"><span class="eyebrow">Run p95</span><strong>{quality["run_wall_p95_seconds"]}s</strong></div>
    </section>
    <div class="meta">
      <div><span class="eyebrow">Commit</span><br><code>{html.escape(run["commit"])}</code></div>
      <div><span class="eyebrow">Fingerprint</span><br><code>{html.escape(run["fingerprint"])}</code></div>
      <div><span class="eyebrow">Specifications</span><br>{html.escape(specification_text)}</div>
      <div><span class="eyebrow">Capabilities</span><br>{html.escape(capability_text)}</div>
      <div><span class="eyebrow">Evidence provenance</span><br>{promotion_text}</div>
      <div><span class="eyebrow">Freshness</span><br><span id="freshness" data-finished="{html.escape(run["finished_at"], quote=True)}">{html.escape(run["finished_at"])}</span></div>
    </div>
    <section><h2>Stages</h2><div class="table-wrap"><table><thead><tr><th>Stage</th><th>Status</th><th class="number">Seconds</th><th>Log</th></tr></thead><tbody>{stage_rows}</tbody></table></div></section>
    <section><h2>User journeys</h2><div class="journeys">{journey_sections}</div></section>
    <section><h2>Quality signals</h2><div class="gaps">
      <div class="gap"><span class="eyebrow">Coverage</span><p>{html.escape(coverage_text)}</p></div>
      <div class="gap"><span class="eyebrow">Mutation</span><p>{html.escape(mutation_text)}</p></div>
      <div class="gap"><span class="eyebrow">Workflow evals</span><p>{html.escape(eval_text)}</p></div>
      <div class="gap"><span class="eyebrow">Feedback latency</span><p>{html.escape(latency_text)}</p></div>
      <div class="gap"><span class="eyebrow">Bounded merge</span><p>{html.escape(merge_text)}</p></div>
      <div class="gap"><span class="eyebrow">Security</span><p>{html.escape(security_text)}</p></div>
    </div></section>
    <section><h2>Recent runs</h2><div class="table-wrap"><table><thead><tr><th>Commit</th><th>Authority</th><th>Result</th><th class="number">Wall</th><th>Finished</th></tr></thead><tbody>{trend_rows}</tbody></table></div></section>
  </main>
  <footer>Generated from digest-bound quality evidence. No result is inferred from terminal text.</footer>
  <script>
    (() => {{ const node=document.getElementById('freshness'); const finished=Date.parse(node.dataset.finished); if (!Number.isFinite(finished)) return; const hours=(Date.now()-finished)/36e5; if (hours>24) {{ node.classList.add('stale'); node.textContent=`STALE · ${{Math.floor(hours)}}h · ${{node.dataset.finished}}`; }} }})();
  </script>
</body>
</html>
'''


def atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.is_symlink():
        raise DashboardError(f"output target is a symlink: {path}")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_bytes(content)
    os.chmod(temporary, 0o644)
    os.replace(temporary, path)


def generate(arguments: argparse.Namespace) -> int:
    result_root = arguments.result_root.resolve()
    run_dir = arguments.run.resolve() if arguments.run else latest_run(result_root)
    if run_dir.parent != result_root:
        raise DashboardError("run must be directly under the selected result root")
    mutation_summary = arguments.mutation_summary.resolve() if arguments.mutation_summary else None
    care_summary = arguments.care_summary.resolve() if arguments.care_summary else None
    data = build_data(
        run_dir, result_root, arguments.run_url, mutation_summary, care_summary
    )
    output = arguments.output.resolve()
    if output == Path("/") or output == ROOT:
        raise DashboardError("dashboard output path is too broad")
    rendered_data = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")
    rendered_html = render_html(data).encode("utf-8")
    atomic_write(output / "data.json", rendered_data)
    atomic_write(output / "index.html", rendered_html)
    print(f"quality-dashboard: generated {output / 'index.html'}")
    return 0


def serve(arguments: argparse.Namespace) -> int:
    root = arguments.directory.resolve()
    safe_file(root / "index.html", "dashboard index")
    if arguments.seconds < 1 or arguments.seconds > 3600:
        raise DashboardError("serve timeout must be from 1 to 3600 seconds")
    handler = lambda *args, **kwargs: SimpleHTTPRequestHandler(  # noqa: E731
        *args, directory=str(root), **kwargs
    )
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), handler)
    timer = threading.Timer(arguments.seconds, server.shutdown)
    timer.daemon = True
    timer.start()
    host, port = server.server_address
    print(f"quality-dashboard: http://{host}:{port}/ (stops after {arguments.seconds}s)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        timer.cancel()
        server.server_close()
    return 0


def parser() -> argparse.ArgumentParser:
    command_parser = argparse.ArgumentParser(prog="scripts/quality-dashboard")
    commands = command_parser.add_subparsers(dest="command", required=True)
    generate_parser = commands.add_parser("generate", help="generate static dashboard files")
    generate_parser.add_argument("--result-root", type=Path, default=DEFAULT_RESULT_ROOT)
    generate_parser.add_argument("--run", type=Path)
    generate_parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    generate_parser.add_argument("--run-url", default="")
    generate_parser.add_argument("--mutation-summary", type=Path)
    generate_parser.add_argument("--care-summary", type=Path)
    generate_parser.set_defaults(function=generate)
    serve_parser = commands.add_parser("serve", help="serve a generated dashboard for a bounded time")
    serve_parser.add_argument("--directory", type=Path, default=DEFAULT_OUTPUT)
    serve_parser.add_argument("--port", type=int, default=8765)
    serve_parser.add_argument("--seconds", type=int, default=300)
    serve_parser.set_defaults(function=serve)
    return command_parser


def main() -> int:
    arguments = parser().parse_args()
    return arguments.function(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DashboardError as error:
        fail(str(error))
