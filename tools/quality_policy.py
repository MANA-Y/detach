#!/usr/bin/env python3
"""Validate and query Detach's single quality-policy manifest."""

from __future__ import annotations

import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable, NoReturn


ROOT = Path(__file__).resolve().parent.parent
POLICY_FILE = Path(os.environ.get("DETACH_QUALITY_POLICY", ROOT / "quality/policy.tsv"))
IDENTIFIER = re.compile(r"^[a-z0-9-]+$")
LIMIT_NAME = re.compile(r"^[a-z][a-z0-9_]*$")
ROUTE_PATTERN = re.compile(r"^[A-Za-z0-9_.*\/-]+$")
SPEC_PATH = re.compile(r"^docs/specs/[a-z0-9-]+\.md$")
SOURCE_PATH = re.compile(r"^app/Sources/[A-Za-z0-9_./-]+\.swift$")
REQUIREMENT_ID = re.compile(r"^QC-[A-Z0-9-]+$")
JOURNEY_ID = re.compile(r"^J-[A-Z0-9-]+$")
SCENARIO_ID = re.compile(r"^SC-[A-Z0-9-]+$")
SUITE_NAME = re.compile(r"^[A-Za-z0-9]+\.[A-Za-z0-9]+$")
POSITIVE_INTEGER = re.compile(r"^[1-9][0-9]*$")


class PolicyError(Exception):
    """A fail-closed policy validation or query error."""


@dataclass(frozen=True)
class Stage:
    order: int
    name: str
    timeout: int
    release: bool


@dataclass(frozen=True)
class Route:
    priority: int
    pattern: str
    test_domain: str
    release_domain: str
    spec: str


@dataclass(frozen=True)
class Classification:
    status: str
    test_domain: str
    release_domain: str
    spec: str
    stages: str
    release_gates: str
    unknown: bool
    pattern: str
    priority: int
    capabilities: str
    journeys: str

    def tsv(self) -> str:
        return "\t".join(
            (
                self.status,
                self.test_domain,
                self.release_domain,
                self.spec,
                self.stages,
                self.release_gates,
                str(self.unknown).lower(),
                self.pattern,
                str(self.priority),
                self.capabilities,
                self.journeys,
            )
        )


