#!/usr/bin/env python3
"""Fail-closed identity verification for unsigned AIES iOS artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile
from typing import Any

SCHEMA = "argus.openclaw-ios.unsigned-archive-report.v1"
BUILD_SETTINGS_SCHEMA = "argus.openclaw-ios.unsigned-build-settings-report.v2"


def expected_target_bundle_identifiers(main_bundle_id: str) -> dict[str, str]:
    return {
        "OpenClaw": main_bundle_id,
        "OpenClawShareExtension": f"{main_bundle_id}.share",
        "OpenClawActivityWidget": f"{main_bundle_id}.activitywidget",
        "OpenClawWatchApp": f"{main_bundle_id}.watchkitapp",
        "OpenClawWatchExtension": f"{main_bundle_id}.watchkitapp.extension",
    }


def build_settings_topology_report(
    payload: Any, expected_main_bundle_id: str
) -> dict[str, Any]:
    """Verify the rendered unsigned build settings before archive creation."""

    if not isinstance(payload, list):
        raise ValueError("xcodebuild build-settings payload must be an array")
    expected_targets = expected_target_bundle_identifiers(expected_main_bundle_id)
    expected_variables = {
        "OPENCLAW_APP_BUNDLE_ID": expected_main_bundle_id,
        "OPENCLAW_SHARE_BUNDLE_ID": f"{expected_main_bundle_id}.share",
        "OPENCLAW_ACTIVITY_WIDGET_BUNDLE_ID": (
            f"{expected_main_bundle_id}.activitywidget"
        ),
        "OPENCLAW_WATCH_APP_BUNDLE_ID": f"{expected_main_bundle_id}.watchkitapp",
        "OPENCLAW_WATCH_EXTENSION_BUNDLE_ID": (
            f"{expected_main_bundle_id}.watchkitapp.extension"
        ),
    }
    records: dict[str, dict[str, Any]] = {}
    for source_index, item in enumerate(payload):
        if not isinstance(item, dict):
            raise ValueError("xcodebuild build-settings entry must be an object")
        target = item.get("target")
        if target not in expected_targets:
            continue
        settings = item.get("buildSettings")
        if not isinstance(settings, dict):
            raise ValueError(
                f"missing buildSettings object for target {target} "
                f"at source index {source_index}"
            )
        actual_bundle_id = settings.get("PRODUCT_BUNDLE_IDENTIFIER")
        expected_bundle_id = expected_targets[target]
        if actual_bundle_id != expected_bundle_id:
            raise ValueError(
                f"rendered bundle identifier mismatch for {target} "
                f"at source index {source_index}: "
                f"expected={expected_bundle_id!r} actual={actual_bundle_id!r}"
            )
        for name, expected_value in expected_variables.items():
            actual_value = settings.get(name)
            if actual_value != expected_value:
                raise ValueError(
                    f"rendered AIES topology variable mismatch for {target}/{name} "
                    f"at source index {source_index}: "
                    f"expected={expected_value!r} actual={actual_value!r}"
                )
        for name in ("CODE_SIGNING_ALLOWED", "CODE_SIGNING_REQUIRED"):
            actual_value = settings.get(name)
            if actual_value != "NO":
                raise ValueError(
                    f"unsigned build setting {name} must be NO for {target} "
                    f"at source index {source_index}: "
                    f"actual={actual_value!r}"
                )
        for name in (
            "CODE_SIGN_IDENTITY",
            "DEVELOPMENT_TEAM",
            "PROVISIONING_PROFILE_SPECIFIER",
        ):
            actual_value = settings.get(name)
            if actual_value not in (None, ""):
                raise ValueError(
                    f"unsigned build setting {name} must be empty for {target} "
                    f"at source index {source_index}: "
                    f"actual={actual_value!r}"
                )
        if target not in records:
            records[target] = {
                "bundle_id": expected_bundle_id,
                "signing": {
                    "CODE_SIGNING_ALLOWED": settings.get("CODE_SIGNING_ALLOWED"),
                    "CODE_SIGNING_REQUIRED": settings.get("CODE_SIGNING_REQUIRED"),
                    "CODE_SIGN_IDENTITY": settings.get("CODE_SIGN_IDENTITY", ""),
                    "DEVELOPMENT_TEAM": settings.get("DEVELOPMENT_TEAM", ""),
                    "PROVISIONING_PROFILE_SPECIFIER": settings.get(
                        "PROVISIONING_PROFILE_SPECIFIER", ""
                    ),
                },
                "topology_variables": dict(sorted(expected_variables.items())),
                "occurrences": [],
            }
        settings_bytes = json.dumps(
            settings,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        records[target]["occurrences"].append(
            {
                "source_index": source_index,
                "full_build_settings_sha256": hashlib.sha256(
                    settings_bytes
                ).hexdigest(),
                "context": {
                    name: settings.get(name)
                    for name in (
                        "SDKROOT",
                        "PLATFORM_NAME",
                        "EFFECTIVE_PLATFORM_NAME",
                        "SUPPORTED_PLATFORMS",
                    )
                },
            }
        )
    missing = sorted(set(expected_targets) - set(records))
    if missing:
        raise ValueError(f"missing required AIES build-settings targets: {missing!r}")
    targets = []
    for target in sorted(records):
        record = records[target]
        occurrences = record["occurrences"]
        targets.append(
            {
                "target": target,
                **record,
                "occurrence_count": len(occurrences),
            }
        )
    return {
        "schema": BUILD_SETTINGS_SCHEMA,
        "status": "verified",
        "expected_main_bundle_id": expected_main_bundle_id,
        "target_count": len(records),
        "required_entry_count": sum(
            len(record["occurrences"]) for record in records.values()
        ),
        "targets": targets,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--ipa", type=pathlib.Path, required=True)
    parser.add_argument("--archive-zip", type=pathlib.Path, required=True)
    parser.add_argument("--expected-main-bundle-id", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--dwarfdump", default="dwarfdump")
    return parser.parse_args()


def expected_bundle_topology(
    main_bundle_id: str,
) -> dict[pathlib.PurePosixPath, str]:
    return {
        pathlib.PurePosixPath("."): main_bundle_id,
        pathlib.PurePosixPath(
            "PlugIns/OpenClawShareExtension.appex"
        ): f"{main_bundle_id}.share",
        pathlib.PurePosixPath(
            "PlugIns/OpenClawActivityWidget.appex"
        ): f"{main_bundle_id}.activitywidget",
        pathlib.PurePosixPath(
            "Watch/OpenClawWatchApp.app"
        ): f"{main_bundle_id}.watchkitapp",
        pathlib.PurePosixPath(
            "Watch/OpenClawWatchApp.app/PlugIns/OpenClawWatchExtension.appex"
        ): f"{main_bundle_id}.watchkitapp.extension",
    }


def read_plist(path: pathlib.Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"missing regular Info.plist: {path}")
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"expected dictionary plist: {path}")
    return value


def require_text(mapping: dict[str, Any], key: str, source: pathlib.Path) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"missing {key} in {source}")
    return value.strip()


def sha256_file(path: pathlib.Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"missing regular artifact: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_identity(root: pathlib.Path) -> dict[str, Any]:
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f"missing archive directory: {root}")
    root = root.resolve()
    digest = hashlib.sha256()
    file_count = 0
    byte_count = 0

    def add_record(kind: str, relative: pathlib.PurePosixPath, payload: bytes) -> None:
        encoded_path = str(relative).encode("utf-8")
        digest.update(kind.encode("ascii") + b"\0")
        digest.update(len(encoded_path).to_bytes(8, "big") + encoded_path)
        digest.update(len(payload).to_bytes(8, "big") + payload)

    def visit(directory: pathlib.Path) -> None:
        nonlocal byte_count, file_count
        for entry in sorted(os.scandir(directory), key=lambda item: item.name):
            path = pathlib.Path(entry.path)
            relative = pathlib.PurePosixPath(path.relative_to(root).as_posix())
            metadata = path.lstat()
            if stat.S_ISDIR(metadata.st_mode):
                add_record("directory", relative, b"")
                visit(path)
            elif stat.S_ISREG(metadata.st_mode):
                content = path.read_bytes()
                add_record("file", relative, content)
                file_count += 1
                byte_count += len(content)
            elif stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(path)
                resolved = (path.parent / target).resolve()
                if resolved != root and root not in resolved.parents:
                    raise ValueError(f"archive contains an unsafe symlink: {relative}")
                add_record("symlink", relative, os.fsencode(target))
            else:
                raise ValueError(f"archive contains unsupported entry type: {relative}")

    visit(root)
    return {
        "sha256": digest.hexdigest(),
        "regular_file_count": file_count,
        "regular_file_bytes": byte_count,
    }


def run_tool(command: list[str]) -> bytes:
    result = subprocess.run(command, check=False, capture_output=True)
    if result.returncode != 0:
        executable = pathlib.Path(command[0]).name
        raise ValueError(
            f"{executable} verification failed with exit code {result.returncode}"
        )
    return result.stdout + result.stderr


def macho_uuids(path: pathlib.Path, dwarfdump: str) -> list[dict[str, str]]:
    output = run_tool([dwarfdump, "--uuid", str(path)]).decode(
        "utf-8", errors="replace"
    )
    values = sorted(
        {
            (match.group(2).strip(), match.group(1).lower())
            for match in re.finditer(
                r"\bUUID:\s*([0-9A-Fa-f-]{36})\s+\(([^)]+)\)", output
            )
        }
    )
    if not values:
        raise ValueError(f"dwarfdump returned no Mach-O UUID for {path.name}")
    return [
        {"architecture": architecture, "uuid": uuid}
        for architecture, uuid in values
    ]


def zip_member_path(member: zipfile.ZipInfo) -> pathlib.PurePosixPath:
    name = member.filename
    if not name or "\x00" in name or "\\" in name or name.startswith("/"):
        raise ValueError(f"ZIP contains an unsafe path: {name!r}")
    raw_parts = name.rstrip("/").split("/")
    if (
        not raw_parts
        or any(part in {"", ".", ".."} for part in raw_parts)
        or re.fullmatch(r"[A-Za-z]:.*", raw_parts[0]) is not None
    ):
        raise ValueError(f"ZIP contains an unsafe path: {name!r}")
    return pathlib.PurePosixPath(*raw_parts)


def zip_member_kind(member: zipfile.ZipInfo) -> str:
    unix_mode = (member.external_attr >> 16) & 0xFFFF
    file_type = stat.S_IFMT(unix_mode)
    if member.is_dir() or file_type == stat.S_IFDIR:
        return "directory"
    if file_type == stat.S_IFLNK:
        return "symlink"
    if file_type in (0, stat.S_IFREG):
        return "file"
    return "unsupported"


def inspect_zip(path: pathlib.Path, *, allow_safe_symlinks: bool) -> dict[str, Any]:
    artifact_hash = sha256_file(path)
    seen: set[pathlib.PurePosixPath] = set()
    member_count = 0
    uncompressed_bytes = 0
    with zipfile.ZipFile(path) as archive:
        corrupt_member = archive.testzip()
        if corrupt_member is not None:
            raise ValueError(f"ZIP integrity failed for member: {corrupt_member}")
        for member in archive.infolist():
            relative = zip_member_path(member)
            if relative in seen:
                raise ValueError(f"ZIP contains a duplicate path: {relative}")
            seen.add(relative)
            if member.flag_bits & 0x1:
                raise ValueError(f"ZIP contains encrypted content: {relative}")
            kind = zip_member_kind(member)
            if kind == "unsupported":
                raise ValueError(f"ZIP contains unsupported entry type: {relative}")
            if kind == "symlink":
                if not allow_safe_symlinks:
                    raise ValueError(f"ZIP contains a symlink: {relative}")
                target_bytes = archive.read(member)
                try:
                    target = target_bytes.decode("utf-8")
                except UnicodeDecodeError as error:
                    raise ValueError(
                        f"ZIP contains a non-text symlink target: {relative}"
                    ) from error
                candidate = relative.parent / pathlib.PurePosixPath(target)
                if (
                    pathlib.PurePosixPath(target).is_absolute()
                    or "\\" in target
                    or any(part == ".." for part in candidate.parts)
                ):
                    raise ValueError(f"ZIP contains an unsafe symlink: {relative}")
            member_count += 1
            uncompressed_bytes += member.file_size
    return {
        "sha256": artifact_hash,
        "bytes": path.stat().st_size,
        "member_count": member_count,
        "uncompressed_bytes": uncompressed_bytes,
        "integrity_verified": True,
        "path_traversal_safe": True,
    }


def safely_extract_ipa(
    ipa_path: pathlib.Path, destination: pathlib.Path
) -> pathlib.Path:
    inspect_zip(ipa_path, allow_safe_symlinks=False)
    with zipfile.ZipFile(ipa_path) as archive:
        archive.extractall(destination)
    payload = destination / "Payload"
    expected_app = payload / "OpenClaw.app"
    entries = sorted(payload.iterdir()) if payload.is_dir() else []
    if (
        entries != [expected_app]
        or not expected_app.is_dir()
        or expected_app.is_symlink()
    ):
        raise ValueError(
            "IPA Payload must contain exactly OpenClaw.app; "
            f"found={[path.name for path in entries]!r}"
        )
    return expected_app


def find_archive_app(archive: pathlib.Path) -> pathlib.Path:
    applications = archive / "Products" / "Applications"
    expected_app = applications / "OpenClaw.app"
    entries = sorted(applications.iterdir()) if applications.is_dir() else []
    if (
        entries != [expected_app]
        or not expected_app.is_dir()
        or expected_app.is_symlink()
    ):
        raise ValueError(
            "archive must contain exactly Products/Applications/OpenClaw.app; "
            f"found={[path.name for path in entries]!r}"
        )
    return expected_app


def discover_bundle_paths(app_path: pathlib.Path) -> list[pathlib.Path]:
    nested = sorted(
        set(app_path.rglob("*.app")) | set(app_path.rglob("*.appex")),
        key=lambda path: path.relative_to(app_path).as_posix(),
    )
    return [app_path, *nested]


def relative_bundle_path(
    bundle_path: pathlib.Path, app_path: pathlib.Path
) -> pathlib.PurePosixPath:
    if bundle_path == app_path:
        return pathlib.PurePosixPath(".")
    return pathlib.PurePosixPath(bundle_path.relative_to(app_path).as_posix())


def executable_identity(bundle_path: pathlib.Path, dwarfdump: str) -> dict[str, Any]:
    info_path = bundle_path / "Info.plist"
    info = read_plist(info_path)
    bundle_id = require_text(info, "CFBundleIdentifier", info_path)
    executable_name = require_text(info, "CFBundleExecutable", info_path)
    if pathlib.PurePath(executable_name).name != executable_name:
        raise ValueError(f"CFBundleExecutable must be one path component: {bundle_id}")
    executable = bundle_path / executable_name
    if not executable.is_file() or executable.is_symlink():
        raise ValueError(f"missing regular bundle executable for {bundle_id}")
    return {
        "bundle_id": bundle_id,
        "name": executable_name,
        "raw_sha256": sha256_file(executable),
        "bytes": executable.stat().st_size,
        "uuids": macho_uuids(executable, dwarfdump),
    }


def verify_app_topology(
    app_path: pathlib.Path, expected_main_bundle_id: str, dwarfdump: str
) -> list[dict[str, Any]]:
    expected = expected_bundle_topology(expected_main_bundle_id)
    paths = discover_bundle_paths(app_path)
    actual_paths = {relative_bundle_path(path, app_path) for path in paths}
    if len(paths) != len(expected) or actual_paths != set(expected):
        missing = sorted(str(path) for path in set(expected) - actual_paths)
        unexpected = sorted(str(path) for path in actual_paths - set(expected))
        raise ValueError(
            f"packaged bundle topology mismatch: count={len(paths)} "
            f"missing={missing!r} unexpected={unexpected!r}"
        )
    records: list[dict[str, Any]] = []
    for bundle_path in paths:
        relative = relative_bundle_path(bundle_path, app_path)
        if bundle_path.is_symlink() or not bundle_path.is_dir():
            raise ValueError(f"bundle is not a regular directory: {relative}")
        identity = executable_identity(bundle_path, dwarfdump)
        expected_id = expected[relative]
        if identity["bundle_id"] != expected_id:
            raise ValueError(
                f"bundle identifier does not match expected path: {relative} "
                f"expected={expected_id!r} actual={identity['bundle_id']!r}"
            )
        records.append(
            {
                "relative_path": str(relative),
                "bundle_id": expected_id,
                "executable": {
                    key: value for key, value in identity.items() if key != "bundle_id"
                },
            }
        )
    return sorted(records, key=lambda record: record["relative_path"])


def verify_dsym_bindings(
    archive: pathlib.Path,
    archive_app: pathlib.Path,
    archive_bundles: list[dict[str, Any]],
    dwarfdump: str,
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    seen: set[pathlib.Path] = set()
    for bundle in archive_bundles:
        relative = pathlib.PurePosixPath(bundle["relative_path"])
        bundle_path = (
            archive_app
            if relative == pathlib.PurePosixPath(".")
            else archive_app / relative
        )
        executable = bundle["executable"]
        dsym_binary = (
            archive
            / "dSYMs"
            / f"{bundle_path.name}.dSYM"
            / "Contents"
            / "Resources"
            / "DWARF"
            / executable["name"]
        )
        if dsym_binary in seen:
            raise ValueError(f"duplicate dSYM binding for {bundle['bundle_id']}")
        seen.add(dsym_binary)
        if not dsym_binary.is_file() or dsym_binary.is_symlink():
            raise ValueError(f"missing matching dSYM binary for {bundle['bundle_id']}")
        dsym_uuids = macho_uuids(dsym_binary, dwarfdump)
        if dsym_uuids != executable["uuids"]:
            raise ValueError(
                f"archive executable and dSYM UUIDs differ for {bundle['bundle_id']}"
            )
        records.append(
            {
                "bundle_id": bundle["bundle_id"],
                "bundle_relative_path": bundle["relative_path"],
                "archive_executable": executable,
                "dsym": {
                    "relative_path": dsym_binary.relative_to(archive).as_posix(),
                    "sha256": sha256_file(dsym_binary),
                    "bytes": dsym_binary.stat().st_size,
                    "uuids": dsym_uuids,
                },
            }
        )
    return records


def verify_archive_ipa_binding(
    archive_records: list[dict[str, Any]], ipa_records: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    archive_by_path = {record["relative_path"]: record for record in archive_records}
    ipa_by_path = {record["relative_path"]: record for record in ipa_records}
    if set(archive_by_path) != set(ipa_by_path):
        raise ValueError("archive and IPA bundle topology differs")
    bound: list[dict[str, Any]] = []
    for relative in sorted(archive_by_path):
        archive_record = archive_by_path[relative]
        ipa_record = ipa_by_path[relative]
        if archive_record["bundle_id"] != ipa_record["bundle_id"]:
            raise ValueError(f"archive and IPA bundle identifier differ for {relative}")
        archive_executable = archive_record["executable"]
        ipa_executable = ipa_record["executable"]
        if archive_executable != ipa_executable:
            raise ValueError(
                "archive and IPA unsigned executable identity differ for "
                f"{archive_record['bundle_id']}"
            )
        bound.append(
            {
                "bundle_id": archive_record["bundle_id"],
                "bundle_relative_path": relative,
                "archive_executable": archive_executable,
                "ipa_executable": ipa_executable,
            }
        )
    return bound


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    archive_tree = tree_identity(args.archive)
    archive_zip = inspect_zip(args.archive_zip, allow_safe_symlinks=True)
    ipa_zip = inspect_zip(args.ipa, allow_safe_symlinks=False)
    archive_app = find_archive_app(args.archive)
    archive_bundles = verify_app_topology(
        archive_app, args.expected_main_bundle_id, args.dwarfdump
    )
    dsym_bindings = verify_dsym_bindings(
        args.archive,
        archive_app,
        archive_bundles,
        args.dwarfdump,
    )
    with tempfile.TemporaryDirectory() as raw_temp:
        ipa_app = safely_extract_ipa(args.ipa, pathlib.Path(raw_temp))
        ipa_bundles = verify_app_topology(
            ipa_app, args.expected_main_bundle_id, args.dwarfdump
        )
        binary_bindings = verify_archive_ipa_binding(archive_bundles, ipa_bundles)
    dsyms_by_id = {record["bundle_id"]: record["dsym"] for record in dsym_bindings}
    for record in binary_bindings:
        record["dsym"] = dsyms_by_id[record["bundle_id"]]
    return {
        "schema": SCHEMA,
        "status": "verified",
        "expected_main_bundle_id": args.expected_main_bundle_id,
        "bundle_count": len(archive_bundles),
        "archive": {
            "tree": archive_tree,
            "bundles": archive_bundles,
        },
        "ipa": {
            "artifact": ipa_zip,
            "bundles": ipa_bundles,
        },
        "archive_zip": archive_zip,
        "binary_binding": {"bundles": binary_bindings},
    }


def main() -> None:
    args = parse_args()
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    for candidate in (args.output, temporary):
        if candidate.is_symlink() or candidate.is_file():
            candidate.unlink()
        elif candidate.exists():
            raise ValueError(f"refusing non-file report path: {candidate}")
    try:
        report = build_report(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        shutil.move(temporary, args.output)
    except BaseException:
        for candidate in (args.output, temporary):
            if candidate.is_symlink() or candidate.is_file():
                candidate.unlink()
        raise


if __name__ == "__main__":
    main()
