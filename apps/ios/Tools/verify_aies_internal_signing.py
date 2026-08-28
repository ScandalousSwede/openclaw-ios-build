#!/usr/bin/env python3
"""Fail-closed signing and push-contract verification for AIES TestFlight builds."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from typing import Any

from aies_macho_signature_equivalence import compare_macho_payloads


SCHEMA = "argus.openclaw-ios.signing-report.v3"
WATCH_APP_RELATIVE_PATH = pathlib.PurePosixPath("Watch/OpenClawWatchApp.app")
WATCH_APP_EXECUTABLE = "OpenClawWatchApp"
WATCHKIT_STUB_RELATIVE_PATH = pathlib.PurePosixPath("_WatchKitStub/WK")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    payload = parser.add_mutually_exclusive_group(required=True)
    payload.add_argument("--ipa", type=pathlib.Path)
    payload.add_argument("--archive-only", action="store_true")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--expected-main-bundle-id", required=True)
    parser.add_argument("--expected-team-id", required=True)
    parser.add_argument("--expected-git-sha", required=True)
    parser.add_argument("--expected-archive-uuid", required=True)
    parser.add_argument("--codesign", default="codesign")
    parser.add_argument("--dwarfdump", default="dwarfdump")
    parser.add_argument("--security", default="security")
    return parser.parse_args()


def read_plist(path: pathlib.Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"expected dictionary plist: {path}")
    return value


def require_text(mapping: dict[str, Any], key: str, source: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"missing {key} in {source}")
    return value.strip()


def run_tool(command: list[str], *, combine_output: bool = False) -> bytes:
    result = subprocess.run(command, check=False, capture_output=True)
    if result.returncode != 0:
        executable = pathlib.Path(command[0]).name
        raise ValueError(
            f"{executable} verification failed with exit code {result.returncode}"
        )
    return result.stdout + result.stderr if combine_output else result.stdout


def plist_from_tool_output(output: bytes, source: str) -> dict[str, Any]:
    xml_start = output.find(b"<?xml")
    xml_end = output.find(b"</plist>", xml_start)
    if xml_start < 0 or xml_end < 0:
        raise ValueError(f"{source} returned no plist")
    value = plistlib.loads(output[xml_start : xml_end + len(b"</plist>")])
    if not isinstance(value, dict):
        raise ValueError(f"{source} returned a non-dictionary plist")
    return value


def read_code_entitlements(path: pathlib.Path, codesign: str) -> dict[str, Any]:
    output = run_tool(
        [codesign, "-d", "--entitlements", ":-", str(path)],
        combine_output=True,
    )
    return plist_from_tool_output(output, "codesign")


def verify_code_signature(path: pathlib.Path, codesign: str, *, deep: bool) -> None:
    command = [codesign, "--verify", "--strict", "--verbose=2"]
    if deep:
        command.append("--deep")
    command.append(str(path))
    run_tool(command, combine_output=True)


def read_profile(path: pathlib.Path, security: str) -> dict[str, Any]:
    profile_path = path / "embedded.mobileprovision"
    if not profile_path.is_file():
        raise ValueError(f"missing embedded.mobileprovision for {path.name}")
    output = run_tool([security, "cms", "-D", "-i", str(profile_path)])
    return plist_from_tool_output(output, "security cms")


def as_iso8601(value: Any, source: str) -> str:
    if not isinstance(value, dt.datetime):
        raise ValueError(f"missing expiration date in {source}")
    normalized = value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)
    return normalized.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def expected_bundle_topology(main_bundle_id: str) -> dict[pathlib.PurePosixPath, str]:
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


def signable_bundles(app_path: pathlib.Path) -> list[pathlib.Path]:
    nested = sorted(set(app_path.rglob("*.app")) | set(app_path.rglob("*.appex")))
    return [app_path, *nested]


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def verify_signing_identity(
    path: pathlib.Path, codesign: str, security: str
) -> dict[str, Any]:
    with tempfile.TemporaryDirectory() as raw_temp:
        certificate_prefix = pathlib.Path(raw_temp) / "signing-cert-"
        run_tool(
            [codesign, "-d", f"--extract-certificates={certificate_prefix}", str(path)],
            combine_output=True,
        )
        leaf_path = pathlib.Path(f"{certificate_prefix}0")
        if not leaf_path.is_file() or not leaf_path.read_bytes():
            raise ValueError(
                f"codesign returned no signing leaf certificate for {path.name}"
            )
        certificate_chain = sorted(pathlib.Path(raw_temp).glob("signing-cert-*"))
        if not certificate_chain or certificate_chain[0] != leaf_path:
            raise ValueError(
                f"codesign returned an invalid certificate chain for {path.name}"
            )
        trust_command = [security, "verify-cert"]
        for certificate in certificate_chain:
            trust_command.extend(["-c", str(certificate)])
        trust_command.extend(["-p", "codeSign", "-L"])
        run_tool(
            trust_command,
            combine_output=True,
        )
        authority_output = run_tool(
            [codesign, "-d", "--verbose=4", str(path)], combine_output=True
        ).decode("utf-8", errors="replace")
        authorities = re.findall(r"^Authority=(.+)$", authority_output, re.MULTILINE)
        if not authorities:
            raise ValueError(f"codesign returned no signing authority for {path.name}")
        return {
            "certificate_chain_count": len(certificate_chain),
            "leaf_certificate_sha256": sha256_bytes(leaf_path.read_bytes()),
            "authorities": authorities,
            "leaf_common_name": authorities[0],
            "trust_verified": True,
        }


def selected_profile_fields(profile: dict[str, Any], source: str) -> dict[str, Any]:
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise ValueError(f"missing profile entitlements in {source}")
    team_ids = profile.get("TeamIdentifier")
    if not isinstance(team_ids, list) or not all(
        isinstance(item, str) for item in team_ids
    ):
        raise ValueError(f"missing TeamIdentifier in {source}")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        raise ValueError(f"missing expiration date in {source}")
    normalized_expiration = (
        expiration if expiration.tzinfo else expiration.replace(tzinfo=dt.timezone.utc)
    )
    if normalized_expiration <= dt.datetime.now(dt.timezone.utc):
        raise ValueError(f"expired provisioning profile for {source}")
    provisioned_devices = profile.get("ProvisionedDevices", [])
    if not isinstance(provisioned_devices, list):
        raise ValueError(f"invalid ProvisionedDevices in {source}")
    developer_certificates = profile.get("DeveloperCertificates")
    if (
        not isinstance(developer_certificates, list)
        or not developer_certificates
        or not all(isinstance(item, bytes) and item for item in developer_certificates)
    ):
        raise ValueError(f"missing DeveloperCertificates in {source}")
    get_task_allow = entitlements.get("get-task-allow")
    beta_reports_active = entitlements.get("beta-reports-active")
    if get_task_allow is True or provisioned_devices:
        profile_type = "development"
    elif profile.get("ProvisionsAllDevices") is True:
        profile_type = "enterprise"
    elif beta_reports_active is True:
        profile_type = "app-store-connect"
    else:
        profile_type = "unknown"
    return {
        "uuid": require_text(profile, "UUID", source),
        "name": require_text(profile, "Name", source),
        "team_identifiers": sorted(team_ids),
        "application_identifier": entitlements.get("application-identifier"),
        "keychain_access_groups": entitlements.get("keychain-access-groups", []),
        "aps_environment": entitlements.get("aps-environment"),
        "beta_reports_active": beta_reports_active,
        "get_task_allow": get_task_allow,
        "profile_type": profile_type,
        "expiration_at": as_iso8601(expiration, source),
        "provisioned_device_count": len(provisioned_devices),
        "provisions_all_devices": profile.get("ProvisionsAllDevices", False) is True,
        "developer_certificate_sha256": sorted(
            sha256_bytes(item) for item in developer_certificates
        ),
        # security cms -D decodes Apple's CMS profile envelope. Authenticity is
        # bounded separately by trusted signer validation plus exact membership
        # of the signing leaf in the profile's DeveloperCertificates array.
        "cms_decoded_by_security": True,
    }


def string_entitlement_authorized(profile_value: str, signed_value: str) -> bool:
    if profile_value == signed_value:
        return True
    # A signed wildcard is never considered narrower than a different profile value.
    if "*" in signed_value:
        return False
    pattern = "^" + re.escape(profile_value).replace(r"\*", ".*") + "$"
    return re.fullmatch(pattern, signed_value) is not None


def entitlement_value_authorized(profile_value: Any, signed_value: Any) -> bool:
    if isinstance(profile_value, str) and isinstance(signed_value, str):
        return string_entitlement_authorized(profile_value, signed_value)
    if isinstance(profile_value, list) and isinstance(signed_value, list):
        return all(
            any(
                entitlement_value_authorized(candidate, item)
                for candidate in profile_value
            )
            for item in signed_value
        )
    if isinstance(profile_value, dict) and isinstance(signed_value, dict):
        return all(
            key in profile_value
            and entitlement_value_authorized(profile_value[key], value)
            for key, value in signed_value.items()
        )
    return type(profile_value) is type(signed_value) and profile_value == signed_value


def verify_entitlement_authorization(
    signed: dict[str, Any],
    profile: dict[str, Any],
    expected_team_id: str,
    bundle_id: str,
) -> list[str]:
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        raise ValueError(f"missing profile entitlements for {bundle_id}")
    authorized: list[str] = []
    for key, signed_value in signed.items():
        if (
            key == "com.apple.developer.team-identifier"
            and key not in profile_entitlements
        ):
            # Apple profiles structurally carry this identity in TeamIdentifier even
            # when the redundant entitlement is omitted.
            team_ids = profile.get("TeamIdentifier")
            if (
                signed_value != expected_team_id
                or not isinstance(team_ids, list)
                or expected_team_id not in team_ids
            ):
                raise ValueError(
                    f"signed entitlement is not authorized by profile: {bundle_id} {key}"
                )
            authorized.append(key)
            continue
        if key not in profile_entitlements or not entitlement_value_authorized(
            profile_entitlements[key], signed_value
        ):
            raise ValueError(
                f"signed entitlement is not authorized by profile: {bundle_id} {key}"
            )
        authorized.append(key)
    return sorted(authorized)


def verify_bundle(
    path: pathlib.Path,
    app_path: pathlib.Path,
    expected_team_id: str,
    codesign: str,
    security: str,
    *,
    distribution: bool,
) -> dict[str, Any]:
    info_path = path / "Info.plist"
    info = read_plist(info_path)
    bundle_id = require_text(info, "CFBundleIdentifier", str(info_path))
    entitlements = read_code_entitlements(path, codesign)
    team_id = entitlements.get("com.apple.developer.team-identifier")
    application_identifier = entitlements.get("application-identifier")
    expected_application_identifier = f"{expected_team_id}.{bundle_id}"
    if team_id != expected_team_id:
        raise ValueError(f"signed team mismatch for {bundle_id}")
    if application_identifier != expected_application_identifier:
        raise ValueError(f"signed application identifier mismatch for {bundle_id}")
    verify_code_signature(path, codesign, deep=path == app_path)
    signing_identity = verify_signing_identity(path, codesign, security)
    raw_profile = read_profile(path, security)
    profile = selected_profile_fields(raw_profile, bundle_id)
    if profile["team_identifiers"] != [expected_team_id]:
        raise ValueError(f"profile team mismatch for {bundle_id}")
    if not isinstance(
        profile["application_identifier"], str
    ) or not string_entitlement_authorized(
        profile["application_identifier"], expected_application_identifier
    ):
        raise ValueError(f"profile application identifier mismatch for {bundle_id}")
    if (
        signing_identity["leaf_certificate_sha256"]
        not in profile["developer_certificate_sha256"]
    ):
        raise ValueError(
            f"signing certificate is not authorized by profile for {bundle_id}"
        )
    authorized_entitlement_keys = verify_entitlement_authorization(
        entitlements,
        raw_profile,
        expected_team_id,
        bundle_id,
    )
    if distribution:
        if entitlements.get("get-task-allow") is not False:
            raise ValueError(
                f"distribution bundle must explicitly disable get-task-allow: {bundle_id}"
            )
        if profile["get_task_allow"] is not False:
            raise ValueError(
                f"distribution profile must explicitly disable get-task-allow: {bundle_id}"
            )
        if profile["profile_type"] != "app-store-connect":
            raise ValueError(
                f"profile is not App Store Connect distribution: {bundle_id}"
            )
        if profile["beta_reports_active"] is not True:
            raise ValueError(
                f"profile is not authorized for App Store Connect/TestFlight: {bundle_id}"
            )
        if (
            profile["provisioned_device_count"] != 0
            or profile["provisions_all_devices"]
        ):
            raise ValueError(f"non-App-Store provisioning profile for {bundle_id}")
        leaf_common_name = signing_identity.get("leaf_common_name")
        if not isinstance(leaf_common_name, str) or not leaf_common_name.startswith(
            "Apple Distribution:"
        ):
            raise ValueError(
                f"bundle is not signed by Apple Distribution: {bundle_id}"
            )

    return {
        "bundle_id": bundle_id,
        "relative_path": str(path.relative_to(app_path.parent)),
        "team_identifier": team_id,
        "application_identifier": application_identifier,
        "keychain_access_groups": entitlements.get("keychain-access-groups", []),
        "get_task_allow": entitlements.get("get-task-allow"),
        "aps_environment": entitlements.get("aps-environment"),
        "authorized_entitlement_keys": authorized_entitlement_keys,
        "profile": profile,
        "signing_identity": signing_identity,
    }


def verify_push_and_provenance(
    app_path: pathlib.Path,
    expected_main_bundle_id: str,
    expected_git_sha: str,
    expected_archive_uuid: str,
) -> dict[str, str]:
    info_path = app_path / "Info.plist"
    info = read_plist(info_path)
    expected = {
        "CFBundleIdentifier": expected_main_bundle_id,
        "OpenClawPushTransport": "direct",
        "OpenClawPushDistribution": "local",
        "OpenClawPushAPNsEnvironment": "production",
        "OpenClawBuildGitSHA": expected_git_sha,
        "OpenClawBuildConfiguration": "Release",
        "OpenClawBuildArchiveUUID": expected_archive_uuid,
        "OpenClawBuildAPSEnvironmentIfSigned": "production",
    }
    for key, wanted in expected.items():
        actual = info.get(key)
        if actual != wanted:
            raise ValueError(f"{key} mismatch: expected {wanted!r}, found {actual!r}")
    relay = info.get("OpenClawPushRelayBaseURL")
    if not isinstance(relay, str) or relay != "":
        raise ValueError(
            "OpenClawPushRelayBaseURL must be the exact empty string for direct AIES push"
        )
    return {
        "bundle_id": expected_main_bundle_id,
        "version": require_text(info, "CFBundleShortVersionString", str(info_path)),
        "build_number": require_text(info, "CFBundleVersion", str(info_path)),
        "push_transport": "direct",
        "push_distribution": "local",
        "push_relay_base_url": relay,
        "push_apns_environment": "production",
        "build_git_sha": expected_git_sha,
        "build_archive_uuid": expected_archive_uuid,
    }


def verify_app(
    app_path: pathlib.Path,
    expected_main_bundle_id: str,
    expected_team_id: str,
    expected_git_sha: str,
    expected_archive_uuid: str,
    codesign: str,
    security: str,
    *,
    distribution: bool = True,
) -> dict[str, Any]:
    if not app_path.is_dir():
        raise ValueError(f"missing app bundle: {app_path}")
    app_info = verify_push_and_provenance(
        app_path,
        expected_main_bundle_id,
        expected_git_sha,
        expected_archive_uuid,
    )
    topology = expected_bundle_topology(expected_main_bundle_id)
    paths = signable_bundles(app_path)
    actual_relative_paths = [
        (
            pathlib.PurePosixPath(".")
            if path == app_path
            else pathlib.PurePosixPath(path.relative_to(app_path).as_posix())
        )
        for path in paths
    ]
    if len(paths) != len(topology) or set(actual_relative_paths) != set(topology):
        missing = sorted(
            str(path) for path in set(topology) - set(actual_relative_paths)
        )
        unexpected = sorted(
            str(path) for path in set(actual_relative_paths) - set(topology)
        )
        raise ValueError(
            f"packaged bundle topology mismatch: count={len(paths)} missing={missing!r} unexpected={unexpected!r}"
        )
    bundles = []
    for path, relative_path in zip(paths, actual_relative_paths):
        record = verify_bundle(
            path,
            app_path,
            expected_team_id,
            codesign,
            security,
            distribution=distribution,
        )
        expected_bundle_id = topology[relative_path]
        if record["bundle_id"] != expected_bundle_id:
            raise ValueError(
                f"bundle identifier does not match expected path: {relative_path} "
                f"expected={expected_bundle_id!r} actual={record['bundle_id']!r}"
            )
        bundles.append(record)
    main_record = next(
        item for item in bundles if item["bundle_id"] == expected_main_bundle_id
    )
    if distribution:
        if main_record["aps_environment"] != "production":
            raise ValueError("main app signed aps-environment is not production")
        if main_record["profile"]["aps_environment"] != "production":
            raise ValueError("main app profile aps-environment is not production")
        for record in bundles:
            if record is main_record:
                continue
            if record["aps_environment"] is not None:
                raise ValueError(
                    "unexpected signed aps-environment for non-push target: "
                    + record["bundle_id"]
                )
            if record["profile"]["aps_environment"] is not None:
                raise ValueError(
                    "unexpected profile aps-environment for non-push target: "
                    + record["bundle_id"]
                )
    return {
        "verification_stage": (
            "exported_ipa_distribution" if distribution else "archive_integrity"
        ),
        "app": app_info,
        "bundles": sorted(bundles, key=lambda item: item["relative_path"]),
    }


def safely_extract_ipa(
    ipa_path: pathlib.Path, destination: pathlib.Path
) -> pathlib.Path:
    if not ipa_path.is_file():
        raise ValueError(f"missing IPA: {ipa_path}")
    destination_root = destination.resolve()
    with zipfile.ZipFile(ipa_path) as archive:
        for member in archive.infolist():
            candidate = (destination / member.filename).resolve()
            if (
                candidate != destination_root
                and destination_root not in candidate.parents
            ):
                raise ValueError("IPA contains an unsafe path")
        archive.extractall(destination)
    payload = destination / "Payload"
    expected_app = payload / "OpenClaw.app"
    entries = sorted(payload.iterdir()) if payload.is_dir() else []
    if entries != [expected_app] or not expected_app.is_dir():
        raise ValueError(
            "IPA Payload must contain exactly OpenClaw.app; "
            f"found={[path.name for path in entries]!r}"
        )
    return expected_app


def macho_uuids(path: pathlib.Path, dwarfdump: str) -> list[dict[str, str]]:
    output = run_tool([dwarfdump, "--uuid", str(path)], combine_output=True).decode(
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
        {"architecture": architecture, "uuid": uuid} for architecture, uuid in values
    ]


def bundle_executable_path(app_path: pathlib.Path) -> pathlib.Path:
    info = read_plist(app_path / "Info.plist")
    executable_name = require_text(
        info, "CFBundleExecutable", str(app_path / "Info.plist")
    )
    if pathlib.PurePath(executable_name).name != executable_name:
        raise ValueError("CFBundleExecutable must be a single path component")
    executable = app_path / executable_name
    if not executable.is_file():
        raise ValueError(f"missing bundle executable: {executable_name}")
    return executable


def executable_identity(
    app_path: pathlib.Path, codesign: str, dwarfdump: str
) -> dict[str, Any]:
    executable = bundle_executable_path(app_path)
    return {
        "name": executable.name,
        "raw_sha256": sha256_bytes(executable.read_bytes()),
        "uuids": macho_uuids(executable, dwarfdump),
    }


def verify_watchkit_stub_binding(
    bundle_path: pathlib.Path,
    executable: dict[str, Any],
    expected_main_bundle_id: str,
    codesign: str,
    dwarfdump: str,
) -> dict[str, Any]:
    """Prove the legacy Watch app launcher is Xcode's embedded SDK stub."""

    info_path = bundle_path / "Info.plist"
    info = read_plist(info_path)
    if info.get("WKWatchKitApp") is not True:
        raise ValueError("Watch app SDK-stub role requires WKWatchKitApp=true")
    companion = info.get("WKCompanionAppBundleIdentifier")
    if companion != expected_main_bundle_id:
        raise ValueError(
            "Watch app SDK-stub companion identifier mismatch: "
            f"expected={expected_main_bundle_id!r} actual={companion!r}"
        )
    if executable.get("name") != WATCH_APP_EXECUTABLE:
        raise ValueError(
            "Watch app SDK-stub executable mismatch: "
            f"expected={WATCH_APP_EXECUTABLE!r} actual={executable.get('name')!r}"
        )

    stub_directory = bundle_path / WATCHKIT_STUB_RELATIVE_PATH.parent
    stub_path = bundle_path / WATCHKIT_STUB_RELATIVE_PATH
    if (
        not stub_directory.is_dir()
        or stub_directory.is_symlink()
        or not stub_path.is_file()
        or stub_path.is_symlink()
    ):
        raise ValueError("missing regular Xcode WatchKit SDK stub")
    stub = {
        "relative_path": WATCHKIT_STUB_RELATIVE_PATH.as_posix(),
        "raw_sha256": sha256_bytes(stub_path.read_bytes()),
        "uuids": macho_uuids(stub_path, dwarfdump),
    }
    if stub["uuids"] != executable.get("uuids"):
        raise ValueError("Watch app executable does not match embedded SDK stub: uuids")
    stub_equivalence = compare_macho_payloads(
        bundle_executable_path(bundle_path), stub_path
    )
    return {
        "kind": "xcode_watchkit_sdk_stub",
        "plist_contract": {
            "WKWatchKitApp": True,
            "WKCompanionAppBundleIdentifier": expected_main_bundle_id,
        },
        "embedded_stub": stub,
        "bundle_executable_match": {
            "uuids": True,
            "signature_aware_payload_equivalence": stub_equivalence,
        },
    }


