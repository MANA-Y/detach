#!/usr/bin/env python3
"""Contract tests for isolated Swift cache precomputation."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from quality_cache_warm import warm  # noqa: E402


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

        with patch("quality_cache_warm.subprocess.Popen", FakeProcess):
            self.assertEqual(warm(ROOT, 3), 0)

        self.assertEqual(len(calls), 3)
        test, normal, coverage = calls
        self.assertIn("--build-tests", test[0])
        self.assertIn(str(ROOT / "app/.build/quality-swift-tests"), test[0])
        self.assertEqual(test[0][test[0].index("--jobs") + 1], "1")
        self.assertEqual(normal[0], [str(ROOT / "app/scripts/make-app.sh")])
        self.assertEqual(normal[2]["DETACH_QUALITY_APP_SCRATCH"], "1")
        self.assertEqual(normal[2]["DETACH_SWIFT_BUILD_JOBS"], "1")
        self.assertIn(str(ROOT / "app/.build/quality-ui-release"), coverage[0])
        self.assertEqual(coverage[0][coverage[0].index("--jobs") + 1], "1")
        module_caches = {call[2]["CLANG_MODULE_CACHE_PATH"] for call in calls}
        self.assertEqual(len(module_caches), 3)
        self.assertIn(str(ROOT / "app/.build/quality-ui-module-cache"), module_caches)


if __name__ == "__main__":
    result = unittest.main(exit=False)
    if result.result.wasSuccessful():
        print("Quality cache warm contracts passed")
    raise SystemExit(not result.result.wasSuccessful())