class Policy:
    def __init__(self, path: Path) -> None:
        if not path.is_file() or path.is_symlink():
            raise PolicyError("policy must be a regular, non-symlink file")
        self.path = path
        self.schema: int | None = None
        self.version: int | None = None
        self.limits: dict[str, int] = {}
        self.stages_by_name: dict[str, Stage] = {}
        self.stage_orders: set[int] = set()
        self.dependencies: list[tuple[str, str]] = []
        self.test_domains: dict[str, tuple[str, str]] = {}
        self.release_domains: dict[str, tuple[str, bool]] = {}
        self.coverage_exclusions: list[tuple[str, str, str, str]] = []
        self.routes: list[Route] = []
        self.capabilities: dict[str, tuple[str, str, str]] = {}
        self.journeys: dict[str, tuple[str, str, str, str]] = {}
        self.scenarios: dict[str, tuple[str, str, str]] = {}
        self.critical: list[tuple[str, str]] = []
        self.required_suites: list[str] = []
        self.requirements: dict[str, tuple[str, str]] = {}
        self._parse()
        self._validate_references()

    @property
    def stages(self) -> list[Stage]:
        return sorted(self.stages_by_name.values(), key=lambda stage: stage.order)

    @property
    def all_stages_csv(self) -> str:
        return ",".join(stage.name for stage in self.stages)

    @staticmethod
    def _csv(value: str, *, allow_dash: bool = False) -> bool:
        if allow_dash and value == "-":
            return True
        names = value.split(",")
        return bool(names) and all(IDENTIFIER.fullmatch(name) for name in names)

    @staticmethod
    def _boolean(value: str, line: int) -> bool:
        if value not in ("true", "false"):
            raise PolicyError(f"line {line}: expected true or false")
        return value == "true"

    @staticmethod
    def _unique(mapping: dict[str, object], key: str, label: str, line: int) -> None:
        if key in mapping:
            raise PolicyError(f"line {line}: duplicate {label}: {key}")

    def _parse(self) -> None:
        try:
            lines = self.path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            raise PolicyError(f"cannot read policy: {error}") from error
        if not lines:
            raise PolicyError("policy is empty")
        critical_paths: set[str] = set()
        coverage_patterns: set[str] = set()
        dependency_pairs: set[tuple[str, str]] = set()
        for line_number, line in enumerate(lines, 1):
            if not line:
                raise PolicyError(f"line {line_number}: blank records are not allowed")
            fields = line.split("\t")
            kind = fields[0]
            values = fields[1:]
            if kind == "schema":
                self._expect_count(kind, values, 1, line_number)
                if self.schema is not None or values[0] != "1":
                    raise PolicyError(f"line {line_number}: schema must occur once and equal 1")
                self.schema = 1
            elif kind == "policy":
                self._expect_count(kind, values, 1, line_number)
                if self.version is not None or not POSITIVE_INTEGER.fullmatch(values[0]):
                    raise PolicyError(f"line {line_number}: policy must be one positive integer")
                self.version = int(values[0])
            elif kind == "limit":
                self._expect_count(kind, values, 2, line_number)
                name, raw_value = values
                if not LIMIT_NAME.fullmatch(name) or not POSITIVE_INTEGER.fullmatch(raw_value):
                    raise PolicyError(f"line {line_number}: invalid limit")
                self._unique(self.limits, name, "limit", line_number)
                self.limits[name] = int(raw_value)
            elif kind == "stage":
                self._expect_count(kind, values, 4, line_number)
                raw_order, name, raw_timeout, raw_release = values
                if (
                    not POSITIVE_INTEGER.fullmatch(raw_order)
                    or not IDENTIFIER.fullmatch(name)
                    or not POSITIVE_INTEGER.fullmatch(raw_timeout)
                ):
                    raise PolicyError(f"line {line_number}: invalid stage")
                order = int(raw_order)
                self._unique(self.stages_by_name, name, "stage", line_number)
                if order in self.stage_orders:
                    raise PolicyError(f"line {line_number}: duplicate stage order: {order}")
                self.stage_orders.add(order)
                self.stages_by_name[name] = Stage(
                    order, name, int(raw_timeout), self._boolean(raw_release, line_number)
                )
            elif kind == "dependency":
                self._expect_count(kind, values, 2, line_number)
                pair = (values[0], values[1])
                if not all(IDENTIFIER.fullmatch(name) for name in pair) or pair in dependency_pairs:
                    raise PolicyError(f"line {line_number}: invalid or duplicate dependency")
                dependency_pairs.add(pair)
                self.dependencies.append(pair)
            elif kind == "test-domain":
                self._expect_count(kind, values, 3, line_number)
                name, stages, capabilities = values
                if (
                    not IDENTIFIER.fullmatch(name)
                    or not (stages == "*" or self._csv(stages))
                    or not (capabilities == "*" or self._csv(capabilities))
                ):
                    raise PolicyError(f"line {line_number}: invalid test domain")
                self._unique(self.test_domains, name, "test domain", line_number)
                self.test_domains[name] = (stages, capabilities)
            elif kind == "release-domain":
                self._expect_count(kind, values, 3, line_number)
                name, gates, raw_unknown = values
                if not IDENTIFIER.fullmatch(name) or not self._csv(gates, allow_dash=True):
                    raise PolicyError(f"line {line_number}: invalid release domain")
                if gates != "-" and any(gate not in ("install", "lid") for gate in gates.split(",")):
                    raise PolicyError(f"line {line_number}: unknown release gate")
                self._unique(self.release_domains, name, "release domain", line_number)
                self.release_domains[name] = (gates, self._boolean(raw_unknown, line_number))
            elif kind == "coverage-exclusion":
                self._expect_count(kind, values, 4, line_number)
                group, pattern, scenarios, summary = values
                expected_prefix = {
                    "ui": "app/Sources/DetachApp/",
                    "business": "app/Sources/DetachKit/",
                }.get(group)
                if (
                    expected_prefix is None
                    or not ROUTE_PATTERN.fullmatch(pattern)
                    or not pattern.startswith(expected_prefix)
                    or not pattern.endswith(".swift")
                    or not self._references(scenarios, SCENARIO_ID)
                    or not summary
                    or pattern in coverage_patterns
                ):
                    raise PolicyError(
                        f"line {line_number}: invalid or duplicate coverage exclusion"
                    )
                coverage_patterns.add(pattern)
                self.coverage_exclusions.append((group, pattern, scenarios, summary))
            elif kind == "route":
                self._expect_count(kind, values, 5, line_number)
                raw_priority, pattern, test_domain, release_domain, spec = values
                if (
                    not POSITIVE_INTEGER.fullmatch(raw_priority)
                    or not ROUTE_PATTERN.fullmatch(pattern)
                    or not IDENTIFIER.fullmatch(test_domain)
                    or not IDENTIFIER.fullmatch(release_domain)
                    or not SPEC_PATH.fullmatch(spec)
                ):
                    raise PolicyError(f"line {line_number}: invalid route")
                self.routes.append(Route(int(raw_priority), pattern, test_domain, release_domain, spec))
            elif kind == "capability":
                self._expect_count(kind, values, 4, line_number)
                identifier, spec, requirements, journeys = values
                if (
                    not IDENTIFIER.fullmatch(identifier)
                    or not SPEC_PATH.fullmatch(spec)
                    or not self._references(requirements, REQUIREMENT_ID, allow_dash=True)
                    or not self._references(journeys, JOURNEY_ID)
                ):
                    raise PolicyError(f"line {line_number}: invalid capability")
                self._unique(self.capabilities, identifier, "capability", line_number)
                self.capabilities[identifier] = (spec, requirements, journeys)
            elif kind == "journey":
                self._expect_count(kind, values, 5, line_number)
                identifier, capability, requirements, scenarios, summary = values
                if (
                    not JOURNEY_ID.fullmatch(identifier)
                    or not IDENTIFIER.fullmatch(capability)
                    or not self._references(requirements, REQUIREMENT_ID, allow_dash=True)
                    or not self._references(scenarios, SCENARIO_ID)
                    or not summary
                ):
                    raise PolicyError(f"line {line_number}: invalid journey")
                self._unique(self.journeys, identifier, "journey", line_number)
                self.journeys[identifier] = (capability, requirements, scenarios, summary)
            elif kind == "scenario":
                self._expect_count(kind, values, 4, line_number)
                identifier, stage, status, command = values
                if (
                    not SCENARIO_ID.fullmatch(identifier)
                    or not IDENTIFIER.fullmatch(stage)
                    or status not in (
                        "instrumented",
                        "automated",
                        "legacy-stage",
                        "planned",
                        "manual-release",
                    )
                    or not command
                ):
                    raise PolicyError(f"line {line_number}: invalid scenario")
                self._unique(self.scenarios, identifier, "scenario", line_number)
                self.scenarios[identifier] = (stage, status, command)
            elif kind == "critical":
                self._expect_count(kind, values, 2, line_number)
                source, requirement = values
                if (
                    not SOURCE_PATH.fullmatch(source)
                    or not REQUIREMENT_ID.fullmatch(requirement)
                    or source in critical_paths
                ):
                    raise PolicyError(f"line {line_number}: invalid or duplicate critical source")
                critical_paths.add(source)
                self.critical.append((source, requirement))
            elif kind == "suite":
                self._expect_count(kind, values, 1, line_number)
                suite = values[0]
                if not SUITE_NAME.fullmatch(suite) or suite in self.required_suites:
                    raise PolicyError(f"line {line_number}: invalid or duplicate required suite")
                self.required_suites.append(suite)
            elif kind == "requirement":
                self._expect_count(kind, values, 3, line_number)
                identifier, spec, summary = values
                if (
                    not REQUIREMENT_ID.fullmatch(identifier)
                    or not SPEC_PATH.fullmatch(spec)
                    or not summary
                ):
                    raise PolicyError(f"line {line_number}: invalid requirement")
                self._unique(self.requirements, identifier, "requirement", line_number)
                self.requirements[identifier] = (spec, summary)
            else:
                raise PolicyError(f"line {line_number}: unsupported record: {kind}")

    @staticmethod
    def _expect_count(kind: str, values: list[str], expected: int, line: int) -> None:
        if len(values) != expected:
            raise PolicyError(f"line {line}: {kind} requires {expected} values")

    @staticmethod
    def _references(value: str, pattern: re.Pattern[str], *, allow_dash: bool = False) -> bool:
        if allow_dash and value == "-":
            return True
        references = value.split(",")
        return bool(references) and all(pattern.fullmatch(reference) for reference in references)

    def _validate_references(self) -> None:
        if self.schema != 1 or self.version is None:
            raise PolicyError("schema and policy records are required")
        if "static" not in self.stages_by_name:
            raise PolicyError("static stage is required")
        if "unknown" not in self.test_domains or "unknown" not in self.release_domains:
            raise PolicyError("unknown test and release domains are required")
        for prerequisite, dependent in self.dependencies:
            if (
                prerequisite not in self.stages_by_name
                or dependent not in self.stages_by_name
                or prerequisite == dependent
            ):
                raise PolicyError(f"unresolved dependency: {prerequisite} -> {dependent}")
        for domain, (stages, capabilities) in self.test_domains.items():
            if stages == "*":
                pass
            else:
                for stage in stages.split(","):
                    if stage not in self.stages_by_name:
                        raise PolicyError(f"test domain {domain} references unknown stage: {stage}")
            if capabilities != "*":
                for capability in capabilities.split(","):
                    if capability not in self.capabilities:
                        raise PolicyError(
                            f"test domain {domain} references unknown capability: {capability}"
                        )
        for route in self.routes:
            if route.test_domain not in self.test_domains:
                raise PolicyError(f"route references unknown test domain: {route.test_domain}")
            if route.release_domain not in self.release_domains:
                raise PolicyError(f"route references unknown release domain: {route.release_domain}")
        for source, requirement in self.critical:
            if requirement not in self.requirements:
                raise PolicyError(f"critical source {source} references unknown requirement: {requirement}")
            if self.coverage_exclusion(source) is not None:
                raise PolicyError(f"critical source cannot be excluded from coverage: {source}")
        for _, pattern, scenarios, _ in self.coverage_exclusions:
            for scenario in scenarios.split(","):
                if scenario not in self.scenarios:
                    raise PolicyError(
                        f"coverage exclusion {pattern} references unknown scenario: {scenario}"
                    )
                if self.scenarios[scenario][1] in ("planned", "manual-release"):
                    raise PolicyError(
                        f"coverage exclusion {pattern} requires an automated scenario: {scenario}"
                    )
        if not self.required_suites:
            raise PolicyError("at least one required Swift suite is required")
        referenced_requirements: set[str] = {requirement for _, requirement in self.critical}
        referenced_journeys: set[str] = set()
        referenced_scenarios: set[str] = set()
        for capability, (_, requirements, journeys) in self.capabilities.items():
            if requirements != "-":
                for requirement in requirements.split(","):
                    if requirement not in self.requirements:
                        raise PolicyError(
                            f"capability {capability} references unknown requirement: {requirement}"
                        )
                    referenced_requirements.add(requirement)
            for journey in journeys.split(","):
                if journey not in self.journeys:
                    raise PolicyError(f"capability {capability} references unknown journey: {journey}")
                if self.journeys[journey][0] != capability:
                    raise PolicyError(f"journey {journey} belongs to another capability")
                referenced_journeys.add(journey)
        for journey, (capability, requirements, scenarios, _) in self.journeys.items():
            if capability not in self.capabilities:
                raise PolicyError(f"journey {journey} references unknown capability: {capability}")
            if requirements != "-":
                for requirement in requirements.split(","):
                    if requirement not in self.requirements:
                        raise PolicyError(
                            f"journey {journey} references unknown requirement: {requirement}"
                        )
                    referenced_requirements.add(requirement)
            for scenario in scenarios.split(","):
                if scenario not in self.scenarios:
                    raise PolicyError(f"journey {journey} references unknown scenario: {scenario}")
                referenced_scenarios.add(scenario)
        for scenario, (stage, _, _) in self.scenarios.items():
            if stage not in self.stages_by_name:
                raise PolicyError(f"scenario {scenario} references unknown stage: {stage}")
        orphan_journeys = set(self.journeys) - referenced_journeys
        orphan_scenarios = set(self.scenarios) - referenced_scenarios
        orphan_requirements = set(self.requirements) - referenced_requirements
        if orphan_journeys:
            raise PolicyError(f"orphan journey: {sorted(orphan_journeys)[0]}")
        if orphan_scenarios:
            raise PolicyError(f"orphan scenario: {sorted(orphan_scenarios)[0]}")
        if orphan_requirements:
            raise PolicyError(f"orphan requirement: {sorted(orphan_requirements)[0]}")

    def classify(self, path: str) -> Classification:
        matches = [route for route in self.routes if fnmatch.fnmatchcase(path, route.pattern)]
        if not matches:
            gates, unknown = self.release_domains["unknown"]
            return Classification(
                "unknown", "unknown", "unknown", "-", self.all_stages_csv,
                gates, unknown, "-", 0, ",".join(self.capabilities), ",".join(self.journeys)
            )
        priority = max(route.priority for route in matches)
        winners = [route for route in matches if route.priority == priority]
        if len(winners) != 1:
            raise PolicyError(f"path has {len(winners)} equal-priority routes: {path}")
        route = winners[0]
        stages, capabilities = self.test_domains[route.test_domain]
        if stages == "*":
            stages = self.all_stages_csv
        if capabilities == "*":
            capabilities = ",".join(self.capabilities)
        selected_journeys: list[str] = []
        for capability in capabilities.split(","):
            for journey in self.capabilities[capability][2].split(","):
                if journey not in selected_journeys:
                    selected_journeys.append(journey)
        gates, unknown = self.release_domains[route.release_domain]
        return Classification(
            "known", route.test_domain, route.release_domain, route.spec, stages,
            gates, unknown, route.pattern, route.priority, capabilities,
            ",".join(selected_journeys)
        )

    def coverage_exclusion(self, path: str) -> str | None:
        matches = [
            group
            for group, pattern, _, _ in self.coverage_exclusions
            if fnmatch.fnmatchcase(path, pattern)
        ]
        if len(matches) > 1:
            raise PolicyError(f"source has overlapping coverage exclusions: {path}")
        return matches[0] if matches else None

    def tracked_paths(self) -> Iterable[str]:
        try:
            result = subprocess.run(
                (
                    "git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others",
                    "--exclude-standard",
                ),
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise PolicyError(f"cannot list repository paths: {error}") from error
        for raw_path in result.stdout.split(b"\0"):
            if raw_path:
                yield os.fsdecode(raw_path)

    def validate_tracked_paths(self) -> None:
        paths = list(self.tracked_paths())
        for path in paths:
            classification = self.classify(path)
            if classification.status != "known":
                raise PolicyError(f"unclassified tracked path: {path}")
            self.coverage_exclusion(path)
        for _, pattern, _, _ in self.coverage_exclusions:
            if not any(fnmatch.fnmatchcase(path, pattern) for path in paths):
                raise PolicyError(f"orphan coverage exclusion: {pattern}")

    def document(self) -> dict[str, object]:
        return {
            "schema": self.schema,
            "policy": self.version,
            "limits": self.limits,
            "stages": [
                {
                    "order": stage.order,
                    "name": stage.name,
                    "timeout_seconds": stage.timeout,
                    "release": stage.release,
                }
                for stage in self.stages
            ],
            "dependencies": [
                {"prerequisite": prerequisite, "dependent": dependent}
                for prerequisite, dependent in self.dependencies
            ],
            "test_domains": [
                {"id": identifier, "stages": stages, "capabilities": capabilities}
                for identifier, (stages, capabilities) in self.test_domains.items()
            ],
            "release_domains": [
                {"id": identifier, "gates": gates, "unknown": unknown}
                for identifier, (gates, unknown) in self.release_domains.items()
            ],
            "coverage_exclusions": [
                {
                    "group": group,
                    "pattern": pattern,
                    "scenarios": scenarios.split(","),
                    "summary": summary,
                }
                for group, pattern, scenarios, summary in self.coverage_exclusions
            ],
            "routes": [
                {
                    "priority": route.priority,
                    "pattern": route.pattern,
                    "test_domain": route.test_domain,
                    "release_domain": route.release_domain,
                    "spec": route.spec,
                }
                for route in self.routes
            ],
            "capabilities": [
                {
                    "id": identifier,
                    "spec": spec,
                    "requirements": self._list_or_empty(requirements),
                    "journeys": journeys.split(","),
                }
                for identifier, (spec, requirements, journeys) in self.capabilities.items()
            ],
            "journeys": [
                {
                    "id": identifier,
                    "capability": capability,
                    "requirements": self._list_or_empty(requirements),
                    "scenarios": scenarios.split(","),
                    "summary": summary,
                }
                for identifier, (capability, requirements, scenarios, summary) in self.journeys.items()
            ],
            "scenarios": [
                {
                    "id": identifier,
                    "stage": stage,
                    "status": status,
                    "command": command,
                }
                for identifier, (stage, status, command) in self.scenarios.items()
            ],
            "critical_sources": [
                {"path": path, "requirement": requirement}
                for path, requirement in self.critical
            ],
            "required_suites": self.required_suites,
            "requirements": [
                {"id": identifier, "spec": spec, "summary": summary}
                for identifier, (spec, summary) in self.requirements.items()
            ],
        }

    @staticmethod
    def _list_or_empty(value: str) -> list[str]:
        return [] if value == "-" else value.split(",")


def usage(stream: object = sys.stdout) -> None:
    print(
        """usage: scripts/quality-policy validate
       scripts/quality-policy version
       scripts/quality-policy stages all|release
       scripts/quality-policy timeout STAGE
       scripts/quality-policy dependencies
       scripts/quality-policy classify PATH
       scripts/quality-policy critical
       scripts/quality-policy requirements
       scripts/quality-policy capabilities
       scripts/quality-policy journeys
       scripts/quality-policy scenarios
       scripts/quality-policy coverage-exclusions
       scripts/quality-policy suites
       scripts/quality-policy render-json
       scripts/quality-policy generate [--check]
       scripts/quality-policy check-paths [PATH ...]""",
        file=stream,
    )


def fail(message: str) -> NoReturn:
    print(f"quality-policy: {message}", file=sys.stderr)
    raise SystemExit(2)


def require_count(arguments: list[str], expected: int, message: str) -> None:
    if len(arguments) != expected:
        raise PolicyError(message)


def main(arguments: list[str]) -> int:
    if not arguments:
        usage(sys.stderr)
        return 2
    command, *values = arguments
    if command in ("-h", "--help", "help"):
        usage()
        return 0
    policy = Policy(POLICY_FILE)
    if command == "validate":
        require_count(values, 0, "validate takes no arguments")
        policy.validate_tracked_paths()
        print("Quality policy is valid")
    elif command == "version":
        require_count(values, 0, "version takes no arguments")
        print(policy.version)
    elif command == "stages":
        require_count(values, 1, "stages requires all or release")
        if values[0] not in ("all", "release"):
            raise PolicyError("stages requires all or release")
        for stage in policy.stages:
            if values[0] == "all" or stage.release:
                print(stage.name)
    elif command == "timeout":
        require_count(values, 1, "timeout requires one stage")
        stage = policy.stages_by_name.get(values[0])
        if stage is None:
            raise PolicyError(f"unknown stage: {values[0]}")
        print(stage.timeout)
    elif command == "dependencies":
        require_count(values, 0, "dependencies takes no arguments")
        for prerequisite, dependent in policy.dependencies:
            print(f"{prerequisite}\t{dependent}")
    elif command == "classify":
        require_count(values, 1, "classify requires one path")
        print(policy.classify(values[0]).tsv())
    elif command == "critical":
        require_count(values, 0, "critical takes no arguments")
        for source, requirement in policy.critical:
            print(f"{source}\t{requirement}")
    elif command == "requirements":
        require_count(values, 0, "requirements takes no arguments")
        for identifier, (spec, summary) in policy.requirements.items():
            print(f"{identifier}\t{spec}\t{summary}")
    elif command == "capabilities":
        require_count(values, 0, "capabilities takes no arguments")
        for identifier, (spec, requirements, journeys) in policy.capabilities.items():
            print(f"{identifier}\t{spec}\t{requirements}\t{journeys}")
    elif command == "journeys":
        require_count(values, 0, "journeys takes no arguments")
        for identifier, (capability, requirements, scenarios, summary) in policy.journeys.items():
            print(f"{identifier}\t{capability}\t{requirements}\t{scenarios}\t{summary}")
    elif command == "scenarios":
        require_count(values, 0, "scenarios takes no arguments")
        for identifier, (stage, status, scenario_command) in policy.scenarios.items():
            print(f"{identifier}\t{stage}\t{status}\t{scenario_command}")
    elif command == "coverage-exclusions":
        require_count(values, 0, "coverage-exclusions takes no arguments")
        for group, pattern, scenarios, summary in policy.coverage_exclusions:
            print(f"{group}\t{pattern}\t{scenarios}\t{summary}")
    elif command == "suites":
        require_count(values, 0, "suites takes no arguments")
        for suite in policy.required_suites:
            print(suite)
    elif command == "render-json":
        require_count(values, 0, "render-json takes no arguments")
        print(json.dumps(policy.document(), indent=2, sort_keys=True))
    elif command == "generate":
        if values not in ([], ["--check"]):
            raise PolicyError("generate accepts only --check")
        target = ROOT / "quality/generated/policy.json"
        rendered = json.dumps(policy.document(), indent=2, sort_keys=True) + "\n"
        if values == ["--check"]:
            if not target.is_file() or target.is_symlink():
                raise PolicyError("generated policy view is missing or unsafe")
            if target.read_text(encoding="utf-8") != rendered:
                raise PolicyError(
                    "generated policy view is stale; run scripts/quality-policy generate"
                )
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() and target.is_symlink():
                raise PolicyError("generated policy view target is a symlink")
            temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
            temporary.write_text(rendered, encoding="utf-8")
            os.chmod(temporary, 0o644)
            os.replace(temporary, target)
    elif command == "check-paths":
        if values:
            for path in values:
                policy.classify(path)
        else:
            policy.validate_tracked_paths()
    else:
        usage(sys.stderr)
        raise PolicyError(f"unknown command: {command}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except PolicyError as error:
        fail(str(error))
