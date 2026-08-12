#!/usr/bin/env python3
"""Deterministic contracts for specification traceability in the quality policy."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from quality_policy import Policy, PolicyError  # noqa: E402


POLICY = ROOT / "quality/policy.tsv"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def expect_error(source: str, expected: str) -> None:
    with tempfile.TemporaryDirectory(prefix="detach-quality-policy-contract.") as directory:
        candidate = Path(directory) / "policy.tsv"
        candidate.write_text(source, encoding="utf-8")
        try:
            Policy(candidate)
        except PolicyError as error:
            require(expected in str(error), f"unexpected policy error: {error}")
        else:
            raise AssertionError(f"policy accepted invalid input: {expected}")


def main() -> None:
    source = POLICY.read_text(encoding="utf-8")
    policy = Policy(POLICY)
    specs = policy.specification_document()

    require(len(specs) == 5, "expected five current specifications")
    require(
        {spec["id"] for spec in specs}
        == {"documentation", "runtime", "power", "app", "release"},
        "specification identities changed unexpectedly",
    )
    require(
        all("status" not in spec for spec in specs),
        "the runtime policy contains specification history state",
    )
    require(
        policy.render_spec_traceability() == policy.render_spec_traceability(),
        "the specification view is not deterministic",
    )

    requirements = {
        requirement["id"]: requirement
        for spec in specs
        for requirement in spec["requirements"]
    }
    require(
        set(requirements) == set(policy.requirements),
        "the specification view omits a requirement",
    )
    for identifier, requirement in requirements.items():
        require(requirement["journeys"], f"{identifier} has no user journey")
        automated = [
            scenario
            for scenario in requirement["scenarios"]
            if scenario["status"] not in {"planned", "manual-release"}
        ]
        require(automated, f"{identifier} has no automated scenario")

    expect_error(
        source.replace(
            "spec\tdocumentation\tdocs/specs/documentation.md\t",
            "spec\tdocumentation\tdocs/specs/documentation.md\thistorical\t",
            1,
        ),
        "spec requires 3 values",
    )
    expect_error(
        "\n".join(
            line
            for line in source.splitlines()
            if not line.startswith("spec\tdocumentation\t")
        )
        + "\n",
        "route references unknown spec: docs/specs/documentation.md",
    )
    expect_error(
        source.replace(
            "journey\tJ-POWER-ENABLE\tpower-protection\t"
            "QC-POWER-ASSERTION,QC-POWER-LEASE,QC-POWER-CLI,QC-POWER-PLATFORM\t",
            "journey\tJ-POWER-ENABLE\tpower-protection\t"
            "QC-POWER-ASSERTION,QC-POWER-LEASE,QC-POWER-PLATFORM\t",
            1,
        ),
        "capability requirement has no journey: power-protection#QC-POWER-CLI",
    )
    expect_error(
        source.replace(
            "requirement\tQC-APP-SETTINGS\tdocs/specs/app.md\t",
            "requirement\tQC-APP-SETTINGS\tdocs/specs/runtime.md\t",
            1,
        ),
        "capability settings references requirement from another spec: QC-APP-SETTINGS",
    )
    expect_error(
        source.replace(
            "scenario\tSC-APP-SETTINGS-UNIT\tswift\tlegacy-stage\t",
            "scenario\tSC-APP-SETTINGS-UNIT\tswift\tplanned\t",
            1,
        ).replace(
            "scenario\tSC-UI-SETTINGS\tui-e2e\tinstrumented\t",
            "scenario\tSC-UI-SETTINGS\tui-e2e\tplanned\t",
            1,
        ).replace(
            ",SC-UI-SETTINGS\tPackaged journeys own the validated scenario selector.",
            "\tPackaged journeys own the validated scenario selector.",
            1,
        ).replace(
            "\tSC-UI-SETTINGS\tThe packaged Settings journey covers its semantic control.",
            "\tSC-UI-DASHBOARD\tThe packaged Settings journey covers its semantic control.",
            1,
        ),
        "requirement has no automated verification scenario: QC-APP-SETTINGS",
    )

    print("Quality policy Python contracts passed")


if __name__ == "__main__":
    main()
