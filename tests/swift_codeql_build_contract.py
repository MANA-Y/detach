#!/usr/bin/env python3
"""Deterministic contracts for bounded direct Swift CodeQL builds."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from swift_codeql_build import (  # noqa: E402
    SCOPES,
    SwiftCodeQLError,
    build_plan,
    prepare,
    source_fingerprint,
    trace,
)


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(0o700)


def fixture(directory: Path) -> tuple[Path, Path, Path, Path]:
    package = directory / "app"
    scratch = package / ".build"
    build = scratch / "arm64-apple-macosx" / "debug"
    module_build = build / "DetachKit.build"
    modules = build / "Modules"
    sources = package / "Sources" / "DetachKit"
    for path in (module_build, modules, sources):
        path.mkdir(parents=True, exist_ok=True)
    first = sources / "First.swift"
    second = sources / "Second.swift"
    first.write_text("public struct First {}\n", encoding="utf-8")
    second.write_text("public struct Second {}\n", encoding="utf-8")
    file_list = module_build / "sources"
    file_list.write_text(f"{first}\n{second}\n", encoding="utf-8")
    output_map = module_build / "output-file-map.json"
    output_map.write_text("{}\n", encoding="utf-8")
    compiler = directory / "swiftc"
    write_executable(compiler, "#!/bin/sh\nexit 0\n")
    record = {
        "executable": str(compiler),
        "fileList": str(file_list),
        "importPath": str(modules),
        "isLibrary": True,
        "moduleName": "DetachKit",
        "moduleOutputPath": str(modules / "DetachKit.swiftmodule"),
        "otherArguments": [
            "-target", "arm64-apple-macosx26.0",
            "-whole-module-optimization",
            "-num-threads", "3",
            "-disable-sandbox",
        ],
        "outputFileMapPath": str(output_map),
        "sources": [str(first), str(second)],
    }
    description = {"swiftCommands": {"C.DetachKit.module": record}}
    (build / "description.json").write_text(
        json.dumps(description) + "\n", encoding="utf-8"
    )
    package.mkdir(exist_ok=True)
    return package, scratch, compiler, first


def expect_error(action, text: str) -> None:
    try:
        action()
    except SwiftCodeQLError as error:
        assert text in str(error), str(error)
    else:
        raise AssertionError(f"expected SwiftCodeQLError containing {text!r}")


def main() -> None:
    os.environ.pop("DEVELOPER_DIR", None)
    assert SCOPES == {
        "kit": ("DetachKit",),
        "app": ("DetachApp",),
        "processes": (
            "DetachPower", "DetachPowerHelper", "DetachState", "DetachWatchdog"
        ),
    }
    with tempfile.TemporaryDirectory(prefix="detach-swift-codeql.") as raw:
        directory = Path(raw)
        package, scratch, compiler, first = fixture(directory)
        arm64_description = scratch / "arm64-apple-macosx" / "debug" / "description.json"
        x86_description = scratch / "x86_64-apple-macosx" / "debug" / "description.json"
        x86_description.parent.mkdir(parents=True)
        x86_value = json.loads(arm64_description.read_text(encoding="utf-8"))
        x86_value["swiftCommands"]["C.DetachKit.module"]["otherArguments"][1] = (
            "x86_64-apple-macosx26.0"
        )
        x86_description.write_text(json.dumps(x86_value) + "\n", encoding="utf-8")
        plan = build_plan(package, scratch, "kit")
        assert plan["scope"] == "kit"
        assert plan["modules"][0]["source_count"] == 2
        command = plan["modules"][0]["command"]
        assert command[0] == str(compiler.absolute())
        assert len([argument for argument in command if argument.startswith("@")]) == 1
        assert str(first) not in command
        assert "-emit-module" not in command
        assert "-parseable-output" not in command
        assert "-enable-batch-mode" not in command
        assert "-incremental" not in command
        assert plan["modules"][0]["source_fingerprint"] == source_fingerprint(
            package, "DetachKit"
        )

        linked = package / "Sources" / "DetachKit" / "Linked.swift"
        linked.symlink_to(first)
        expect_error(lambda: build_plan(package, scratch, "kit"), "must not be a symlink")
        linked.unlink()

        plan_path = directory / "plan.json"
        plan_path.write_text(json.dumps(plan) + "\n", encoding="utf-8")
        result = trace(plan_path, 2)
        assert result["result"] == "passed"
        assert result["scope"] == "kit"
        assert result["source_count"] == 2

        first.write_text("public struct Changed {}\n", encoding="utf-8")
        expect_error(lambda: trace(plan_path, 2), "source fingerprint changed")
        first.write_text("public struct First {}\n", encoding="utf-8")

        description_path = scratch / "arm64-apple-macosx" / "debug" / "description.json"
        description = json.loads(description_path.read_text(encoding="utf-8"))
        description["swiftCommands"]["C.DetachKit.module"]["sources"].pop()
        description_path.write_text(json.dumps(description) + "\n", encoding="utf-8")
        expect_error(
            lambda: build_plan(package, scratch, "kit"),
            "source closure is incomplete",
        )
        _, scratch, compiler, _ = fixture(directory)

        fake_swift = directory / "swift"
        write_executable(fake_swift, "#!/bin/sh\nexit 0\n")
        prepared_path = directory / "prepared.json"
        prepared = prepare(package, scratch, "kit", prepared_path, str(fake_swift), 2)
        assert prepared["result"] == "passed"
        assert prepared["source_count"] == 2
        assert prepared_path.stat().st_mode & 0o777 == 0o600

        write_executable(compiler, "#!/bin/sh\nsleep 5\n")
        timeout_plan = build_plan(package, scratch, "kit")
        prepared_path.write_text(json.dumps(timeout_plan) + "\n", encoding="utf-8")
        started = time.monotonic()
        expect_error(lambda: trace(prepared_path, 1), "exceeded its total deadline")
        assert time.monotonic() - started < 4

        invalid = timeout_plan
        invalid["modules"][0]["command"][0] = "/usr/bin/true"
        prepared_path.write_text(json.dumps(invalid) + "\n", encoding="utf-8")
        expect_error(lambda: trace(prepared_path, 2), "executable swiftc")

    print("Swift CodeQL build contracts passed")


if __name__ == "__main__":
    main()
