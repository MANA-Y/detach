#!/usr/bin/env python3
"""Generate and validate Detach's deterministic SPDX release SBOM."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, NoReturn


ROOT = Path(__file__).resolve().parent.parent
PACKAGE_RESOLVED = ROOT / "app/Package.resolved"
TMUX_BUILDER = ROOT / "scripts/build-tmux.sh"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")


class SbomError(Exception):
    """An SBOM input or document does not satisfy the release contract."""


def fail(message: str) -> NoReturn:
    print(f"release-sbom: {message}", file=sys.stderr)
    raise SystemExit(2)


def read_json(path: Path, label: str) -> Any:
    if not path.is_file() or path.is_symlink():
        raise SbomError(f"{label} must be a regular, non-symlink file")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SbomError(f"cannot read {label}: {error}") from error


def command(arguments: list[str], label: str) -> str:
    try:
        result = subprocess.run(
            arguments,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SbomError(f"cannot read {label}: {error}") from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise SbomError(f"cannot read {label}: {detail}")
    return result.stdout.strip()


def package_resolved(path: Path) -> list[dict[str, str]]:
    value = read_json(path, "Swift package resolution")
    pins = value.get("pins") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or value.get("version") != 2
        or not isinstance(pins, list)
    ):
        raise SbomError("Swift package resolution schema is invalid")
    packages: list[dict[str, str]] = []
    for pin in pins:
        state = pin.get("state") if isinstance(pin, dict) else None
        if (
            not isinstance(pin, dict)
            or not isinstance(state, dict)
            or not isinstance(pin.get("identity"), str)
            or not isinstance(pin.get("location"), str)
            or not isinstance(state.get("version"), str)
            or not isinstance(state.get("revision"), str)
            or not COMMIT.fullmatch(state["revision"])
        ):
            raise SbomError("Swift package resolution contains an invalid pin")
        packages.append(
            {
                "name": pin["identity"],
                "version": state["version"],
                "location": pin["location"],
                "revision": state["revision"],
            }
        )
    if not packages:
        raise SbomError("Swift package resolution contains no packages")
    return sorted(packages, key=lambda package: package["name"])


def tmux_metadata(executable: Path) -> list[dict[str, str]]:
    try:
        value = json.loads(command([str(executable), "metadata", "--json"], "tmux metadata"))
    except json.JSONDecodeError as error:
        raise SbomError(f"tmux metadata is malformed: {error}") from error
    if not isinstance(value, dict) or value.get("schema") != 1:
        raise SbomError("tmux metadata schema is invalid")
    packages: list[dict[str, str]] = []
    for name in ("tmux", "libevent", "utf8proc"):
        package = value.get(name)
        if (
            not isinstance(package, dict)
            or set(package) != {"version", "license", "source_url", "sha256"}
            or any(not isinstance(field, str) or not field for field in package.values())
            or not DIGEST.fullmatch(package["sha256"])
        ):
            raise SbomError(f"tmux metadata is invalid for {name}")
        packages.append({"name": name, **package})
    return packages


def git_created(commit: str) -> str:
    raw = command(
        ["git", "show", "-s", "--format=%cI", f"{commit}^{{commit}}"],
        "source commit time",
    )
    try:
        value = datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError as error:
        raise SbomError("source commit time is invalid") from error
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def spdx_id(name: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9.-]", "-", name)
    return f"SPDXRef-Package-{normalized}"


def build_document(
    version: str,
    tag: str,
    commit: str,
    repository: str,
    swift_packages: list[dict[str, str]],
    native_packages: list[dict[str, str]],
    created: str,
) -> dict[str, Any]:
    root_id = "SPDXRef-Package-Detach"
    packages: list[dict[str, Any]] = [
        {
            "SPDXID": root_id,
            "name": "Detach",
            "versionInfo": version,
            "downloadLocation": f"https://github.com/{repository}/releases/tag/{tag}",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "externalRefs": [
                {
                    "referenceCategory": "OTHER",
                    "referenceType": "vcs",
                    "referenceLocator": f"git+https://github.com/{repository}.git@{commit}",
                }
            ],
        }
    ]
    for package in swift_packages:
        packages.append(
            {
                "SPDXID": spdx_id(package["name"]),
                "name": package["name"],
                "versionInfo": package["version"],
                "downloadLocation": f"git+{package['location']}@{package['revision']}",
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "copyrightText": "NOASSERTION",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": f"pkg:swift/{package['name']}@{package['version']}",
                    }
                ],
            }
        )
    for package in native_packages:
        packages.append(
            {
                "SPDXID": spdx_id(package["name"]),
                "name": package["name"],
                "versionInfo": package["version"],
                "downloadLocation": package["source_url"],
                "filesAnalyzed": False,
                "checksums": [
                    {"algorithm": "SHA256", "checksumValue": package["sha256"]}
                ],
                "licenseConcluded": package["license"],
                "licenseDeclared": package["license"],
                "copyrightText": "NOASSERTION",
            }
        )
    relationships = [
        {
            "spdxElementId": root_id,
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": package["SPDXID"],
        }
        for package in packages[1:]
    ]
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Detach-{version}",
        "documentNamespace": (
            f"https://github.com/{repository}/releases/tag/{tag}/"
            f"spdx/{commit}"
        ),
        "creationInfo": {
            "created": created,
            "creators": ["Tool: Detach release-sbom/1"],
        },
        "documentDescribes": [root_id],
        "packages": packages,
        "relationships": relationships,
    }


def validate_document(
    value: Any, version: str, tag: str, commit: str, repository: str
) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or value.get("spdxVersion") != "SPDX-2.3"
        or value.get("dataLicense") != "CC0-1.0"
        or value.get("SPDXID") != "SPDXRef-DOCUMENT"
        or value.get("name") != f"Detach-{version}"
        or value.get("documentNamespace")
        != f"https://github.com/{repository}/releases/tag/{tag}/spdx/{commit}"
        or value.get("documentDescribes") != ["SPDXRef-Package-Detach"]
    ):
        raise SbomError("SPDX document identity is invalid")
    packages = value.get("packages")
    relationships = value.get("relationships")
    creation = value.get("creationInfo")
    if (
        not isinstance(packages, list)
        or len(packages) < 2
        or not isinstance(relationships, list)
        or len(relationships) != len(packages) - 1
        or not isinstance(creation, dict)
        or creation.get("creators") != ["Tool: Detach release-sbom/1"]
        or not isinstance(creation.get("created"), str)
    ):
        raise SbomError("SPDX document structure is invalid")
    identifiers = [package.get("SPDXID") for package in packages if isinstance(package, dict)]
    if len(identifiers) != len(packages) or len(set(identifiers)) != len(identifiers):
        raise SbomError("SPDX package identities are invalid")
    root = packages[0]
    root_refs = root.get("externalRefs") if isinstance(root, dict) else None
    if (
        root.get("SPDXID") != "SPDXRef-Package-Detach"
        or root.get("versionInfo") != version
        or not isinstance(root_refs, list)
        or len(root_refs) != 1
        or not isinstance(root_refs[0], dict)
        or root_refs[0].get("referenceLocator")
        != f"git+https://github.com/{repository}.git@{commit}"
    ):
        raise SbomError("SPDX root package provenance is invalid")
    if any(not isinstance(relationship, dict) for relationship in relationships):
        raise SbomError("SPDX dependency relationships are invalid")
    related = {relationship.get("relatedSpdxElement") for relationship in relationships}
    if related != set(identifiers[1:]) or any(
        relationship.get("spdxElementId") != "SPDXRef-Package-Detach"
        or relationship.get("relationshipType") != "DEPENDS_ON"
        for relationship in relationships
    ):
        raise SbomError("SPDX dependency relationships are invalid")
    return value


def write_json(path: Path, value: dict[str, Any]) -> None:
    if path.exists() and (not path.is_file() or path.is_symlink()):
        raise SbomError("SBOM output is unsafe")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--repository", required=True)


def validate_identity(args: argparse.Namespace) -> None:
    if not SEMVER.fullmatch(args.version):
        raise SbomError("version must be valid SemVer")
    if args.tag != f"v{args.version}":
        raise SbomError("tag must equal v followed by the version")
    if not COMMIT.fullmatch(args.commit):
        raise SbomError("commit must be one lowercase 40-character commit")
    if not REPOSITORY.fullmatch(args.repository):
        raise SbomError("repository must identify owner/repository")


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    commands = value.add_subparsers(dest="command", required=True)
    generate = commands.add_parser("generate")
    common_arguments(generate)
    generate.add_argument("--output", type=Path, required=True)
    validate = commands.add_parser("validate")
    common_arguments(validate)
    validate.add_argument("--input", type=Path, required=True)
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        validate_identity(args)
        document = build_document(
            args.version,
            args.tag,
            args.commit,
            args.repository,
            package_resolved(PACKAGE_RESOLVED),
            tmux_metadata(TMUX_BUILDER),
            git_created(args.commit),
        )
        if args.command == "generate":
            validate_document(
                document, args.version, args.tag, args.commit, args.repository
            )
            write_json(args.output, document)
        else:
            supplied = validate_document(
                read_json(args.input, "SPDX SBOM"),
                args.version,
                args.tag,
                args.commit,
                args.repository,
            )
            if supplied != document:
                raise SbomError("SPDX document does not match pinned release inputs")
    except (SbomError, OSError) as error:
        fail(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
