#!/usr/bin/env python3
"""Embed a bounded, build-time verified executable/dSYM UUID mapping."""

from __future__ import annotations

import argparse
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile
import uuid
from typing import Any


SCHEMA = "argus.openclaw-ios.runtime-symbolication-manifest.v1"
MAXIMUM_BYTES = 64 * 1024
UUID_LINE = re.compile(
    r"^UUID: ([0-9A-Fa-f-]{36}) \(([^()\r\n]{1,64})\) .+$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--archive-uuid", required=True)
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--dwarfdump", required=True)
    parser.add_argument("--dsymutil", required=True)
    parser.add_argument("--temporary-directory", type=pathlib.Path, required=True)
    return parser.parse_args()


def read_plist(path: pathlib.Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"missing regular plist: {path}")
    value = plistlib.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError(f"plist root is not a dictionary: {path}")
    return value


def require_string(value: dict[str, Any], key: str, path: pathlib.Path) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result.strip():
        raise ValueError(f"{path} lacks non-empty {key}")
    return result.strip()


def require_string_list(value: dict[str, Any], key: str, path: pathlib.Path) -> list[str]:
    result = value.get(key)
    if not isinstance(result, list) or not all(
        isinstance(item, str) and item.strip() for item in result
    ):
        raise ValueError(f"{path} lacks bounded string array {key}")
    normalized = sorted(set(item.strip() for item in result))
    if len(normalized) != len(result):
        raise ValueError(f"{path} contains duplicate {key}")
    return normalized


def require_descendant(path: pathlib.Path, root: pathlib.Path, label: str) -> None:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (FileNotFoundError, ValueError) as error:
        raise ValueError(f"{label} escapes its controlled root") from error


def run(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        diagnostic = (completed.stderr or completed.stdout).strip()[:2048]
        raise ValueError(f"command failed ({completed.returncode}): {diagnostic}")
    return completed.stdout


def macho_uuids(path: pathlib.Path, dwarfdump: str) -> list[dict[str, str]]:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"missing regular Mach-O executable: {path}")
    records: list[dict[str, str]] = []
    for raw_line in run([dwarfdump, "--uuid", str(path)]).splitlines():
        match = UUID_LINE.fullmatch(raw_line.strip())
        if match is None:
            raise ValueError(f"unrecognized dwarfdump UUID output for {path.name}")
        normalized_uuid = str(uuid.UUID(match.group(1))).lower()
        architecture = match.group(2)
        records.append({"uuid": normalized_uuid, "architecture": architecture})
    records.sort(key=lambda item: (item["architecture"], item["uuid"]))
    if not records or len({(item["architecture"], item["uuid"]) for item in records}) != len(records):
        raise ValueError(f"missing or duplicate Mach-O UUIDs for {path.name}")
    return records


def bundle_record(
    bundle: pathlib.Path,
    relative_path: str,
    main_bundle_id: str,
    dwarfdump: str,
    dsymutil: str,
    temporary_directory: pathlib.Path,
) -> dict[str, Any]:
    info_path = bundle / "Info.plist"
    info = read_plist(info_path)
    bundle_id = require_string(info, "CFBundleIdentifier", info_path)
    executable_name = require_string(info, "CFBundleExecutable", info_path)
    executable_path = bundle / executable_name
    require_descendant(executable_path, bundle, "bundle executable")
    executable_uuids = macho_uuids(executable_path, dwarfdump)

    if relative_path.startswith("Watch/") and relative_path.endswith(".app"):
        if info.get("WKWatchKitApp") is not True:
            raise ValueError("Watch app is not the expected Xcode WatchKit launcher")
        if require_string(info, "WKCompanionAppBundleIdentifier", info_path) != main_bundle_id:
            raise ValueError("Watch app companion bundle identifier mismatch")
        return {
            "bundle_id": bundle_id,
            "bundle_relative_path": relative_path,
            "executable_name": executable_name,
            "executable_role": "sdk_watchkit_stub",
            "executable_uuids": executable_uuids,
            "dsym_requirement": "not_applicable_sdk_watchkit_stub",
            "dsym_status": "not_emitted",
            "dsym_uuids": [],
        }

    with tempfile.TemporaryDirectory(
        prefix="aies-symbolication-", dir=temporary_directory
    ) as temporary:
        dsym = pathlib.Path(temporary) / f"{bundle.name}.dSYM"
        run([dsymutil, str(executable_path), "-o", str(dsym)])
        dsym_binary = dsym / "Contents" / "Resources" / "DWARF" / executable_name
        require_descendant(dsym_binary, dsym, "temporary dSYM executable")
        dsym_uuids = macho_uuids(dsym_binary, dwarfdump)
    if dsym_uuids != executable_uuids:
        raise ValueError(f"generated dSYM UUIDs differ for {bundle_id}")
    return {
        "bundle_id": bundle_id,
        "bundle_relative_path": relative_path,
        "executable_name": executable_name,
        "executable_role": "compiled_product",
        "executable_uuids": executable_uuids,
        "dsym_requirement": "required_compiled_executable",
        "dsym_status": "uuid_matched_during_build",
        "dsym_uuids": dsym_uuids,
    }


