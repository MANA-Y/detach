#!/usr/bin/env python3
"""Contract tests for isolated Swift cache precomputation."""

from __future__ import annotations

from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from quality_cache_warm import resolve_dependencies, warm  # noqa: E402


class CacheWarmContract(unittest.TestCase):
    def test_three_build_graph_uses_isolated_paths_and_one_job_each(self) -> None:
        calls: list[tuple[list[str], Path, dict[str, str]]] = []

        class FakeProcess:
            def __init__(self, command, *, cwd, env):
                calls.append((command, cwd, env))

            def wait(self):
                return 0

            def terminate(self):
                raise AssertionError("successful cache process was terminated")

        with TemporaryDirectory() as temporary:
            test_root = Path(temporary)
            app = test_root / "app"
            (app / "scripts").mkdir(parents=True)
            (app / "Package.swift").write_text("package\n", encoding="utf-8")
            (app / "Package.resolved").write_text("resolved\n", encoding="utf-8")
            with (
                patch(
                    "quality_cache_warm.subprocess.run",
                    return_value=SimpleNamespace(returncode=0),
                ) as resolve,
                patch("quality_cache_warm.subprocess.Popen", FakeProcess),
            ):
                self.assertEqual(warm(test_root, 3), 0)

            resolve_command = resolve.call_args.args[0]
            self.assertEqual(resolve_command[:3], ["swift", "package", "resolve"])
            self.assertIn(str(app / ".build"), resolve_command)
            self.assertIn(
                str(app / ".build/quality-dependency-resolve"), resolve_command
            )
            with patch("quality_cache_warm.subprocess.run") as cached_resolve:
                self.assertEqual(resolve_dependencies(test_root), 0)
                cached_resolve.assert_not_called()

            self.assertEqual(len(calls), 3)
            test, normal, coverage = calls
            self.assertIn("--build-tests", test[0])
            self.assertIn(str(app / ".build/quality-swift-tests"), test[0])
            self.assertEqual(test[0][test[0].index("--jobs") + 1], "1")
            self.assertEqual(normal[0], [str(app / "scripts/make-app.sh")])
            self.assertEqual(normal[2]["DETACH_QUALITY_APP_SCRATCH"], "1")
            self.assertEqual(normal[2]["DETACH_SWIFT_BUILD_JOBS"], "1")
            self.assertIn(str(app / ".build/quality-ui-release"), coverage[0])
            self.assertEqual(coverage[0][coverage[0].index("--jobs") + 1], "1")
            module_caches = {call[2]["CLANG_MODULE_CACHE_PATH"] for call in calls}
            self.assertEqual(len(module_caches), 3)
            self.assertIn(str(app / ".build/quality-ui-module-cache"), module_caches)


if __name__ == "__main__":
    result = unittest.main(exit=False)
    if result.result.wasSuccessful():
        print("Quality cache warm contracts passed")
    raise SystemExit(not result.result.wasSuccessful())