def verify_archive_dsym_binding(
    archive: pathlib.Path,
    archive_app: pathlib.Path,
    codesign: str,
    dwarfdump: str,
    expected_main_bundle_id: str,
) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    seen_dsyms: set[pathlib.Path] = set()
    for relative_path, expected_bundle_id in expected_bundle_topology(
        expected_main_bundle_id
    ).items():
        archive_bundle = (
            archive_app
            if relative_path == pathlib.PurePosixPath(".")
            else archive_app / relative_path
        )
        archive_identity = executable_identity(archive_bundle, codesign, dwarfdump)
        dsym_binary = (
            archive
            / "dSYMs"
            / f"{archive_bundle.name}.dSYM"
            / "Contents"
            / "Resources"
            / "DWARF"
            / archive_identity["name"]
        )
        if dsym_binary in seen_dsyms:
            raise ValueError(f"duplicate dSYM binding for {expected_bundle_id}")
        seen_dsyms.add(dsym_binary)
        if relative_path == WATCH_APP_RELATIVE_PATH:
            expected_watch_id = f"{expected_main_bundle_id}.watchkitapp"
            if expected_bundle_id != expected_watch_id:
                raise ValueError("Watch app SDK-stub bundle identifier mismatch")
            dsym_root = archive / "dSYMs" / f"{archive_bundle.name}.dSYM"
            if dsym_root.exists() or dsym_root.is_symlink():
                raise ValueError(
                    "unexpected dSYM for Xcode WatchKit SDK-stub executable"
                )
            records.append(
                {
                    "bundle_id": expected_bundle_id,
                    "bundle_relative_path": str(relative_path),
                    "archive_executable": archive_identity,
                    "executable_role": "sdk_watchkit_stub",
                    "dsym_requirement": "not_applicable_sdk_watchkit_stub",
                    "dsym_status": "not_emitted",
                    "dsym": None,
                    "watchkit_stub": {
                        "archive": verify_watchkit_stub_binding(
                            archive_bundle,
                            archive_identity,
                            expected_main_bundle_id,
                            codesign,
                            dwarfdump,
                        )
                    },
                }
            )
            continue
        if not dsym_binary.is_file():
            raise ValueError(f"missing matching dSYM binary for {expected_bundle_id}")
        dsym_uuids = macho_uuids(dsym_binary, dwarfdump)
        if dsym_uuids != archive_identity["uuids"]:
            raise ValueError(
                f"archive executable and dSYM UUIDs differ for {expected_bundle_id}"
            )
        records.append(
            {
                "bundle_id": expected_bundle_id,
                "bundle_relative_path": str(relative_path),
                "archive_executable": archive_identity,
                "executable_role": "compiled_product",
                "dsym_requirement": "required_compiled_executable",
                "dsym_status": "uuid_matched",
                "dsym": {
                    "relative_path": str(dsym_binary.relative_to(archive)),
                    "sha256": sha256_bytes(dsym_binary.read_bytes()),
                    "uuids": dsym_uuids,
                },
            }
        )
    compiled = [
        record for record in records if record["executable_role"] == "compiled_product"
    ]
    stubs = [
        record
        for record in records
        if record["executable_role"] == "sdk_watchkit_stub"
    ]
    if len(compiled) != 4 or len(stubs) != 1:
        raise ValueError("unexpected compiled-product/WatchKit-stub role topology")
    return {
        "bundle_count": len(records),
        "compiled_executable_count": len(compiled),
        "sdk_watchkit_stub_count": len(stubs),
        "required_dsym_count": len(compiled),
        "verified_dsym_count": sum(
            record["dsym_status"] == "uuid_matched" for record in compiled
        ),
        "bundles": records,
    }