def discover_bundles(app: pathlib.Path) -> list[tuple[pathlib.Path, str]]:
    if not app.is_dir() or app.is_symlink():
        raise ValueError(f"missing regular application bundle: {app}")
    ios_extensions = sorted((app / "PlugIns").glob("*.appex"))
    watch_apps = sorted((app / "Watch").glob("*.app"))
    watch_extensions = sorted((app / "Watch").glob("*.app/PlugIns/*.appex"))
    if len(ios_extensions) != 2 or len(watch_apps) != 1 or len(watch_extensions) != 1:
        raise ValueError("unexpected five-target embedded bundle topology")
    bundles = [app, *ios_extensions, *watch_apps, *watch_extensions]
    for bundle in bundles:
        if bundle.is_symlink() or not bundle.is_dir():
            raise ValueError(f"embedded bundle is not a regular directory: {bundle}")
        require_descendant(bundle, app, "embedded bundle")
    return [(bundle, "." if bundle == app else bundle.relative_to(app).as_posix()) for bundle in bundles]


def build_manifest(args: argparse.Namespace) -> dict[str, Any]:
    if not re.fullmatch(r"[0-9a-f]{40}", args.git_sha):
        raise ValueError("git SHA must be exact lowercase hexadecimal")
    archive_uuid = str(uuid.UUID(args.archive_uuid)).lower()
    if not args.configuration or len(args.configuration.encode()) > 32:
        raise ValueError("configuration is missing or oversized")
    info_path = args.app / "Info.plist"
    info = read_plist(info_path)
    main_bundle_id = require_string(info, "CFBundleIdentifier", info_path)
    if require_string(info, "OpenClawBuildGitSHA", info_path) != args.git_sha:
        raise ValueError("embedded source SHA differs from symbolication input")
    if str(uuid.UUID(require_string(info, "OpenClawBuildArchiveUUID", info_path))).lower() != archive_uuid:
        raise ValueError("embedded archive UUID differs from symbolication input")
    if require_string(info, "OpenClawBuildConfiguration", info_path) != args.configuration:
        raise ValueError("embedded configuration differs from symbolication input")

    records = [
        bundle_record(
            bundle,
            relative_path,
            main_bundle_id,
            args.dwarfdump,
            args.dsymutil,
            args.temporary_directory,
        )
        for bundle, relative_path in discover_bundles(args.app)
    ]
    records.sort(key=lambda item: item["bundle_relative_path"])
    expected_ids = {
        main_bundle_id,
        *require_string_list(info, "OpenClawBuildExtensionBundleIDs", info_path),
        *require_string_list(info, "OpenClawBuildWatchBundleIDs", info_path),
    }
    if len(expected_ids) != 5 or {record["bundle_id"] for record in records} != expected_ids:
        raise ValueError("embedded bundle identifiers differ from build provenance")
    if sum(record["executable_role"] == "compiled_product" for record in records) != 4:
        raise ValueError("expected four compiled executables")
    if sum(record["executable_role"] == "sdk_watchkit_stub" for record in records) != 1:
        raise ValueError("expected one Xcode WatchKit launcher stub")
    return {
        "schema": SCHEMA,
        "git_sha": args.git_sha,
        "archive_uuid": archive_uuid,
        "build_number": require_string(info, "CFBundleVersion", info_path),
        "configuration": args.configuration,
        "executables": records,
    }


def write_manifest(args: argparse.Namespace) -> None:
    temporary_output = args.output.with_suffix(args.output.suffix + ".tmp")
    for candidate in (args.output, temporary_output):
        if candidate.is_symlink() or candidate.is_file():
            candidate.unlink()
        elif candidate.exists():
            raise ValueError(f"refusing non-file symbolication output: {candidate}")
    require_descendant(args.output.parent, args.app, "symbolication output directory")
    try:
        manifest = build_manifest(args)
        data = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
        if len(data) > MAXIMUM_BYTES:
            raise ValueError("runtime symbolication manifest exceeds size bound")
        temporary_output.write_bytes(data)
        temporary_output.replace(args.output)
    except Exception:
        for candidate in (args.output, temporary_output):
            if candidate.is_symlink() or candidate.is_file():
                candidate.unlink()
        raise


def main() -> None:
    args = parse_args()
    args.temporary_directory.mkdir(parents=True, exist_ok=True)
    if args.temporary_directory.is_symlink() or not args.temporary_directory.is_dir():
        raise ValueError("temporary directory is not a regular directory")
    write_manifest(args)


if __name__ == "__main__":
    main()
