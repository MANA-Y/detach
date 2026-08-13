#!/usr/bin/env python3
"""Static fail-closed contracts for repository security automation."""

from __future__ import annotations

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from swift_codeql_build import SCOPES, SWIFT_BUILD_OPTIONS, source_files  # noqa: E402


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
    cache = workflow.index("Restore the Swift dependency graph")
    resolve = workflow.index("Resolve the locked Swift dependencies")
    clean = workflow.index("Remove cached products before tracing")
    prepare = workflow.index("Prepare Swift compiler plan outside tracing")
    swift_init = workflow.index("Initialize Swift analysis")
    trace = workflow.index("Trace generated Swift compiler plan")
    swift_analyze = workflow.index("Analyze Swift scope")
    require(cache < resolve < clean < prepare < swift_init < trace < swift_analyze,
            "Swift preparation, direct tracing, and analysis are out of order")
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
    require(SCOPES == {
        "kit": ("DetachKit",),
        "app": ("DetachApp",),
        "processes": (
            "DetachPower", "DetachPowerHelper", "DetachState", "DetachWatchdog"
        ),
    }, "direct Swift compiler scopes do not cover every production module")
    scoped_modules = {module for modules in SCOPES.values() for module in modules}
    repository_modules = {
        path.name
        for path in (ROOT / "app/Sources").iterdir()
        if path.is_dir() and list(path.rglob("*.swift"))
    }
    require(scoped_modules == repository_modules,
            "direct Swift compiler scopes do not match the production source tree")
    require(sum(len(source_files(ROOT / "app", module)) for module in scoped_modules) > 0,
            "direct Swift compiler scopes contain no production source")
    require("category: /language:swift-${{ matrix.scope }}" in workflow,
            "Swift scopes must publish distinct CodeQL categories")
    options = list(SWIFT_BUILD_OPTIONS)
    require(options[options.index("--arch") + 1] == "arm64",
            "Swift analysis must build only arm64")
    require(options[options.index("--jobs") + 1] == "3",
            "Swift preparation must match the three-thread extractor")
    for option in ("--disable-index-store", "--disable-sandbox",
                   "--force-resolved-versions", "-whole-module-optimization",
                   "-num-threads", "-gnone"):
        require(option in options, f"Swift preparation is missing {option}")
    require("python3 tools/swift_codeql_build.py prepare" in workflow,
            "Swift preparation must use the tested Python boundary")
    require("python3 tools/swift_codeql_build.py trace" in workflow,
            "Swift tracing must use the tested Python boundary")
    require("--timeout-seconds 180" in workflow,
            "Swift preparation deadline is missing")
    require("--timeout-seconds 600" in workflow,
            "Swift tracing deadline is missing")
    require("swift build" not in workflow[swift_init:swift_analyze],
            "SwiftPM must stay outside the CodeQL traced zone")
    for module in scoped_modules:
        require(module not in workflow,
                f"workflow duplicates the Python module map: {module}")
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