def verify_binary_binding(
    archive: pathlib.Path,
    archive_app: pathlib.Path,
    ipa_app: pathlib.Path,
    codesign: str,
    dwarfdump: str,
    expected_main_bundle_id: str,
) -> dict[str, Any]:
    archive_binding = verify_archive_dsym_binding(
        archive,
        archive_app,
        codesign,
        dwarfdump,
        expected_main_bundle_id,
    )
    records: list[dict[str, Any]] = []
    for record in archive_binding["bundles"]:
        relative_path = pathlib.PurePosixPath(record["bundle_relative_path"])
        ipa_bundle = (
            ipa_app
            if relative_path == pathlib.PurePosixPath(".")
            else ipa_app / relative_path
        )
        ipa_identity = executable_identity(ipa_bundle, codesign, dwarfdump)
        archive_identity = record["archive_executable"]
        bound_fields = ("name", "uuids")
        if any(
            archive_identity[field] != ipa_identity[field] for field in bound_fields
        ):
            raise ValueError(
                "archive and exported IPA executable identity differ for "
                f"{record['bundle_id']}"
            )
        payload_equivalence = compare_macho_payloads(
            bundle_executable_path(
                archive_app
                if relative_path == pathlib.PurePosixPath(".")
                else archive_app / relative_path
            ),
            bundle_executable_path(ipa_bundle),
        )
        final_record = {
            **record,
            "ipa_executable": ipa_identity,
            "archive_to_ipa_payload_equivalence": payload_equivalence,
        }
        if record["executable_role"] == "sdk_watchkit_stub":
            ipa_stub = verify_watchkit_stub_binding(
                ipa_bundle,
                ipa_identity,
                expected_main_bundle_id,
                codesign,
                dwarfdump,
            )
            archive_stub = record["watchkit_stub"]["archive"]
            if archive_stub["embedded_stub"]["uuids"] != ipa_stub[
                "embedded_stub"
            ]["uuids"]:
                raise ValueError(
                    "archive and IPA WatchKit SDK-stub identity differ: uuids"
                )
            archive_bundle = archive_app / relative_path
            stub_payload_equivalence = compare_macho_payloads(
                archive_bundle / WATCHKIT_STUB_RELATIVE_PATH,
                ipa_bundle / WATCHKIT_STUB_RELATIVE_PATH,
            )
            final_record["watchkit_stub"] = {
                "archive": archive_stub,
                "ipa": ipa_stub,
                "archive_to_ipa_payload_equivalence": stub_payload_equivalence,
            }
        records.append(final_record)
    return {
        key: value for key, value in archive_binding.items() if key != "bundles"
    } | {"bundles": records}


