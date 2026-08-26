#!/usr/bin/env python3
"""Precompute exact SwiftPM build products outside merge-readiness evidence."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import sys
from typing import NoReturn

from quality_gate import SWIFT_TEST_SCRATCH, UI_COVERAGE_SCRATCH, split_quality_pipeline_jobs


ROOT = Path(__file__).resolve().parent.parent


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
    print("quality-cache-warm: exact Swift build cache is ready; no gate evidence emitted")
    return 0


def main(arguments: list[str]) -> int:
    if arguments == ["--dependencies-only"]:
        return resolve_dependencies(ROOT)
    if arguments:
        raise CacheWarmError("usage: quality-cache-warm [--dependencies-only]")
    return warm(ROOT)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CacheWarmError as error:
        fail(str(error))
