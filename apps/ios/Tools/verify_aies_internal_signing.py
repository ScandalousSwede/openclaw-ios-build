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

SCHEMA = "argus.openclaw-ios.signing-report.v1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--ipa", type=pathlib.Path, required=True)
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
        return {
            "certificate_chain_count": len(certificate_chain),
            "leaf_certificate_sha256": sha256_bytes(leaf_path.read_bytes()),
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
    if entitlements.get("beta-reports-active") is not True:
        raise ValueError(
            f"profile is not authorized for App Store Connect/TestFlight in {source}"
        )
    return {
        "uuid": require_text(profile, "UUID", source),
        "name": require_text(profile, "Name", source),
        "team_identifiers": sorted(team_ids),
        "application_identifier": entitlements.get("application-identifier"),
        "aps_environment": entitlements.get("aps-environment"),
        "beta_reports_active": True,
        "get_task_allow": entitlements.get("get-task-allow", False),
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
    if entitlements.get("get-task-allow") is True:
        raise ValueError(f"distribution bundle has get-task-allow enabled: {bundle_id}")

    verify_code_signature(path, codesign, deep=path == app_path)
    signing_identity = verify_signing_identity(path, codesign, security)
    raw_profile = read_profile(path, security)
    profile = selected_profile_fields(raw_profile, bundle_id)
    if expected_team_id not in profile["team_identifiers"]:
        raise ValueError(f"profile team mismatch for {bundle_id}")
    if not isinstance(
        profile["application_identifier"], str
    ) or not string_entitlement_authorized(
        profile["application_identifier"], expected_application_identifier
    ):
        raise ValueError(f"profile application identifier mismatch for {bundle_id}")
    if profile["get_task_allow"] is True:
        raise ValueError(
            f"distribution profile has get-task-allow enabled: {bundle_id}"
        )
    if profile["provisioned_device_count"] != 0 or profile["provisions_all_devices"]:
        raise ValueError(f"non-App-Store provisioning profile for {bundle_id}")
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

    return {
        "bundle_id": bundle_id,
        "relative_path": str(path.relative_to(app_path.parent)),
        "team_identifier": team_id,
        "application_identifier": application_identifier,
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
        record = verify_bundle(path, app_path, expected_team_id, codesign, security)
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
    if main_record["aps_environment"] != "production":
        raise ValueError("main app signed aps-environment is not production")
    if main_record["profile"]["aps_environment"] != "production":
        raise ValueError("main app profile aps-environment is not production")
    return {
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


def signature_stripped_sha256(path: pathlib.Path, codesign: str) -> str:
    with tempfile.TemporaryDirectory() as raw_temp:
        stripped = pathlib.Path(raw_temp) / path.name
        shutil.copy2(path, stripped)
        run_tool([codesign, "--remove-signature", str(stripped)], combine_output=True)
        return sha256_bytes(stripped.read_bytes())


def executable_identity(
    app_path: pathlib.Path, codesign: str, dwarfdump: str
) -> dict[str, Any]:
    info = read_plist(app_path / "Info.plist")
    executable_name = require_text(
        info, "CFBundleExecutable", str(app_path / "Info.plist")
    )
    if pathlib.PurePath(executable_name).name != executable_name:
        raise ValueError("CFBundleExecutable must be a single path component")
    executable = app_path / executable_name
    if not executable.is_file():
        raise ValueError(f"missing bundle executable: {executable_name}")
    return {
        "name": executable_name,
        "raw_sha256": sha256_bytes(executable.read_bytes()),
        "signature_stripped_sha256": signature_stripped_sha256(executable, codesign),
        "uuids": macho_uuids(executable, dwarfdump),
    }


def verify_binary_binding(
    archive: pathlib.Path,
    archive_app: pathlib.Path,
    ipa_app: pathlib.Path,
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
        ipa_bundle = (
            ipa_app
            if relative_path == pathlib.PurePosixPath(".")
            else ipa_app / relative_path
        )
        archive_identity = executable_identity(archive_bundle, codesign, dwarfdump)
        ipa_identity = executable_identity(ipa_bundle, codesign, dwarfdump)
        bound_fields = ("name", "signature_stripped_sha256", "uuids")
        if any(
            archive_identity[field] != ipa_identity[field] for field in bound_fields
        ):
            raise ValueError(
                "archive and exported IPA executable identity differ for "
                f"{expected_bundle_id}"
            )

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
                "ipa_executable": ipa_identity,
                "dsym": {
                    "relative_path": str(dsym_binary.relative_to(archive)),
                    "sha256": sha256_bytes(dsym_binary.read_bytes()),
                    "uuids": dsym_uuids,
                },
            }
        )
    return {"bundles": records}


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
    )
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
    relay_base_url = archive_result["app"]["push_relay_base_url"]
    return {
        "schema": SCHEMA,
        "status": "verified",
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
        "binary_binding": binary_binding,
        "archive": archive_result,
        "ipa": ipa_result,
    }


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
