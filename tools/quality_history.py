#!/usr/bin/env python3
"""Report timing and failure telemetry from current-schema quality evidence."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any, NoReturn

from quality_dashboard import (
    DashboardError,
    MANIFEST_SCHEMA,
    read_manifest,
    read_summary,
)


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RESULT_ROOT = ROOT / "app/build/quality-gates"
FAILURES = {"failed", "environment-failed", "timeout", "interrupted"}


class HistoryError(Exception):
    """Retained evidence cannot produce trustworthy run telemetry."""


def fail(message: str) -> NoReturn:
    print(f"quality-history: {message}", file=sys.stderr)
    raise SystemExit(2)


def percentile(values: list[int], percent: int) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = (len(ordered) * percent + 99) // 100
    return ordered[max(0, index - 1)]


def uses_unsupported_schema(run_dir: Path) -> bool:
    manifest = run_dir / "manifest.tsv"
    if not manifest.is_file() or manifest.is_symlink():
        return False
    try:
        lines = manifest.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return False
    if not lines:
        return False
    fields = lines[0].split("\t")
    return (
        len(fields) == 2
        and fields[0] == "schema"
        and fields[1].isdigit()
        and fields[1] != MANIFEST_SCHEMA
    )


def collect(result_root: Path) -> dict[str, Any]:
    if not result_root.is_dir() or result_root.is_symlink():
        raise HistoryError("result root is missing or unsafe")
    walls: list[int] = []
    stage_values: dict[str, list[tuple[int, str]]] = {}
    runs = 0
    passed = 0
    invalid = 0
    for run_dir in sorted(result_root.iterdir()):
        if not run_dir.is_dir() or run_dir.is_symlink():
            continue
        if uses_unsupported_schema(run_dir):
            continue
        try:
            manifest = read_manifest(run_dir, require_dashboard_fields=False)
            stages = read_summary(run_dir, manifest)
        except (DashboardError, OSError, UnicodeError):
            invalid += 1
            continue
        if manifest["result"] not in ("passed", "failed", "interrupted"):
            continue
        runs += 1
        passed += int(manifest["result"] == "passed")
        walls.append(int(manifest["timing_wall_seconds"]))
        for stage in stages:
            if stage["status"] in ("reused", "blocked"):
                continue
            stage_values.setdefault(stage["stage"], []).append(
                (stage["duration_seconds"], stage["status"])
            )
    if not runs:
        raise HistoryError("no valid completed current-schema evidence found")
    stages = []
    for name, records in sorted(stage_values.items()):
        durations = [duration for duration, _ in records]
        stages.append(
            {
                "environment_failures": sum(
                    status == "environment-failed" for _, status in records
                ),
                "failures": sum(status in FAILURES for _, status in records),
                "p50_seconds": percentile(durations, 50),
                "p95_seconds": percentile(durations, 95),
                "samples": len(records),
                "stage": name,
            }
        )
    return {
        "schema": 1,
        "runs": runs,
        "passed": passed,
        "failed_or_interrupted": runs - passed,
        "invalid_evidence": invalid,
        "wall": {
            "samples": len(walls),
            "p50_seconds": percentile(walls, 50),
            "p95_seconds": percentile(walls, 95),
        },
        "stages": stages,
    }


def render_tsv(document: dict[str, Any]) -> str:
    lines = [
        f"runs\t{document['runs']}",
        f"passed\t{document['passed']}",
        f"failed_or_interrupted\t{document['failed_or_interrupted']}",
        f"invalid_evidence\t{document['invalid_evidence']}",
        f"wall_p50_seconds\t{document['wall']['p50_seconds']}",
        f"wall_p95_seconds\t{document['wall']['p95_seconds']}",
        "",
        "stage\tsamples\tfailures\tenvironment_failures\tp50_seconds\tp95_seconds",
    ]
    lines.extend(
        "\t".join(
            str(stage[key])
            for key in (
                "stage",
                "samples",
                "failures",
                "environment_failures",
                "p50_seconds",
                "p95_seconds",
            )
        )
        for stage in document["stages"]
    )
    return "\n".join(lines) + "\n"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("result_root", nargs="?", type=Path, default=DEFAULT_RESULT_ROOT)
    result.add_argument("--format", choices=("tsv", "json"), default="tsv")
    return result


def main() -> int:
    arguments = parser().parse_args()
    document = collect(arguments.result_root.resolve())
    if arguments.format == "json":
        print(json.dumps(document, indent=2, sort_keys=True))
    else:
        print(render_tsv(document), end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (HistoryError, OSError, UnicodeError) as error:
        fail(str(error))
