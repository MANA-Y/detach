#!/usr/bin/env python3
"""Static fail-closed contracts for repository security automation."""

from __future__ import annotations

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/security.yml"
DEPENDABOT = ROOT / ".github/dependabot.yml"
PINNED_ACTION = re.compile(r"(?:-\s+)?uses:\s+[^\s@]+@[0-9a-f]{40}(?:\s+#\s+v[0-9]+)?$")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    dependabot = DEPENDABOT.read_text(encoding="utf-8")
    uses = [line.strip() for line in workflow.splitlines() if "uses:" in line]
    require(uses and all(PINNED_ACTION.fullmatch(line) for line in uses),
            "every security Action must use an immutable commit")
    require("languages: actions" in workflow, "workflow analysis is missing")
    require("languages: swift" in workflow, "Swift analysis is missing")
    require("build-mode: manual" in workflow, "Swift must use an explicit build")
    require("--arch arm64" in workflow, "Swift analysis must build only arm64")
    cache = workflow.index("Restore the Swift dependency graph")
    resolve = workflow.index("Resolve the locked Swift dependencies")
    clean = workflow.index("Remove cached products before tracing")
    prepare = workflow.index("Prepare shared Swift source outside scope tracing")
    swift_init = workflow.index("Initialize Swift analysis")
    kit_build = workflow.index("Build Swift kit source for analysis")
    swift_build = workflow.index("Build Swift app source for analysis")
    process_build = workflow.index("Build Swift process entry points for analysis")
    swift_analyze = workflow.index("Analyze Swift scope")
    require(cache < resolve < clean < prepare < swift_init < kit_build < swift_build
            < process_build < swift_analyze,
            "Swift preparation, target builds, and analysis are out of order")
    require("actions/cache/restore@0057852bfaa89a56745cba8c7296529d2fc39830" in workflow,
            "Swift analysis must restore the immutable quality-gate cache")
    require("swift package --package-path app --force-resolved-versions resolve" in workflow,
            "Swift analysis must resolve the tracked lock before tracing")
    require("swift package --package-path app clean" in workflow,
            "Swift analysis must rebuild repository sources after cache restore")
    require("scope: [kit, app, processes]" in workflow,
            "Swift analysis must cover the kit, app, and process scopes")
    require("max-parallel: 3" in workflow and "fail-fast: false" in workflow,
            "Swift analysis scopes must run independently with bounded fan-out")
    require("if: matrix.scope != 'kit'" in workflow,
            "app and process scopes must prepare shared source before tracing")
    for scope in ("kit", "app", "processes"):
        require(f"if: matrix.scope == '{scope}'" in workflow,
                f"Swift analysis is missing its {scope} scope condition")
    require("category: /language:swift-${{ matrix.scope }}" in workflow,
            "Swift scopes must publish distinct CodeQL categories")
    require(workflow.count("--force-resolved-versions") == 8,
            "Swift resolve, preparation, and every scope build must reject lock drift")
    require(workflow.count("--jobs 3") == 7,
            "Swift target builds must match the three-thread extractor")
    require(workflow.count("--disable-index-store") == 7,
            "Swift security builds must not pay for unused index data")
    require(workflow.count("--target DetachKit") == 2,
            "shared Swift source needs one preparation and one traced build command")
    for target in ("DetachApp", "DetachPower", "DetachPowerHelper",
                   "DetachState", "DetachWatchdog"):
        require(f"--target {target}" in workflow,
                f"Swift analysis is missing target {target}")
    require("timeout-minutes: 5" in workflow, "workflow analysis deadline is missing")
    require("timeout-minutes: 15" in workflow, "Swift analysis deadline is missing")
    require("security-events: write" in workflow, "CodeQL cannot publish results")
    require("pull_request:" not in workflow, "security care must not extend PR feedback")
    require("release-version" not in workflow and "notary" not in workflow,
            "security care can enter a release path")
    require("version: 2" in dependabot, "Dependabot schema is missing")
    require("package-ecosystem: github-actions" in dependabot,
            "GitHub Actions updates are missing")
    require("package-ecosystem: swift" in dependabot,
            "Swift updates are missing")
    require("directory: /app" in dependabot, "Swift package directory is wrong")
    require(dependabot.count("interval: weekly") == 2,
            "dependency updates must use one bounded weekly cadence")
    require(dependabot.count("open-pull-requests-limit: 1") == 2,
            "each dependency ecosystem must allow only one open update pull request")
    require("actions:" in dependabot and "swift-packages:" in dependabot,
            "dependency updates must be grouped by ecosystem")
    require(dependabot.count('          - "*"') == 2,
            "each dependency group must cover its complete ecosystem")
    print("Security automation contracts passed")


if __name__ == "__main__":
    main()
