#!/usr/bin/env python3
"""Contract tests for isolated Swift cache precomputation."""

from __future__ import annotations

from pathlib import Path
import json
import os
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from quality_cache_warm import (  # noqa: E402
    CacheWarmError,
    record_product_inputs,
    resolve_dependencies,
    reuse_exact_products,
    warm,
)


class CacheWarmContract(unittest.TestCase):
    @staticmethod
    def make_product_inputs(root: Path) -> list[Path]:
        paths = [
            root / "app/Package.swift",
            root / "app/Package.resolved",
            root / "app/Resources/DetachWatchdog-Info.plist",
            root / "app/scripts/make-app.sh",
            root / "scripts/build-tmux.sh",
            root / "VERSION",
            root / "BUILD",
            root / "app/Sources/Feature.swift",
            root / "app/Tests/FeatureTests.swift",
        ]
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"{path.name}\n", encoding="utf-8")
        return paths

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
            self.make_product_inputs(test_root)
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

    def test_exact_product_manifest_restores_only_bound_source_times(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = self.make_product_inputs(root)
            unrelated = root / "README.md"
            unrelated.write_text("unchanged\n", encoding="utf-8")
            bound_times = {
                path: 1_700_000_000_000_000_000 + index
                for index, path in enumerate(inputs)
            }
            for path, modified_ns in bound_times.items():
                os.utime(path, ns=(modified_ns, modified_ns))
            self.assertEqual(record_product_inputs(root), 0)
            manifest = root / "app/.build/quality-product-inputs-v1.json"
            self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)

            changed_ns = 1_800_000_000_000_000_000
            for path in inputs:
                os.utime(path, ns=(changed_ns, changed_ns))
            unrelated_before = unrelated.stat().st_mtime_ns
            self.assertEqual(reuse_exact_products(root), 0)
            self.assertEqual(
                {path: path.stat().st_mtime_ns for path in inputs}, bound_times
            )
            self.assertEqual(unrelated.stat().st_mtime_ns, unrelated_before)

    def test_exact_product_manifest_fails_closed_on_content_or_shape_change(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = self.make_product_inputs(root)
            record_product_inputs(root)
            inputs[-1].write_text("different\n", encoding="utf-8")
            with self.assertRaisesRegex(CacheWarmError, "does not match source content"):
                reuse_exact_products(root)

            inputs[-1].write_text(f"{inputs[-1].name}\n", encoding="utf-8")
            manifest = root / "app/.build/quality-product-inputs-v1.json"
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            payload["inputs"]["VERSION"] = True
            manifest.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(CacheWarmError, "invalid timestamp"):
                reuse_exact_products(root)

    def test_missing_exact_product_manifest_is_a_safe_cache_miss(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_product_inputs(root)
            self.assertEqual(reuse_exact_products(root), 0)


if __name__ == "__main__":
    result = unittest.main(exit=False)
    if result.result.wasSuccessful():
        print("Quality cache warm contracts passed")
    raise SystemExit(not result.result.wasSuccessful())
