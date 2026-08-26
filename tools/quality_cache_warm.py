#!/usr/bin/env python3
"""Precompute exact SwiftPM build products outside merge-readiness evidence."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import NoReturn

from quality_gate import SWIFT_TEST_SCRATCH, UI_COVERAGE_SCRATCH, split_quality_pipeline_jobs


ROOT = Path(__file__).resolve().parent.parent
PRODUCT_INPUT_MANIFEST = "quality-product-inputs-v1.json"
PRODUCT_INPUT_FILES = (
    "app/Package.swift",
    "app/Package.resolved",
    "app/Resources/DetachWatchdog-Info.plist",
    "app/scripts/make-app.sh",
    "scripts/build-tmux.sh",
    "VERSION",
    "BUILD",
)
PRODUCT_INPUT_TREES = (
    "app/Sources",
    "app/Tests",
)


class CacheWarmError(Exception):
    """The cache warmer cannot safely complete."""


def fail(message: str) -> NoReturn:
    print(f"quality-cache-warm: {message}", file=sys.stderr)
    raise SystemExit(2)


def module_environment(root: Path, name: str) -> dict[str, str]:
    environment = os.environ.copy()
    module_cache = root / "app/.build/module-cache" / name
    environment.update(
        {
            "CLANG_MODULE_CACHE_PATH": str(module_cache),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(module_cache),
        }
    )
    return environment


def dependency_fingerprint(app: Path) -> str:
    digest = hashlib.sha256(b"detach-swift-dependencies-v1\0")
    for name in ("Package.swift", "Package.resolved"):
        path = app / name
        if not path.is_file() or path.is_symlink():
            raise CacheWarmError(f"missing or unsafe app/{name}")
        digest.update(name.encode("utf-8") + b"\0" + path.read_bytes())
    return digest.hexdigest()


def product_inputs(root: Path) -> list[tuple[str, Path]]:
    """Return the safe files bound by the hosted exact-product cache key."""
    root = root.resolve()
    candidates = [root / relative for relative in PRODUCT_INPUT_FILES]
    for relative in PRODUCT_INPUT_TREES:
        tree = root / relative
        if not tree.is_dir() or tree.is_symlink():
            raise CacheWarmError(f"missing or unsafe {relative}")
        candidates.extend(tree.rglob("*.swift"))

    inputs: list[tuple[str, Path]] = []
    for path in candidates:
        relative = path.relative_to(root).as_posix()
        if not path.is_file() or path.is_symlink():
            raise CacheWarmError(f"missing or unsafe {relative}")
        try:
            path.resolve().relative_to(root)
        except ValueError as error:
            raise CacheWarmError(f"product input escapes repository: {relative}") from error
        inputs.append((relative, path))
    inputs.sort(key=lambda item: item[0])
    return inputs


def product_fingerprint(inputs: list[tuple[str, Path]]) -> str:
    digest = hashlib.sha256(b"detach-swift-products-v1\0")
    for relative, path in inputs:
        digest.update(relative.encode("utf-8") + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def product_manifest(root: Path) -> Path:
    return root / "app/.build" / PRODUCT_INPUT_MANIFEST


def record_product_inputs(root: Path) -> int:
    """Bind completed exact products to the source times SwiftPM observed."""
    inputs = product_inputs(root)
    manifest = product_manifest(root)
    if manifest.is_symlink():
        raise CacheWarmError("exact product input manifest is a symlink")
    manifest.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": 1,
        "fingerprint": product_fingerprint(inputs),
        "inputs": {
            relative: path.stat().st_mtime_ns for relative, path in inputs
        },
    }
    temporary = manifest.with_name(f".{manifest.name}.{os.getpid()}")
    temporary.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    os.chmod(temporary, 0o600)
    os.replace(temporary, manifest)
    print("quality-cache-warm: exact product input times recorded")
    return 0


def reuse_exact_products(root: Path) -> int:
    """Restore source times only when cached products bind the exact content."""
    inputs = product_inputs(root)
    manifest = product_manifest(root)
    if manifest.is_symlink():
        raise CacheWarmError("exact product input manifest is a symlink")
    if not manifest.is_file():
        print("quality-cache-warm: exact cache has no reusable product manifest")
        return 0
    try:
        payload = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CacheWarmError("invalid exact product input manifest") from error
    if not isinstance(payload, dict):
        raise CacheWarmError("exact product input manifest does not match source content")
    expected_paths = [relative for relative, _ in inputs]
    recorded = payload.get("inputs")
    if (
        payload.get("schema") != 1
        or payload.get("fingerprint") != product_fingerprint(inputs)
        or not isinstance(recorded, dict)
        or sorted(recorded) != expected_paths
    ):
        raise CacheWarmError("exact product input manifest does not match source content")
    for relative, path in inputs:
        modified_ns = recorded[relative]
        if not isinstance(modified_ns, int) or isinstance(modified_ns, bool) or modified_ns <= 0:
            raise CacheWarmError("exact product input manifest has an invalid timestamp")
        current = path.stat()
        os.utime(path, ns=(current.st_atime_ns, modified_ns), follow_symlinks=False)
    print("quality-cache-warm: exact Swift products are reusable")
    return 0


def resolve_dependencies(root: Path) -> int:
    app = root / "app"
    fingerprint = dependency_fingerprint(app)
    sentinel = app / ".build/quality-dependencies-v1"
    if sentinel.is_symlink():
        raise CacheWarmError("dependency cache sentinel is a symlink")
    if sentinel.is_file() and sentinel.read_text(encoding="utf-8").strip() == fingerprint:
        print("quality-cache-warm: exact Swift dependencies are ready")
        return 0
    command = [
        "swift", "package", "resolve", "--disable-sandbox",
        "--cache-path", str(app / ".build"),
        "--scratch-path", str(app / ".build/quality-dependency-resolve"),
    ]
    result = subprocess.run(
        command,
        cwd=app,
        env=module_environment(root, "dependency-resolve"),
        check=False,
    )
    if result.returncode == 0:
        sentinel.parent.mkdir(parents=True, exist_ok=True)
        temporary = sentinel.with_name(f".{sentinel.name}.{os.getpid()}")
        temporary.write_text(f"{fingerprint}\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        os.replace(temporary, sentinel)
        print("quality-cache-warm: exact Swift dependencies are ready")
    return result.returncode


def warm(root: Path, logical_cpus: int | None = None) -> int:
    app = root / "app"
    dependency_status = resolve_dependencies(root)
    if dependency_status:
        return dependency_status
    swift_jobs, normal_jobs, coverage_jobs = split_quality_pipeline_jobs(logical_cpus)
    test_scratch = app / ".build" / SWIFT_TEST_SCRATCH
    coverage_scratch = app / ".build" / UI_COVERAGE_SCRATCH

    test_command = [
        "swift", "build", "--build-tests", "--enable-code-coverage",
        "--disable-sandbox", "--disable-automatic-resolution",
        "--cache-path", str(app / ".build"),
        "--scratch-path", str(test_scratch), "--jobs", str(swift_jobs),
    ]
    normal_environment = module_environment(root, "app")
    normal_environment.update(
        {
            "DETACH_SWIFT_BUILD_JOBS": str(normal_jobs),
            "DETACH_QUALITY_APP_SCRATCH": "1",
        }
    )
    coverage_environment = os.environ.copy()
    coverage_module_cache = app / ".build/quality-ui-module-cache"
    coverage_environment.update(
        {
            "CLANG_MODULE_CACHE_PATH": str(coverage_module_cache),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(coverage_module_cache),
        }
    )
    coverage_environment.pop("DETACH_APP_BUILD_MARKER_FILE", None)
    coverage_command = [
        "swift", "build", "--enable-code-coverage", "--disable-sandbox",
        "--disable-automatic-resolution", "--cache-path", str(app / ".build"),
        "-c", "release", "--triple", "arm64-apple-macosx26.0",
        "--scratch-path", str(coverage_scratch), "--product", "DetachApp",
        "--jobs", str(coverage_jobs),
    ]
    definitions = (
        (test_command, app, module_environment(root, "swift")),
        ([str(app / "scripts/make-app.sh")], root, normal_environment),
        (coverage_command, app, coverage_environment),
    )
    processes: list[subprocess.Popen[bytes]] = []
    try:
        for command, cwd, environment in definitions:
            processes.append(subprocess.Popen(command, cwd=cwd, env=environment))
    except OSError as error:
        for process in processes:
            process.terminate()
            process.wait()
        raise CacheWarmError(f"cannot start cache build: {error}") from error
    statuses = [process.wait() for process in processes]
    for status in statuses:
        if status:
            return status
    record_product_inputs(root)
    print("quality-cache-warm: exact Swift build cache is ready; no gate evidence emitted")
    return 0


def main(arguments: list[str]) -> int:
    if arguments == ["--dependencies-only"]:
        return resolve_dependencies(ROOT)
    if arguments == ["--record-product-inputs"]:
        return record_product_inputs(ROOT)
    if arguments == ["--reuse-exact-products"]:
        return reuse_exact_products(ROOT)
    if arguments:
        raise CacheWarmError(
            "usage: quality-cache-warm "
            "[--dependencies-only|--record-product-inputs|--reuse-exact-products]"
        )
    return warm(ROOT)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CacheWarmError as error:
        fail(str(error))
