#!/usr/bin/env python3
"""Write an attributable, secret-free manifest for an archived OpenClaw iOS build."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import uuid
from typing import Any


SCHEMA = "argus.openclaw-ios.build-manifest.v1"
UUID_PATTERN = re.compile(r"UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--git-branch", required=True)
    parser.add_argument("--build-timestamp", required=True)
    parser.add_argument("--xcode-version", required=True)
    parser.add_argument("--swift-version", required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--archive-uuid", required=True)
    payload = parser.add_mutually_exclusive_group(required=True)
    payload.add_argument("--ipa", type=pathlib.Path)
    payload.add_argument("--archive-only", action="store_true")
    parser.add_argument("--archive-zip", type=pathlib.Path, required=True)
    parser.add_argument("--dsym-zip", type=pathlib.Path, required=True)
    parser.add_argument("--github-run-id")
    parser.add_argument("--dwarfdump", default="dwarfdump")
    parser.add_argument("--codesign", default="codesign")
    return parser.parse_args()


def read_plist(path: pathlib.Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"expected dictionary plist: {path}")
    return value


def require_string(mapping: dict[str, Any], key: str, source: pathlib.Path) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"missing {key} in {source}")
    return value.strip()


def string_list(mapping: dict[str, Any], key: str, source: pathlib.Path) -> list[str]:
    value = mapping.get(key)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"missing or invalid {key} in {source}")
    return sorted({item.strip() for item in value if item.strip()})


def bundle_ids(paths: list[pathlib.Path]) -> list[str]:
    identifiers: set[str] = set()
    for path in paths:
        info_path = path / "Info.plist"
        if not info_path.is_file():
            continue
        identifier = read_plist(info_path).get("CFBundleIdentifier")
        if isinstance(identifier, str) and identifier.strip():
            identifiers.add(identifier.strip())
    return sorted(identifiers)


def run_dwarfdump(path: pathlib.Path, executable: str) -> list[dict[str, str]]:
    result = subprocess.run(
        [executable, "--uuid", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    slices = []
    for match in UUID_PATTERN.finditer(result.stdout):
        slices.append({"uuid": match.group(1).lower(), "architecture": match.group(2)})
    if not slices:
        raise ValueError(f"dwarfdump returned no UUIDs for {path}")
    return slices


def signed_aps_environment(app_path: pathlib.Path, executable: str) -> str | None:
    result = subprocess.run(
        [executable, "-d", "--entitlements", ":-", str(app_path)],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    combined = result.stdout + result.stderr
    start = combined.find(b"<?xml")
    end_marker = b"</plist>"
    end = combined.find(end_marker, start)
    if start < 0 or end < 0:
        return None
    try:
        entitlements = plistlib.loads(combined[start : end + len(end_marker)])
    except Exception:
        return None
    value = entitlements.get("aps-environment") if isinstance(entitlements, dict) else None
    return value if value in {"development", "production"} else None


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def artifact_record(kind: str, path: pathlib.Path) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"missing {kind} artifact: {path}")
    return {
        "kind": kind,
        "file_name": path.name,
        "size_bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def build_manifest(args: argparse.Namespace) -> dict[str, Any]:
    archive_uuid = str(uuid.UUID(args.archive_uuid)).lower()
    app_path = args.archive / "Products" / "Applications" / "OpenClaw.app"
    info_path = app_path / "Info.plist"
    info = read_plist(info_path)
    executable_name = require_string(info, "CFBundleExecutable", info_path)
    executable_path = app_path / executable_name
    if not executable_path.is_file():
        raise ValueError(f"missing archived executable: {executable_path}")

    main_binary_slices = run_dwarfdump(executable_path, args.dwarfdump)
    dsym_slices: list[dict[str, str]] = []
    for dsym in sorted((args.archive / "dSYMs").glob("*.dSYM")):
        for item in run_dwarfdump(dsym, args.dwarfdump):
            dsym_slices.append({**item, "bundle": dsym.name})
    if not dsym_slices:
        raise ValueError("archive contains no attributable dSYM UUIDs")

    main_binary_uuids = {item["uuid"] for item in main_binary_slices}
    dsym_uuids = {item["uuid"] for item in dsym_slices}
    missing_main_uuids = sorted(main_binary_uuids - dsym_uuids)
    if missing_main_uuids:
        raise ValueError(
            "main app binary UUIDs have no matching dSYM: " + ", ".join(missing_main_uuids)
        )

    ios_extensions = bundle_ids(sorted((app_path / "PlugIns").glob("*.appex")))
    watch_root = app_path / "Watch"
    watch_bundles = bundle_ids(sorted(watch_root.rglob("*.app")) + sorted(watch_root.rglob("*.appex")))
    aps_environment = signed_aps_environment(app_path, args.codesign)

    embedded_expectations = {
        "OpenClawBuildGitSHA": args.git_sha,
        "OpenClawBuildGitBranch": args.git_branch,
        "OpenClawBuildTimestamp": args.build_timestamp,
        "OpenClawBuildXcodeVersion": args.xcode_version,
        "OpenClawBuildSwiftVersion": args.swift_version,
        "OpenClawBuildSDKVersion": args.sdk_version,
        "OpenClawBuildConfiguration": args.configuration,
        "OpenClawBuildArchiveUUID": archive_uuid,
    }
    for key, expected in embedded_expectations.items():
        actual = require_string(info, key, info_path)
        if actual != expected:
            raise ValueError(f"embedded {key} mismatch: expected {expected!r}, found {actual!r}")

    embedded_extensions = string_list(info, "OpenClawBuildExtensionBundleIDs", info_path)
    if embedded_extensions != ios_extensions:
        raise ValueError(
            f"embedded extension bundle IDs mismatch: expected {ios_extensions!r}, "
            f"found {embedded_extensions!r}"
        )
    embedded_watch = string_list(info, "OpenClawBuildWatchBundleIDs", info_path)
    if embedded_watch != watch_bundles:
        raise ValueError(
            f"embedded Watch bundle IDs mismatch: expected {watch_bundles!r}, found {embedded_watch!r}"
        )
    embedded_aps = info.get("OpenClawBuildAPSEnvironmentIfSigned")
    normalized_embedded_aps = embedded_aps.strip() if isinstance(embedded_aps, str) else ""
    if normalized_embedded_aps != (aps_environment or ""):
        raise ValueError(
            "embedded APNs environment does not match the archived app signature"
        )

    archive_only = getattr(args, "archive_only", False)
    artifacts = [
        artifact_record("xcarchive", args.archive_zip),
        artifact_record("dsyms", args.dsym_zip),
    ]
    if not archive_only:
        artifacts.insert(0, artifact_record("ipa", args.ipa))

    return {
        "schema": SCHEMA,
        "evidence_stage": "archive" if archive_only else "export",
        "git_sha": args.git_sha,
        "git_branch": args.git_branch,
        "version": require_string(info, "CFBundleShortVersionString", info_path),
        "build_number": require_string(info, "CFBundleVersion", info_path),
        "build_timestamp": args.build_timestamp,
        "xcode_version": args.xcode_version,
        "swift_version": args.swift_version,
        "sdk_version": args.sdk_version,
        "main_bundle_id": require_string(info, "CFBundleIdentifier", info_path),
        "extension_bundle_ids": ios_extensions,
        "watch_bundle_ids_if_present": watch_bundles,
        "archive_uuid": archive_uuid,
        "main_binary_uuids": main_binary_slices,
        "dsym_uuids": sorted(dsym_uuids),
        "dsym_slices": sorted(dsym_slices, key=lambda item: (item["bundle"], item["architecture"])),
        "configuration": args.configuration,
        "aps_environment_if_signed": aps_environment,
        "github_run_id": args.github_run_id,
        "artifacts": artifacts,
    }


def main() -> None:
    args = parse_args()
    manifest = build_manifest(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