def validate_report_contract(report: Any, *, archive_only: bool) -> None:
    """Reject missing, malformed, ambiguous, or partial verifier receipts."""

    if not isinstance(report, dict):
        raise ValueError("signing verifier output is not a JSON object")
    expected_status = (
        "archive_integrity_verified"
        if archive_only
        else "exported_ipa_distribution_verified"
    )
    if report.get("schema") != SCHEMA or report.get("status") != expected_status:
        raise ValueError("signing verifier output has an invalid schema or status")
    contract = report.get("verification_contract")
    if not isinstance(contract, dict) or contract.get(
        "upload_requires_exported_ipa_distribution_verified"
    ) is not True:
        raise ValueError("signing verifier output has no fail-closed upload contract")
    expected_main_bundle_id = require_text(
        report, "expected_main_bundle_id", "report"
    )
    expected_ids = set(expected_bundle_topology(expected_main_bundle_id).values())
    required_sections = ["archive", "binary_binding"]
    if not archive_only:
        required_sections.append("ipa")
    for section_name in required_sections:
        section = report.get(section_name)
        if not isinstance(section, dict):
            raise ValueError(f"signing verifier output is missing {section_name}")
        bundles = section.get("bundles")
        if not isinstance(bundles, list) or len(bundles) != len(expected_ids):
            raise ValueError(
                f"signing verifier output has partial target coverage: {section_name}"
            )
        actual_ids = {
            item.get("bundle_id") for item in bundles if isinstance(item, dict)
        }
        if actual_ids != expected_ids:
            raise ValueError(
                f"signing verifier output target identities differ: {section_name}"
            )
    if not archive_only:
        ipa = report["ipa"]
        if ipa.get("verification_stage") != "exported_ipa_distribution":
            raise ValueError("exported IPA distribution stage is missing or ambiguous")
        for bundle in report["binary_binding"]["bundles"]:
            equivalence = bundle.get("archive_to_ipa_payload_equivalence")
            if not isinstance(equivalence, dict) or equivalence.get("status") != (
                "signature_aware_payload_equivalent"
            ):
                raise ValueError(
                    "signing verifier output lacks executable payload equivalence"
                )


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    applications_directory = args.archive / "Products" / "Applications"
    archive_app = applications_directory / "OpenClaw.app"
    archive_entries = (
        sorted(applications_directory.iterdir())
        if applications_directory.is_dir()
        else []
    )
    if archive_entries != [archive_app] or not archive_app.is_dir():
        raise ValueError(
            "archive must contain exactly Products/Applications/OpenClaw.app; "
            f"found={[path.name for path in archive_entries]!r}"
        )
    archive_result = verify_app(
        archive_app,
        args.expected_main_bundle_id,
        args.expected_team_id,
        args.expected_git_sha,
        args.expected_archive_uuid,
        args.codesign,
        args.security,
        distribution=False,
    )
    archive_binding = verify_archive_dsym_binding(
        args.archive,
        archive_app,
        args.codesign,
        args.dwarfdump,
        args.expected_main_bundle_id,
    )
    relay_base_url = archive_result["app"]["push_relay_base_url"]
    common = {
        "schema": SCHEMA,
        "expected_git_sha": args.expected_git_sha,
        "expected_team_id": args.expected_team_id,
        "expected_main_bundle_id": args.expected_main_bundle_id,
        "push_contract": {
            "transport": "direct",
            "distribution": "local",
            "apns_environment": "production",
            "relay_base_url": relay_base_url,
            "relay_base_url_present": relay_base_url != "",
        },
        "archive": archive_result,
        "verification_contract": {
            "archive_stage": "integrity_and_provenance_only",
            "distribution_stage": "exported_ipa_before_upload",
            "archive_development_signing_permitted": True,
            "upload_requires_exported_ipa_distribution_verified": True,
        },
    }
    if getattr(args, "archive_only", False):
        report = {
            **common,
            "status": "archive_integrity_verified",
            "binary_binding": archive_binding,
        }
        validate_report_contract(report, archive_only=True)
        return report

    with tempfile.TemporaryDirectory() as raw_temp:
        ipa_app = safely_extract_ipa(args.ipa, pathlib.Path(raw_temp))
        ipa_result = verify_app(
            ipa_app,
            args.expected_main_bundle_id,
            args.expected_team_id,
            args.expected_git_sha,
            args.expected_archive_uuid,
            args.codesign,
            args.security,
            distribution=True,
        )
        binary_binding = verify_binary_binding(
            args.archive,
            archive_app,
            ipa_app,
            args.codesign,
            args.dwarfdump,
            args.expected_main_bundle_id,
        )
    if archive_result["app"] != ipa_result["app"]:
        raise ValueError("archive and exported IPA metadata differ")
    archive_bundles = [
        (item["relative_path"], item["bundle_id"]) for item in archive_result["bundles"]
    ]
    ipa_bundles = [
        (item["relative_path"], item["bundle_id"]) for item in ipa_result["bundles"]
    ]
    if archive_bundles != ipa_bundles:
        raise ValueError("archive and exported IPA bundle topology differs")
    report = {
        **common,
        "status": "exported_ipa_distribution_verified",
        "binary_binding": binary_binding,
        "ipa": ipa_result,
    }
    validate_report_contract(report, archive_only=False)
    return report


def main() -> None:
    args = parse_args()
    temp_output = args.output.with_suffix(args.output.suffix + ".tmp")
    for candidate in (args.output, temp_output):
        if candidate.is_symlink() or candidate.is_file():
            candidate.unlink()
        elif candidate.exists():
            raise ValueError(f"refusing non-file signing report path: {candidate}")
    try:
        report = build_report(args)
        validate_report_contract(
            report, archive_only=getattr(args, "archive_only", False)
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temp_output.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        shutil.move(temp_output, args.output)
    except BaseException:
        for candidate in (args.output, temp_output):
            if candidate.is_symlink() or candidate.is_file():
                candidate.unlink()
        raise


if __name__ == "__main__":
    main()
