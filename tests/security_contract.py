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
