#!/usr/bin/env python3
"""Focused unit contracts for the Python quality-gate boundary."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))

from quality_gate import (  # noqa: E402
    EXECUTION_PREREQUISITES,
    GateError,
    QualityGate,
    gate_contract_definitions,
    gate_orchestrator_limit,
    include_gate_orchestrators,
    parse_name_status,
    run_app_stage,
    split_swift_build_jobs,
    ui_coverage_binary,
)
from quality_policy import POLICY_FILE, Policy  # noqa: E402


class QualityGateContract(unittest.TestCase):
    def test_name_status_preserves_rename_and_unusual_paths(self) -> None:
        raw = b"R100\0old name\0new\nname\0A\0plain\0"
        self.assertEqual(
            parse_name_status(raw),
            [("R100", "old name", "new\nname"), ("A", "plain", None)],
        )

    def test_name_status_fails_closed_on_a_partial_rename(self) -> None:
        with self.assertRaisesRegex(GateError, "malformed rename/copy entry"):
            parse_name_status(b"R100\0old\0")

    def test_manifest_reader_marks_duplicate_values_invalid(self) -> None:
        gate = QualityGate.__new__(QualityGate)
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.tsv"
            manifest.write_text(
                "policy\t17\npolicy\t16\nresult\tpassed\n", encoding="utf-8"
            )
            values = gate.manifest_values(manifest)
        self.assertIsNone(values["policy"])
        self.assertEqual(values["result"], "passed")

    def test_execution_prerequisites_reference_policy_stages(self) -> None:
        stages = set(Policy(POLICY_FILE).stages_by_name)
        self.assertLessEqual(set(EXECUTION_PREREQUISITES), stages)
        self.assertTrue(all(EXECUTION_PREREQUISITES.values()))
        prerequisites = {
            prerequisite
            for values in EXECUTION_PREREQUISITES.values()
            for prerequisite in values
        }
        self.assertLessEqual(prerequisites, stages)

    def test_local_change_contracts_skip_repository_orchestrator_shards(self) -> None:
        all_contracts = gate_contract_definitions(ROOT, include_orchestrators=True)
        focused = gate_contract_definitions(ROOT, include_orchestrators=False)
        focused_names = {contract[0] for contract in focused}
        self.assertTrue(focused_names)
        self.assertFalse(any(name.startswith("orchestrator-") for name in focused_names))
        self.assertEqual(
            focused_names,
            {
                contract[0]
                for contract in all_contracts
                if not contract[0].startswith("orchestrator-")
            },
        )
        self.assertLess(len(focused), len(all_contracts))
        self.assertFalse(include_gate_orchestrators("change", ""))
        self.assertTrue(include_gate_orchestrators("repository", ""))
        self.assertTrue(include_gate_orchestrators("change", "gate-contract"))

    def test_gate_orchestrator_capacity_tracks_available_processors(self) -> None:
        self.assertEqual(gate_orchestrator_limit(10), 3)
        self.assertEqual(gate_orchestrator_limit(8), 3)
        self.assertEqual(gate_orchestrator_limit(4), 2)

    def test_public_shell_entry_point_is_thin(self) -> None:
        wrapper = (ROOT / "scripts/quality-gate").read_text(encoding="utf-8")
        self.assertLessEqual(len(wrapper.splitlines()), 12)
        self.assertIn('exec python3 "$ROOT/tools/quality_gate.py" "$@"', wrapper)
        self.assertNotIn("jq ", wrapper)
        self.assertNotIn("awk ", wrapper)

    def test_app_builds_normal_bundle_and_release_coverage_in_parallel(self) -> None:
        events: list[str] = []

        class FakeProcess:
            def __init__(self, command, *, cwd, env):
                self.command = command
                self.cwd = cwd
                self.env = env
                events.append("coverage-started")

            def wait(self):
                events.append("coverage-finished")
                return 0

        def fake_child_run(command, *, cwd=ROOT, env=None):
            self.assertEqual(events, ["coverage-started"])
            self.assertEqual(command, [str(ROOT / "app/scripts/make-app.sh")])
            self.assertEqual(env["DETACH_SWIFT_BUILD_JOBS"], "5")
            events.append("normal-finished")
            return 0

        with patch.dict(
            "os.environ",
            {"DETACH_QUALITY_GATE_SELECTED_STAGES": "app,quality-contracts"},
            clear=False,
        ), patch("quality_gate.os.cpu_count", return_value=10), patch(
            "quality_gate.subprocess.Popen", FakeProcess
        ), patch("quality_gate.child_run", fake_child_run):
            self.assertEqual(run_app_stage(ROOT), 0)

        self.assertEqual(
            events,
            ["coverage-started", "normal-finished", "coverage-finished"],
        )
        self.assertEqual(split_swift_build_jobs(10), (5, 5))
        self.assertEqual(
            ui_coverage_binary(ROOT),
            ROOT / "app/.build/quality-ui-release/arm64-apple-macosx/release/DetachApp",
        )


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(QualityGateContract)
    result = unittest.TextTestRunner(verbosity=0).run(suite)
    if not result.wasSuccessful():
        return 1
    print("Quality gate Python contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
