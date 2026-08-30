#!/usr/bin/env python3
"""Write an attributable, secret-free manifest for an archived OpenClaw iOS build."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import uuid
from typing import Any


SCHEMA = "argus.openclaw-ios.build-manifest.v1"
ARCHIVE_PRE_EXPORT = "ARCHIVE_PRE_EXPORT"
EXPORTED_IPA_POST_EXPORT = "EXPORTED_IPA_POST_EXPORT"
UNSIGNED_ARCHIVE_QUALIFICATION = "UNSIGNED_ARCHIVE_QUALIFICATION"
ARTIFACT_STAGES = (
    ARCHIVE_PRE_EXPORT,
    EXPORTED_IPA_POST_EXPORT,
    UNSIGNED_ARCHIVE_QUALIFICATION,
)
STAGE_B_RECEIPT_NAME = "OpenClaw-signing-entitlements.json"
STAGE_A_RECEIPT_NAME = "OpenClaw-archive-signing-entitlements.json"
UUID_PATTERN = re.compile(r"UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)")
TEAM_ID_PATTERN = re.compile(r"^[A-Z0-9]{10}$")
RUNTIME_SYMBOLICATION_SCHEMA = (
    "argus.openclaw-ios.runtime-symbolication-manifest.v1"
)
RUNTIME_SYMBOLICATION_FILE = "AIESRuntimeSymbolicationManifest.json"
RUNTIME_SYMBOLICATION_MAXIMUM_BYTES = 64 * 1024


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
    parser.add_argument(
        "--artifact-stage",
        choices=ARTIFACT_STAGES,
        help=(
            "Explicit artifact/distribution stage. The signed lane's existing "
            "--archive-only and --ipa selectors map to ARCHIVE_PRE_EXPORT and "
            "EXPORTED_IPA_POST_EXPORT; unsigned IPA-shaped qualification artifacts "
            "must select UNSIGNED_ARCHIVE_QUALIFICATION."
        ),
    )
    parser.add_argument(
        "--distribution-verification",
        type=pathlib.Path,
        help=(
            "Complete Stage-B exported-IPA verifier receipt. Post-export manifests "
            f"default to the sibling {STAGE_B_RECEIPT_NAME}."
        ),
    )
    parser.add_argument(
        "--archive-verification",
        type=pathlib.Path,
        help=(
            "Complete Stage-A archive-integrity receipt. Signed archive manifests "
            f"default to the sibling {STAGE_A_RECEIPT_NAME}."
        ),
    )
    parser.add_argument("--expected-main-bundle-id")
    parser.add_argument("--expected-team-id")
    parser.add_argument("--archive-zip", type=pathlib.Path, required=True)
    parser.add_argument("--dsym-zip", type=pathlib.Path, required=True)
    parser.add_argument("--github-run-id")
    parser.add_argument("--dwarfdump", default="dwarfdump")
    parser.add_argument("--codesign", default="codesign")
    parser.add_argument("--security", default="security")
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


def normalized_uuid_slices(value: Any, source: str) -> list[dict[str, str]]:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{source} has no UUID slices")
    result: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict) or set(item) != {"uuid", "architecture"}:
            raise ValueError(f"{source} contains malformed UUID slice")
        raw_uuid = item.get("uuid")
        architecture = item.get("architecture")
        if not isinstance(raw_uuid, str) or not isinstance(architecture, str):
            raise ValueError(f"{source} contains non-string UUID slice")
        try:
            normalized_uuid = str(uuid.UUID(raw_uuid)).lower()
        except ValueError as error:
            raise ValueError(f"{source} contains malformed UUID") from error
        if not architecture or len(architecture.encode()) > 64:
            raise ValueError(f"{source} contains malformed architecture")
        result.append({"uuid": normalized_uuid, "architecture": architecture})
    result.sort(key=lambda item: (item["architecture"], item["uuid"]))
    if len({(item["architecture"], item["uuid"]) for item in result}) != len(result):
        raise ValueError(f"{source} contains duplicate UUID slice")
    return result


def safe_bundle_relative_path(value: Any) -> pathlib.PurePosixPath:
    if not isinstance(value, str) or not value or len(value.encode()) > 256:
        raise ValueError("runtime symbolication bundle path is missing or oversized")
    if value == ".":
        return pathlib.PurePosixPath(".")
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or "\\" in value or any(
        component in {"", ".", ".."} for component in value.split("/")
    ):
        raise ValueError("runtime symbolication bundle path is unsafe")
    return path


def require_resolved_descendant(
    path: pathlib.Path, root: pathlib.Path, label: str
) -> None:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (FileNotFoundError, ValueError) as error:
        raise ValueError(f"runtime symbolication {label} escapes its controlled root") from error


def verify_runtime_symbolication_manifest(
    args: argparse.Namespace,
    app_path: pathlib.Path,
    *,
    main_bundle_id: str,
    version_build_number: str,
    archive_uuid: str,
) -> dict[str, Any]:
    path = app_path / RUNTIME_SYMBOLICATION_FILE
    if path.is_symlink() or not path.is_file():
        raise ValueError("archive lacks regular runtime symbolication manifest")
    data = path.read_bytes()
    if not data or len(data) > RUNTIME_SYMBOLICATION_MAXIMUM_BYTES:
        raise ValueError("runtime symbolication manifest violates size bound")
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("runtime symbolication manifest is malformed") from error
    required_keys = {
        "schema",
        "git_sha",
        "archive_uuid",
        "build_number",
        "configuration",
        "executables",
    }
    if not isinstance(value, dict) or set(value) != required_keys:
        raise ValueError("runtime symbolication manifest keys are malformed")
    expected_provenance = {
        "schema": RUNTIME_SYMBOLICATION_SCHEMA,
        "git_sha": args.git_sha,
        "archive_uuid": archive_uuid,
        "build_number": version_build_number,
        "configuration": args.configuration,
    }
    for key, expected in expected_provenance.items():
        if value.get(key) != expected:
            raise ValueError(f"runtime symbolication {key} mismatch")
    records = value.get("executables")
    if not isinstance(records, list) or len(records) != 5:
        raise ValueError("runtime symbolication manifest requires five executables")
    expected_record_keys = {
        "bundle_id",
        "bundle_relative_path",
        "executable_name",
        "executable_role",
        "executable_uuids",
        "dsym_requirement",
        "dsym_status",
        "dsym_uuids",
    }
    verified: list[dict[str, Any]] = []
    seen_paths: set[pathlib.PurePosixPath] = set()
    seen_ids: set[str] = set()
    expected_ids = {
        main_bundle_id,
        *string_list(
            read_plist(app_path / "Info.plist"),
            "OpenClawBuildExtensionBundleIDs",
            app_path / "Info.plist",
        ),
        *string_list(
            read_plist(app_path / "Info.plist"),
            "OpenClawBuildWatchBundleIDs",
            app_path / "Info.plist",
        ),
    }
    if len(expected_ids) != 5:
        raise ValueError("runtime symbolication provenance does not name five bundle IDs")
    for item in records:
        if not isinstance(item, dict) or set(item) != expected_record_keys:
            raise ValueError("runtime symbolication executable record keys are malformed")
        relative = safe_bundle_relative_path(item["bundle_relative_path"])
        bundle = app_path if relative == pathlib.PurePosixPath(".") else app_path / relative
        if relative in seen_paths or bundle.is_symlink() or not bundle.is_dir():
            raise ValueError("runtime symbolication bundle path is missing or duplicate")
        require_resolved_descendant(bundle, app_path, "bundle path")
        seen_paths.add(relative)
        info_path = bundle / "Info.plist"
        if info_path.is_symlink() or not info_path.is_file():
            raise ValueError("runtime symbolication bundle Info.plist is missing")
        require_resolved_descendant(info_path, bundle, "bundle Info.plist")
        info = read_plist(info_path)
        bundle_id = require_string(info, "CFBundleIdentifier", info_path)
        executable_name = require_string(info, "CFBundleExecutable", info_path)
        if item["bundle_id"] != bundle_id or item["executable_name"] != executable_name:
            raise ValueError("runtime symbolication bundle/executable identity mismatch")
        if bundle_id in seen_ids:
            raise ValueError("runtime symbolication bundle identifier is duplicated")
        seen_ids.add(bundle_id)
        executable_path = bundle / executable_name
        if not executable_path.is_file() or executable_path.is_symlink():
            raise ValueError("runtime symbolication executable is missing")
        require_resolved_descendant(executable_path, bundle, "bundle executable")
        observed_executable = sorted(
            run_dwarfdump(executable_path, args.dwarfdump),
            key=lambda record: (record["architecture"], record["uuid"]),
        )
        embedded_executable = normalized_uuid_slices(
            item["executable_uuids"], f"runtime executable {bundle_id}"
        )
        if embedded_executable != observed_executable:
            raise ValueError("runtime symbolication executable UUID mismatch")
        is_watch_application = (
            len(relative.parts) == 2
            and relative.parts[0] == "Watch"
            and relative.parts[1].endswith(".app")
        )
        if item["executable_role"] == "sdk_watchkit_stub":
            if (
                not is_watch_application
                or item["dsym_requirement"] != "not_applicable_sdk_watchkit_stub"
                or item["dsym_status"] != "not_emitted"
                or item["dsym_uuids"] != []
                or info.get("WKWatchKitApp") is not True
                or info.get("WKCompanionAppBundleIdentifier") != main_bundle_id
            ):
                raise ValueError("runtime symbolication WatchKit launcher contract mismatch")
            if (args.archive / "dSYMs" / f"{bundle.name}.dSYM").exists():
                raise ValueError("runtime symbolication WatchKit launcher has unexpected dSYM")
        elif item["executable_role"] == "compiled_product":
            if (
                is_watch_application
                or item["dsym_requirement"] != "required_compiled_executable"
                or item["dsym_status"] != "uuid_matched_during_build"
            ):
                raise ValueError("runtime symbolication compiled dSYM contract mismatch")
            dsym_binary = (
                args.archive
                / "dSYMs"
                / f"{bundle.name}.dSYM"
                / "Contents"
                / "Resources"
                / "DWARF"
                / executable_name
            )
            if not dsym_binary.is_file() or dsym_binary.is_symlink():
                raise ValueError("runtime symbolication matching archive dSYM is missing")
            require_resolved_descendant(
                dsym_binary,
                args.archive / "dSYMs",
                "archive dSYM executable",
            )
            observed_dsym = sorted(
                run_dwarfdump(dsym_binary, args.dwarfdump),
                key=lambda record: (record["architecture"], record["uuid"]),
            )
            embedded_dsym = normalized_uuid_slices(
                item["dsym_uuids"], f"runtime dSYM {bundle_id}"
            )
            if observed_dsym != observed_executable or embedded_dsym != observed_dsym:
                raise ValueError("runtime symbolication executable/dSYM UUID mismatch")
        else:
            raise ValueError("runtime symbolication executable role is unsupported")
        verified.append(item)
    if seen_ids != expected_ids:
        raise ValueError("runtime symbolication bundle identifiers differ from provenance")
    if len([item for item in verified if item["executable_role"] == "compiled_product"]) != 4:
        raise ValueError("runtime symbolication requires four compiled products")
    if len([item for item in verified if item["executable_role"] == "sdk_watchkit_stub"]) != 1:
        raise ValueError("runtime symbolication requires one WatchKit launcher")
    return {
        "status": "verified_archive_executable_and_dsym_mapping",
        "schema": RUNTIME_SYMBOLICATION_SCHEMA,
        "resource_file_name": RUNTIME_SYMBOLICATION_FILE,
        "resource_sha256": hashlib.sha256(data).hexdigest(),
        "executables": verified,
    }


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


def resolve_artifact_stage(args: argparse.Namespace) -> str:
    archive_only = bool(getattr(args, "archive_only", False))
    ipa = getattr(args, "ipa", None)
    explicit_stage = getattr(args, "artifact_stage", None)
    if explicit_stage is not None and explicit_stage not in ARTIFACT_STAGES:
        raise ValueError(f"unsupported artifact stage: {explicit_stage!r}")

    if archive_only:
        stage = explicit_stage or ARCHIVE_PRE_EXPORT
        if stage != ARCHIVE_PRE_EXPORT:
            raise ValueError("--archive-only requires ARCHIVE_PRE_EXPORT")
        if ipa is not None:
            raise ValueError("archive-only manifest must not include an IPA")
        return stage

    if ipa is None:
        raise ValueError("IPA-backed manifest is missing --ipa")
    if explicit_stage is None:
        # The protected signed lane predates --artifact-stage, but its --ipa
        # selector is unambiguous only inside the already-gated internal-release
        # context. All credential-free/diagnostic IPA callers must name the stage.
        if os.environ.get("AIES_INTERNAL_ONLY_CONFIRMED") != "true":
            raise ValueError(
                "IPA-backed manifest requires explicit --artifact-stage outside "
                "the protected internal-release context"
            )
        stage = EXPORTED_IPA_POST_EXPORT
    else:
        stage = explicit_stage
    if stage == ARCHIVE_PRE_EXPORT:
        raise ValueError("ARCHIVE_PRE_EXPORT must use --archive-only")
    return stage


def trusted_release_identity(
    args: argparse.Namespace, observed_main_bundle_id: str
) -> tuple[str, str]:
    expected_main_bundle_id = (
        getattr(args, "expected_main_bundle_id", None)
        or os.environ.get("ASC_APP_IDENTIFIER")
    )
    expected_team_id = (
        getattr(args, "expected_team_id", None)
        or os.environ.get("IOS_DEVELOPMENT_TEAM")
    )
    if expected_main_bundle_id != observed_main_bundle_id:
        raise ValueError(
            "trusted release main bundle ID mismatch: "
            f"expected {expected_main_bundle_id!r}, found {observed_main_bundle_id!r}"
        )
    if not isinstance(expected_team_id, str) or not TEAM_ID_PATTERN.fullmatch(
        expected_team_id
    ):
        raise ValueError("trusted release Team ID is missing or malformed")
    return expected_main_bundle_id, expected_team_id


def read_receipt_once(path: pathlib.Path, stage_name: str) -> tuple[bytes, dict[str, Any]]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing regular {stage_name} receipt: {path}")
    try:
        receipt_bytes = path.read_bytes()
        receipt = json.loads(receipt_bytes.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid {stage_name} receipt: {path}") from error
    if not isinstance(receipt, dict):
        raise ValueError(f"invalid {stage_name} receipt object: {path}")
    return receipt_bytes, receipt


def canonical_json_bytes(value: Any) -> bytes:
    """Return a type-preserving canonical encoding for exact receipt comparison."""

    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def replay_signing_verification(
    args: argparse.Namespace,
    *,
    archive_only: bool,
    expected_main_bundle_id: str,
    expected_team_id: str,
) -> dict[str, Any]:
    """Re-run the qualified verifier against the exact current artifact inputs."""

    from verify_aies_internal_signing import build_report, validate_report_contract

    replay_args = argparse.Namespace(
        archive=args.archive,
        ipa=None if archive_only else args.ipa,
        archive_only=archive_only,
        expected_main_bundle_id=expected_main_bundle_id,
        expected_team_id=expected_team_id,
        expected_git_sha=args.git_sha,
        expected_archive_uuid=str(uuid.UUID(args.archive_uuid)).lower(),
        codesign=args.codesign,
        dwarfdump=args.dwarfdump,
        security=getattr(args, "security", "security"),
    )
    report = build_report(replay_args)
    validate_report_contract(report, archive_only=archive_only)
    return report


def require_app_identity(
    receipt: dict[str, Any],
    section_name: str,
    *,
    main_bundle_id: str,
    version: str,
    build_number: str,
    git_sha: str,
    archive_uuid: str,
) -> None:
    section = receipt.get(section_name)
    app = section.get("app") if isinstance(section, dict) else None
    if not isinstance(app, dict):
        raise ValueError(f"signing receipt is missing {section_name} app identity")
    expected = {
        "bundle_id": main_bundle_id,
        "version": version,
        "build_number": build_number,
        "build_git_sha": git_sha,
        "build_archive_uuid": archive_uuid,
    }
    for key, value in expected.items():
        if app.get(key) != value:
            raise ValueError(
                f"signing receipt {section_name} app {key} mismatch: "
                f"expected {value!r}, found {app.get(key)!r}"
            )


def main_bundle_receipt(
    receipt: dict[str, Any], section_name: str, main_bundle_id: str
) -> dict[str, Any]:
    section = receipt.get(section_name)
    bundles = section.get("bundles") if isinstance(section, dict) else None
    if not isinstance(bundles, list):
        raise ValueError(f"signing receipt is missing {section_name} bundles")
    matches = [
        item
        for item in bundles
        if isinstance(item, dict) and item.get("bundle_id") == main_bundle_id
    ]
    if len(matches) != 1:
        raise ValueError(
            f"signing receipt has ambiguous {section_name} main-app coverage"
        )
    return matches[0]


def load_replayed_signing_verification(
    path: pathlib.Path,
    args: argparse.Namespace,
    *,
    archive_only: bool,
    main_bundle_id: str,
    version: str,
    build_number: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    stage_name = "Stage-A archive-integrity" if archive_only else "Stage-B distribution"
    receipt_bytes, receipt = read_receipt_once(path, stage_name)
    from verify_aies_internal_signing import validate_report_contract

    try:
        validate_report_contract(receipt, archive_only=archive_only)
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(f"invalid {stage_name} receipt contract: {path}") from error
    expected_main_bundle_id, expected_team_id = trusted_release_identity(
        args, main_bundle_id
    )

    ipa_sha256_before = None if archive_only else sha256(args.ipa)
    replay = replay_signing_verification(
        args,
        archive_only=archive_only,
        expected_main_bundle_id=expected_main_bundle_id,
        expected_team_id=expected_team_id,
    )
    if canonical_json_bytes(receipt) != canonical_json_bytes(replay):
        raise ValueError(
            f"{stage_name} receipt does not exactly match verifier replay "
            "against the current artifacts"
        )
    ipa_sha256_after = None if archive_only else sha256(args.ipa)
    if ipa_sha256_before != ipa_sha256_after:
        raise ValueError("exported IPA changed during Stage-B receipt replay")

    archive_uuid = str(uuid.UUID(args.archive_uuid)).lower()
    require_app_identity(
        receipt,
        "archive",
        main_bundle_id=main_bundle_id,
        version=version,
        build_number=build_number,
        git_sha=args.git_sha,
        archive_uuid=archive_uuid,
    )
    if not archive_only:
        require_app_identity(
            receipt,
            "ipa",
            main_bundle_id=main_bundle_id,
            version=version,
            build_number=build_number,
            git_sha=args.git_sha,
            archive_uuid=archive_uuid,
        )
    archive_main = main_bundle_receipt(receipt, "archive", main_bundle_id)
    summary = {
        "status": receipt["status"],
        "receipt_file_name": path.name,
        "receipt_sha256": hashlib.sha256(receipt_bytes).hexdigest(),
        "receipt_schema": receipt["schema"],
        "expected_main_bundle_id": expected_main_bundle_id,
        "expected_team_id": expected_team_id,
        "verifier_replayed_against_current_artifacts": True,
        "ipa_sha256": ipa_sha256_after,
    }
    return summary, archive_main


def build_manifest(args: argparse.Namespace) -> dict[str, Any]:
    artifact_stage = resolve_artifact_stage(args)
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
    expected_aps_environment = normalized_embedded_aps or None

    archive_only = artifact_stage == ARCHIVE_PRE_EXPORT
    artifacts = [
        artifact_record("xcarchive", args.archive_zip),
        artifact_record("dsyms", args.dsym_zip),
    ]
    if not archive_only:
        artifacts.insert(0, artifact_record("ipa", args.ipa))

    version = require_string(info, "CFBundleShortVersionString", info_path)
    build_number = require_string(info, "CFBundleVersion", info_path)
    main_bundle_id = require_string(info, "CFBundleIdentifier", info_path)
    runtime_symbolication = verify_runtime_symbolication_manifest(
        args,
        app_path,
        main_bundle_id=main_bundle_id,
        version_build_number=build_number,
        archive_uuid=archive_uuid,
    )
    if artifact_stage == EXPORTED_IPA_POST_EXPORT:
        if expected_aps_environment != "production":
            raise ValueError(
                "post-export main-app distribution expectation must be production"
            )
        if getattr(args, "archive_verification", None) is not None:
            raise ValueError(
                "EXPORTED_IPA_POST_EXPORT consumes the archive evidence embedded "
                "in the complete Stage-B receipt"
            )
        receipt_path = getattr(args, "distribution_verification", None)
        if receipt_path is None:
            receipt_path = args.output.with_name(STAGE_B_RECEIPT_NAME)
        receipt, archive_main = load_replayed_signing_verification(
            receipt_path,
            args,
            archive_only=False,
            main_bundle_id=main_bundle_id,
            version=version,
            build_number=build_number,
        )
        if receipt["ipa_sha256"] != artifacts[0]["sha256"]:
            raise ValueError("Stage-B replay IPA digest differs from manifest artifact")
        aps_environment = archive_main.get("aps_environment")
        archive_integrity_verification = {
            "status": "verified_within_stage_b_replay",
            "expected_main_bundle_id": receipt["expected_main_bundle_id"],
            "expected_team_id": receipt["expected_team_id"],
            "verifier_replayed_against_current_artifacts": True,
        }
        readiness = {
            "status": "VERIFIED_POST_EXPORT",
            "final_distribution_verified": True,
            "upload_eligible": True,
        }
        final_distribution_verification: dict[str, Any] = receipt
    elif artifact_stage == ARCHIVE_PRE_EXPORT:
        if getattr(args, "distribution_verification", None) is not None:
            raise ValueError(
                "ARCHIVE_PRE_EXPORT must not consume a Stage-B distribution receipt"
            )
        archive_receipt_path = getattr(args, "archive_verification", None)
        if archive_receipt_path is None:
            archive_receipt_path = args.output.with_name(STAGE_A_RECEIPT_NAME)
        archive_integrity_verification, archive_main = (
            load_replayed_signing_verification(
                archive_receipt_path,
                args,
                archive_only=True,
                main_bundle_id=main_bundle_id,
                version=version,
                build_number=build_number,
            )
        )
        aps_environment = archive_main.get("aps_environment")
        readiness = {
            "status": "NOT_FINAL_PRE_EXPORT",
            "final_distribution_verified": False,
            "upload_eligible": False,
        }
        final_distribution_verification = {
            "status": "pending_exported_ipa_stage_b",
            "required_stage": EXPORTED_IPA_POST_EXPORT,
            "receipt_file_name": None,
            "receipt_sha256": None,
            "ipa_sha256": None,
        }
    else:
        if getattr(args, "distribution_verification", None) is not None:
            raise ValueError(
                "UNSIGNED_ARCHIVE_QUALIFICATION must not consume a distribution receipt"
            )
        if getattr(args, "archive_verification", None) is not None:
            raise ValueError(
                "UNSIGNED_ARCHIVE_QUALIFICATION must not consume a signed Stage-A receipt"
            )
        aps_environment = signed_aps_environment(app_path, args.codesign)
        archive_integrity_verification = {
            "status": "not_applicable_unsigned_qualification",
            "receipt_file_name": None,
            "receipt_sha256": None,
            "verifier_replayed_against_current_artifacts": False,
        }
        readiness = {
            "status": "NOT_APPLICABLE_UNSIGNED",
            "final_distribution_verified": False,
            "upload_eligible": False,
        }
        final_distribution_verification = {
            "status": "not_applicable_unsigned_qualification",
            "required_stage": EXPORTED_IPA_POST_EXPORT,
            "receipt_file_name": None,
            "receipt_sha256": None,
            "ipa_sha256": None,
        }

    return {
        "schema": SCHEMA,
        "artifact_stage": artifact_stage,
        "evidence_stage": (
            "archive"
            if artifact_stage == ARCHIVE_PRE_EXPORT
            else "export"
            if artifact_stage == EXPORTED_IPA_POST_EXPORT
            else "unsigned"
        ),
        "distribution_readiness": readiness,
        "embedded_distribution_expectations": {
            "main_app_aps_environment": expected_aps_environment,
            "enforcement_stage": EXPORTED_IPA_POST_EXPORT,
        },
        "observed_archive_signing": {
            "main_app_aps_environment": aps_environment,
            "main_app_get_task_allow": (
                archive_main.get("get_task_allow")
                if artifact_stage != UNSIGNED_ARCHIVE_QUALIFICATION
                else None
            ),
            "main_app_team_identifier": (
                archive_main.get("team_identifier")
                if artifact_stage != UNSIGNED_ARCHIVE_QUALIFICATION
                else None
            ),
            "main_app_profile_type": (
                archive_main.get("profile", {}).get("profile_type")
                if artifact_stage != UNSIGNED_ARCHIVE_QUALIFICATION
                else None
            ),
            "distribution_expectation_enforced_against_archive": False,
        },
        "archive_integrity_verification": archive_integrity_verification,
        "final_distribution_verification": final_distribution_verification,
        "git_sha": args.git_sha,
        "git_branch": args.git_branch,
        "version": version,
        "build_number": build_number,
        "build_timestamp": args.build_timestamp,
        "xcode_version": args.xcode_version,
        "swift_version": args.swift_version,
        "sdk_version": args.sdk_version,
        "main_bundle_id": main_bundle_id,
        "extension_bundle_ids": ios_extensions,
        "watch_bundle_ids_if_present": watch_bundles,
        "archive_uuid": archive_uuid,
        "main_binary_uuids": main_binary_slices,
        "dsym_uuids": sorted(dsym_uuids),
        "dsym_slices": sorted(dsym_slices, key=lambda item: (item["bundle"], item["architecture"])),
        "runtime_symbolication": runtime_symbolication,
        "configuration": args.configuration,
        "aps_environment_if_signed": aps_environment,
        "github_run_id": args.github_run_id,
        "artifacts": artifacts,
    }


def main() -> None:
    args = parse_args()
    temp_output = args.output.with_suffix(args.output.suffix + ".tmp")
    for candidate in (args.output, temp_output):
        if candidate.is_symlink() or candidate.is_file():
            candidate.unlink()
        elif candidate.exists():
            raise ValueError(f"refusing non-file manifest output path: {candidate}")
    try:
        manifest = build_manifest(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temp_output.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        temp_output.replace(args.output)
    except Exception:
        for candidate in (args.output, temp_output):
            if candidate.is_symlink() or candidate.is_file():
                candidate.unlink()
        raise


if __name__ == "__main__":
    main()
