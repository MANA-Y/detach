#!/usr/bin/env python3
"""Prepare and run bounded direct Swift compiler commands for CodeQL."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from typing import Any, NoReturn


SCHEMA = 1
SCOPES: dict[str, tuple[str, ...]] = {
    "kit": ("DetachKit",),
    "app": ("DetachApp",),
    "processes": (
        "DetachPower",
        "DetachPowerHelper",
        "DetachState",
        "DetachWatchdog",
    ),
}
SWIFT_BUILD_OPTIONS = (
    "--arch", "arm64",
    "--jobs", "3",
    "--disable-index-store",
    "--disable-sandbox",
    "--force-resolved-versions",
    "-Xswiftc", "-whole-module-optimization",
    "-Xswiftc", "-num-threads",
    "-Xswiftc", "3",
    "-Xswiftc", "-gnone",
)


class SwiftCodeQLError(Exception):
    """A generated Swift compiler plan does not satisfy the security contract."""


def fail(message: str) -> NoReturn:
    print(f"swift-codeql-build: {message}", file=sys.stderr)
    raise SystemExit(2)


def regular_file(path: Path, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        raise SwiftCodeQLError(f"{label} must be a regular, non-symlink file: {path}")
    return path


def swift_compiler(value: str, label: str) -> Path:
    lexical = Path(value).absolute()
    if lexical.name != "swiftc" or not os.access(lexical, os.X_OK):
        raise SwiftCodeQLError(f"{label} is not executable swiftc: {lexical}")
    resolved = regular_file(lexical.resolve(), label)
    developer_dir = os.environ.get("DEVELOPER_DIR")
    if developer_dir and not within(resolved, Path(developer_dir).resolve()):
        raise SwiftCodeQLError(f"{label} is outside DEVELOPER_DIR: {lexical}")
    return lexical


def read_json(path: Path, label: str) -> Any:
    regular_file(path, label)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SwiftCodeQLError(f"cannot read {label}: {error}") from error


def within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def source_files(package: Path, module: str) -> list[Path]:
    source_entry = package / "Sources" / module
    if source_entry.is_symlink() or not source_entry.is_dir():
        raise SwiftCodeQLError(f"Swift module source directory is invalid: {source_entry}")
    source_root = source_entry.resolve()
    entries = sorted(source_root.rglob("*.swift"))
    if not entries:
        raise SwiftCodeQLError(f"Swift module has no source files: {module}")
    sources: list[Path] = []
    for entry in entries:
        if entry.is_symlink():
            raise SwiftCodeQLError(f"Swift source must not be a symlink: {entry}")
        source = entry.resolve()
        regular_file(source, f"{module} source")
        if not within(source, source_root):
            raise SwiftCodeQLError(f"Swift source escapes its module: {source}")
        sources.append(source)
    return sources


def source_fingerprint(package: Path, module: str) -> str:
    digest = hashlib.sha256()
    package = package.resolve()
    for source in source_files(package, module):
        relative = source.relative_to(package).as_posix().encode("utf-8")
        digest.update(relative)
        digest.update(b"\0")
        digest.update(source.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(
        isinstance(item, str) and item for item in value
    ):
        raise SwiftCodeQLError(f"{label} must be a non-empty string list")
    return value


def arm64_record(record: dict[str, Any]) -> bool:
    arguments = record.get("otherArguments")
    if not isinstance(arguments, list):
        return False
    return any(
        argument == "-target"
        and index + 1 < len(arguments)
        and isinstance(arguments[index + 1], str)
        and arguments[index + 1].startswith("arm64-apple-macosx")
        for index, argument in enumerate(arguments)
    )


def find_description(scratch: Path, modules: tuple[str, ...]) -> Path:
    matches: list[Path] = []
    for path in sorted(scratch.glob("*/debug/description.json")):
        try:
            value = read_json(path, "SwiftPM build description")
        except SwiftCodeQLError:
            continue
        commands = value.get("swiftCommands") if isinstance(value, dict) else None
        if not isinstance(commands, dict):
            continue
        names = {
            record.get("moduleName")
            for record in commands.values()
            if isinstance(record, dict) and arm64_record(record)
        }
        if set(modules).issubset(names):
            matches.append(path)
    if len(matches) != 1:
        raise SwiftCodeQLError(
            f"expected one SwiftPM build description for {','.join(modules)}, "
            f"found {len(matches)}"
        )
    return matches[0]


def compiler_command(
    package: Path,
    scratch: Path,
    module: str,
    record: dict[str, Any],
) -> tuple[list[str], int, str]:
    package = package.resolve()
    scratch = scratch.resolve()
    executable_value = record.get("executable")
    if not isinstance(executable_value, str) or not executable_value:
        raise SwiftCodeQLError(f"SwiftPM omitted the compiler for {module}")
    executable = swift_compiler(executable_value, f"{module} compiler")

    if record.get("moduleName") != module:
        raise SwiftCodeQLError(f"SwiftPM module identity changed: {module}")
    generated_sources = string_list(record.get("sources"), f"{module} generated sources")
    actual_sources = source_files(package, module)
    generated_paths = sorted(Path(value).resolve() for value in generated_sources)
    if generated_paths != actual_sources:
        raise SwiftCodeQLError(f"SwiftPM source closure is incomplete for {module}")

    file_list = regular_file(Path(str(record.get("fileList", ""))).resolve(), f"{module} file list")
    output_map = regular_file(
        Path(str(record.get("outputFileMapPath", ""))).resolve(),
        f"{module} output map",
    )
    module_output = Path(str(record.get("moduleOutputPath", ""))).resolve()
    import_path = Path(str(record.get("importPath", ""))).resolve()
    for generated in (file_list, output_map, module_output.parent, import_path):
        if not within(generated, scratch):
            raise SwiftCodeQLError(f"SwiftPM output escapes the scratch path: {generated}")
    try:
        listed_sources = sorted(
            Path(line).resolve()
            for line in file_list.read_text(encoding="utf-8").splitlines()
            if line
        )
    except (OSError, UnicodeError) as error:
        raise SwiftCodeQLError(f"cannot read {module} file list: {error}") from error
    if listed_sources != actual_sources:
        raise SwiftCodeQLError(f"SwiftPM file list is incomplete for {module}")
    output_value = read_json(output_map, f"{module} output map")
    if not isinstance(output_value, dict):
        raise SwiftCodeQLError(f"SwiftPM output map is invalid for {module}")

    other = string_list(record.get("otherArguments"), f"{module} compiler arguments")
    targets = [
        other[index + 1]
        for index, argument in enumerate(other[:-1])
        if argument == "-target"
    ]
    if len(targets) != 1 or not targets[0].startswith("arm64-apple-macosx"):
        raise SwiftCodeQLError(f"SwiftPM compiler target is not arm64 for {module}")
    required_sequences = (
        ("-whole-module-optimization",),
        ("-num-threads", "3"),
        ("-disable-sandbox",),
    )
    joined = "\0".join(other)
    for sequence in required_sequences:
        if "\0".join(sequence) not in joined:
            raise SwiftCodeQLError(
                f"SwiftPM compiler arguments are missing {' '.join(sequence)} for {module}"
            )

    driver_only = {"-v", "-incremental", "-enable-batch-mode", "-parseable-output"}
    traced_arguments = [argument for argument in other if argument not in driver_only]
    arguments = [
        str(executable),
        "-module-name", module,
        "-output-file-map", str(output_map),
    ]
    if record.get("isLibrary") is True:
        arguments.append("-parse-as-library")
    elif record.get("isLibrary") is not False:
        raise SwiftCodeQLError(f"SwiftPM library state is invalid for {module}")
    arguments.extend([
        "-c", f"@{file_list}",
        "-I", str(import_path),
        *traced_arguments,
        "-gnone",
    ])
    return arguments, len(actual_sources), source_fingerprint(package, module)


def build_plan(package: Path, scratch: Path, scope: str) -> dict[str, Any]:
    package = package.resolve()
    scratch = scratch.resolve()
    modules = SCOPES.get(scope)
    if modules is None:
        raise SwiftCodeQLError(f"unknown Swift CodeQL scope: {scope}")
    description_path = find_description(scratch, modules)
    description = read_json(description_path, "SwiftPM build description")
    commands = description.get("swiftCommands") if isinstance(description, dict) else None
    if not isinstance(commands, dict):
        raise SwiftCodeQLError("SwiftPM build description has no compiler commands")
    records: list[dict[str, Any]] = []
    for module in modules:
        matches = [
            record
            for record in commands.values()
            if isinstance(record, dict) and record.get("moduleName") == module
        ]
        if len(matches) != 1:
            raise SwiftCodeQLError(
                f"expected one SwiftPM compiler command for {module}, found {len(matches)}"
            )
        command, count, fingerprint = compiler_command(
            package, scratch, module, matches[0]
        )
        records.append({
            "module": module,
            "source_count": count,
            "source_fingerprint": fingerprint,
            "command": command,
        })
    return {
        "schema": SCHEMA,
        "scope": scope,
        "package": str(package),
        "scratch": str(scratch),
        "description": str(description_path.resolve()),
        "modules": records,
    }


def terminate(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_bounded(
    arguments: list[str],
    deadline: float,
    label: str,
    environment: dict[str, str] | None = None,
) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise SwiftCodeQLError(f"{label} exceeded its total deadline")
    started = time.monotonic()
    try:
        process = subprocess.Popen(
            arguments,
            env=environment,
            start_new_session=True,
        )
    except OSError as error:
        raise SwiftCodeQLError(f"cannot start {label}: {error}") from error
    try:
        status = process.wait(timeout=remaining)
    except subprocess.TimeoutExpired as error:
        terminate(process)
        raise SwiftCodeQLError(f"{label} exceeded its total deadline") from error
    except BaseException:
        terminate(process)
        raise
    if status:
        raise SwiftCodeQLError(f"{label} failed with status {status}")
    return time.monotonic() - started


def write_plan(path: Path, value: dict[str, Any]) -> None:
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            os.chmod(temporary, 0o600)
            json.dump(value, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except OSError as error:
        temporary.unlink(missing_ok=True)
        raise SwiftCodeQLError(f"cannot write compiler plan: {error}") from error


def prepare(
    package: Path,
    scratch: Path,
    scope: str,
    plan_path: Path,
    swift: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    package = package.resolve()
    scratch = scratch.resolve()
    modules = SCOPES.get(scope)
    if modules is None:
        raise SwiftCodeQLError(f"unknown Swift CodeQL scope: {scope}")
    if timeout_seconds <= 0:
        raise SwiftCodeQLError("prepare timeout must be positive")
    deadline = time.monotonic() + timeout_seconds
    module_cache = scratch / "module-cache"
    module_cache.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(module_cache)
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(module_cache)
    durations: list[dict[str, Any]] = []
    for module in modules:
        arguments = [
            swift,
            "build",
            "--package-path", str(package),
            "--scratch-path", str(scratch),
            "--target", module,
            *SWIFT_BUILD_OPTIONS,
        ]
        duration = run_bounded(
            arguments,
            deadline,
            f"SwiftPM prepare for {module}",
            environment,
        )
        durations.append({"module": module, "duration_seconds": round(duration, 3)})
    plan = build_plan(package, scratch, scope)
    write_plan(plan_path, plan)
    return {
        "schema": SCHEMA,
        "result": "passed",
        "phase": "prepare",
        "scope": scope,
        "source_count": sum(record["source_count"] for record in plan["modules"]),
        "modules": durations,
        "plan": str(plan_path.resolve()),
    }


def validate_plan(value: Any) -> tuple[str, Path, list[dict[str, Any]]]:
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise SwiftCodeQLError("compiler plan schema is invalid")
    scope = value.get("scope")
    if not isinstance(scope, str) or scope not in SCOPES:
        raise SwiftCodeQLError("compiler plan scope is invalid")
    package_value = value.get("package")
    scratch_value = value.get("scratch")
    records = value.get("modules")
    if (
        not isinstance(package_value, str)
        or not isinstance(scratch_value, str)
        or not isinstance(records, list)
    ):
        raise SwiftCodeQLError("compiler plan structure is invalid")
    package = Path(package_value).resolve()
    scratch = Path(scratch_value).resolve()
    if [record.get("module") for record in records if isinstance(record, dict)] != list(
        SCOPES[scope]
    ):
        raise SwiftCodeQLError("compiler plan module closure is invalid")
    for record in records:
        if not isinstance(record, dict):
            raise SwiftCodeQLError("compiler plan module record is invalid")
        module = record["module"]
        command = string_list(record.get("command"), f"{module} planned command")
        executable = swift_compiler(command[0], f"{module} planned compiler")
        if command[0] != str(executable):
            raise SwiftCodeQLError(f"planned compiler path is not canonical for {module}")
        required = (
            "-module-name", module,
            "-whole-module-optimization",
            "-num-threads", "3",
            "-gnone",
        )
        joined = "\0".join(command)
        for item in required:
            if item not in command:
                raise SwiftCodeQLError(f"planned command is missing {item} for {module}")
        if (
            f"-module-name\0{module}" not in joined
            or "-num-threads\0" + "3" not in joined
        ):
            raise SwiftCodeQLError(f"planned command order is invalid for {module}")
        file_arguments = [item[1:] for item in command if item.startswith("@")]
        if len(file_arguments) != 1:
            raise SwiftCodeQLError(f"planned command needs one generated file list for {module}")
        file_list = regular_file(Path(file_arguments[0]).resolve(), f"{module} file list")
        listed = sorted(
            Path(line).resolve()
            for line in file_list.read_text(encoding="utf-8").splitlines()
            if line
        )
        actual = source_files(package, module)
        if listed != actual or record.get("source_count") != len(actual):
            raise SwiftCodeQLError(f"planned source closure changed for {module}")
        if record.get("source_fingerprint") != source_fingerprint(package, module):
            raise SwiftCodeQLError(f"planned source fingerprint changed for {module}")
    if value != build_plan(package, scratch, scope):
        raise SwiftCodeQLError("compiler plan no longer matches SwiftPM output")
    return scope, package, records


def trace(plan_path: Path, timeout_seconds: int) -> dict[str, Any]:
    if timeout_seconds <= 0:
        raise SwiftCodeQLError("trace timeout must be positive")
    value = read_json(plan_path.resolve(), "compiler plan")
    scope, _, records = validate_plan(value)
    deadline = time.monotonic() + timeout_seconds
    durations: list[dict[str, Any]] = []
    for record in records:
        module = record["module"]
        duration = run_bounded(record["command"], deadline, f"CodeQL compile for {module}")
        durations.append({"module": module, "duration_seconds": round(duration, 3)})
    return {
        "schema": SCHEMA,
        "result": "passed",
        "phase": "trace",
        "scope": scope,
        "source_count": sum(record["source_count"] for record in records),
        "modules": durations,
    }


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    subparsers = value.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--scope", choices=tuple(SCOPES), required=True)
    prepare_parser.add_argument("--package", type=Path, required=True)
    prepare_parser.add_argument("--scratch", type=Path, required=True)
    prepare_parser.add_argument("--plan", type=Path, required=True)
    prepare_parser.add_argument("--swift", default="swift")
    prepare_parser.add_argument("--timeout-seconds", type=int, default=180)
    trace_parser = subparsers.add_parser("trace")
    trace_parser.add_argument("--plan", type=Path, required=True)
    trace_parser.add_argument("--timeout-seconds", type=int, default=600)
    return value


def main() -> None:
    arguments = parser().parse_args()
    try:
        if arguments.command == "prepare":
            result = prepare(
                arguments.package,
                arguments.scratch,
                arguments.scope,
                arguments.plan,
                arguments.swift,
                arguments.timeout_seconds,
            )
        else:
            result = trace(arguments.plan, arguments.timeout_seconds)
    except SwiftCodeQLError as error:
        fail(str(error))
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
