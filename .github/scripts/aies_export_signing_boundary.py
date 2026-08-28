#!/usr/bin/env python3
"""Inspect an existing xcarchive and an optionally exported IPA without rebuilding."""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--ipa", type=pathlib.Path)
    parser.add_argument("--source-tools", type=pathlib.Path, required=True)
    parser.add_argument("--expected-main-bundle-id", required=True)
    parser.add_argument("--expected-team-id", required=True)
    parser.add_argument("--expected-git-sha", required=True)
    parser.add_argument("--expected-archive-uuid", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def load_verifier(path: pathlib.Path):
    spec = importlib.util.spec_from_file_location("aies_signing_verifier", path)
    if spec is None or spec.loader is None:
        raise ValueError(f"unable to load signing verifier: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run(command: list[str]) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(command, check=False, capture_output=True)
    if result.returncode != 0:
        raise ValueError(
            f"{pathlib.Path(command[0]).name} failed with exit code {result.returncode}"
        )
    return result


def iso8601(value: Any) -> str | None:
    if not isinstance(value, dt.datetime):
        return None
    normalized = value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)
    return normalized.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def signing_authority(path: pathlib.Path) -> dict[str, Any]:
    result = run(["codesign", "-d", "--verbose=4", str(path)])
    text = (result.stdout + result.stderr).decode("utf-8", errors="replace")
    authorities = re.findall(r"^Authority=(.+)$", text, flags=re.MULTILINE)
    team = re.search(r"^TeamIdentifier=(.+)$", text, flags=re.MULTILINE)
    identifier = re.search(r"^Identifier=(.+)$", text, flags=re.MULTILINE)
    if not authorities:
        raise ValueError(f"codesign returned no signing authority for {path}")
    return {
        "authorities": authorities,
        "leaf_common_name": authorities[0],
        "team_identifier": team.group(1) if team else None,
        "code_identifier": identifier.group(1) if identifier else None,
    }


def profile_type(profile: dict[str, Any]) -> str:
    entitlements = profile.get("Entitlements", {})
    devices = profile.get("ProvisionedDevices", [])
    if entitlements.get("get-task-allow") is True or devices:
        return "development"
    if profile.get("ProvisionsAllDevices") is True:
        return "enterprise"
    if entitlements.get("beta-reports-active") is True:
        return "app-store-connect"
    return "unknown"


def profile_summary(profile: dict[str, Any], verifier) -> dict[str, Any]:
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise ValueError("provisioning profile has no entitlement dictionary")
    certificates = profile.get("DeveloperCertificates", [])
    if not isinstance(certificates, list) or not certificates:
        raise ValueError("provisioning profile has no developer certificates")
    devices = profile.get("ProvisionedDevices", [])
    if not isinstance(devices, list):
        raise ValueError("provisioning profile has invalid device inventory")
    return {
        "uuid": profile.get("UUID"),
        "name": profile.get("Name"),
        "type": profile_type(profile),
        "team_identifiers": profile.get("TeamIdentifier"),
        "creation_at": iso8601(profile.get("CreationDate")),
        "expiration_at": iso8601(profile.get("ExpirationDate")),
        "provisioned_device_count": len(devices),
        "provisions_all_devices": profile.get("ProvisionsAllDevices") is True,
        "application_identifier": entitlements.get("application-identifier"),
        "team_identifier": entitlements.get("com.apple.developer.team-identifier"),
        "keychain_access_groups": entitlements.get("keychain-access-groups", []),
        "get_task_allow": entitlements.get("get-task-allow", False),
        "aps_environment": entitlements.get("aps-environment"),
        "beta_reports_active": entitlements.get("beta-reports-active"),
        "entitlements": entitlements,
        "developer_certificate_sha256": sorted(
            verifier.sha256_bytes(value) for value in certificates
        ),
    }


def bundle_summary(
    path: pathlib.Path,
    app_path: pathlib.Path,
    expected_team_id: str,
    verifier,
) -> dict[str, Any]:
    info = verifier.read_plist(path / "Info.plist")
    bundle_id = verifier.require_text(info, "CFBundleIdentifier", str(path))
    entitlements = verifier.read_code_entitlements(path, "codesign")
    verifier.verify_code_signature(path, "codesign", deep=path == app_path)
    raw_profile = verifier.read_profile(path, "security")
    identity = verifier.verify_signing_identity(path, "codesign", "security")
    profile = profile_summary(raw_profile, verifier)
    signed_team = entitlements.get("com.apple.developer.team-identifier")
    signed_application = entitlements.get("application-identifier")
    expected_application = f"{expected_team_id}.{bundle_id}"
    if signed_team != expected_team_id:
        raise ValueError(f"signed team mismatch for {bundle_id}")
    if signed_application != expected_application:
        raise ValueError(f"signed application identifier mismatch for {bundle_id}")
    if expected_team_id not in (profile["team_identifiers"] or []):
        raise ValueError(f"profile team mismatch for {bundle_id}")
    profile_application = profile["application_identifier"]
    if not isinstance(profile_application, str) or not verifier.string_entitlement_authorized(
        profile_application, expected_application
    ):
        raise ValueError(f"profile application identifier mismatch for {bundle_id}")
    if identity["leaf_certificate_sha256"] not in profile[
        "developer_certificate_sha256"
    ]:
        raise ValueError(
            f"signing certificate is not authorized by profile for {bundle_id}"
        )
    authorized_entitlement_keys = verifier.verify_entitlement_authorization(
        entitlements,
        raw_profile,
        expected_team_id,
        bundle_id,
    )
    executable = verifier.executable_identity(path, "codesign", "dwarfdump")
    relative = "." if path == app_path else path.relative_to(app_path).as_posix()
    return {
        "bundle_id": bundle_id,
        "relative_path": relative,
        "bundle_version": info.get("CFBundleVersion"),
        "marketing_version": info.get("CFBundleShortVersionString"),
        "signing_authority": signing_authority(path),
        "signing_identity": identity,
        "signed_entitlements": entitlements,
        "signed_team_identifier": signed_team,
        "signed_application_identifier": signed_application,
        "signed_keychain_access_groups": entitlements.get(
            "keychain-access-groups", []
        ),
        "signed_get_task_allow": entitlements.get("get-task-allow", False),
        "signed_aps_environment": entitlements.get("aps-environment"),
        "profile": profile,
        "authorized_entitlement_keys": authorized_entitlement_keys,
        "executable": executable,
        "expected_team_matches": entitlements.get(
            "com.apple.developer.team-identifier"
        )
        == expected_team_id,
    }


def app_summary(
    app_path: pathlib.Path,
    expected_main_bundle_id: str,
    expected_team_id: str,
    verifier,
) -> dict[str, Any]:
    topology = verifier.expected_bundle_topology(expected_main_bundle_id)
    paths = verifier.signable_bundles(app_path)
    records = [
        bundle_summary(path, app_path, expected_team_id, verifier) for path in paths
    ]
    actual = {
        pathlib.PurePosixPath(record["relative_path"]): record["bundle_id"]
        for record in records
    }
    if actual != topology:
        raise ValueError(f"five-bundle topology mismatch: {actual!r}")
    return {
        "bundle_count": len(records),
        "bundles": sorted(records, key=lambda item: item["relative_path"]),
    }


def comparison(archive: dict[str, Any], ipa: dict[str, Any]) -> list[dict[str, Any]]:
    archive_by_id = {item["bundle_id"]: item for item in archive["bundles"]}
    ipa_by_id = {item["bundle_id"]: item for item in ipa["bundles"]}
    if archive_by_id.keys() != ipa_by_id.keys():
        raise ValueError("archive/IPA bundle identifiers differ")
    records = []
    for bundle_id in sorted(archive_by_id):
        before = archive_by_id[bundle_id]
        after = ipa_by_id[bundle_id]
        for key in ("bundle_version", "marketing_version"):
            if before[key] != after[key]:
                raise ValueError(
                    f"archive/IPA {key} mismatch for {bundle_id}: "
                    f"{before[key]!r} != {after[key]!r}"
                )
        records.append(
            {
                "bundle_id": bundle_id,
                "archive": {
                    "signing_authority": before["signing_authority"],
                    "profile_uuid": before["profile"]["uuid"],
                    "profile_name": before["profile"]["name"],
                    "profile_type": before["profile"]["type"],
                    "get_task_allow": before["signed_get_task_allow"],
                    "aps_environment": before["signed_aps_environment"],
                },
                "exported_ipa": {
                    "signing_authority": after["signing_authority"],
                    "profile_uuid": after["profile"]["uuid"],
                    "profile_name": after["profile"]["name"],
                    "profile_type": after["profile"]["type"],
                    "get_task_allow": after["signed_get_task_allow"],
                    "aps_environment": after["signed_aps_environment"],
                },
                "changed": {
                    "leaf_signing_authority": before["signing_authority"][
                        "leaf_common_name"
                    ]
                    != after["signing_authority"]["leaf_common_name"],
                    "profile_uuid": before["profile"]["uuid"]
                    != after["profile"]["uuid"],
                    "profile_type": before["profile"]["type"]
                    != after["profile"]["type"],
                    "get_task_allow": before["signed_get_task_allow"]
                    != after["signed_get_task_allow"],
                    "aps_environment": before["signed_aps_environment"]
                    != after["signed_aps_environment"],
                },
            }
        )
    return records


def main() -> None:
    args = parse_args()
    verifier_path = args.source_tools / "verify_aies_internal_signing.py"
    verifier = load_verifier(verifier_path)

    applications = args.archive / "Products" / "Applications"
    archive_app = applications / "OpenClaw.app"
    if sorted(applications.iterdir()) != [archive_app]:
        raise ValueError("archive must contain exactly OpenClaw.app")
    archive_metadata = verifier.verify_push_and_provenance(
        archive_app,
        args.expected_main_bundle_id,
        args.expected_git_sha,
        args.expected_archive_uuid,
    )
    archive = app_summary(
        archive_app, args.expected_main_bundle_id, args.expected_team_id, verifier
    )
    archive_dsym_binding = verifier.verify_archive_dsym_binding(
        args.archive,
        archive_app,
        "codesign",
        "dwarfdump",
        args.expected_main_bundle_id,
    )
    archive_info = verifier.read_plist(args.archive / "Info.plist")
    report: dict[str, Any] = {
        "schema": "aies.ios.export-signing-boundary.v1",
        "source_sha": args.expected_git_sha,
        "expected_team_id": args.expected_team_id,
        "expected_archive_uuid": args.expected_archive_uuid,
        "archive_application_properties": archive_info.get(
            "ApplicationProperties", {}
        ),
        "archive_metadata": archive_metadata,
        "archive": archive,
        "archive_dsym_binding": archive_dsym_binding,
        "ipa": None,
        "archive_to_ipa": None,
        "distribution_verification": None,
    }
    verification_errors: list[str] = []

    if args.ipa is not None:
        with tempfile.TemporaryDirectory() as raw_temp:
            ipa_app = verifier.safely_extract_ipa(
                args.ipa, pathlib.Path(raw_temp) / "ipa"
            )
            try:
                ipa = app_summary(
                    ipa_app,
                    args.expected_main_bundle_id,
                    args.expected_team_id,
                    verifier,
                )
                report["ipa"] = ipa
                report["archive_to_ipa"] = comparison(archive, ipa)
            except Exception as error:
                verification_errors.append(f"IPA observation: {error}")

            distribution = None
            try:
                distribution = verifier.verify_app(
                    ipa_app,
                    args.expected_main_bundle_id,
                    args.expected_team_id,
                    args.expected_git_sha,
                    args.expected_archive_uuid,
                    "codesign",
                    "security",
                )
            except Exception as error:
                verification_errors.append(f"distribution signing: {error}")

            binary_binding = None
            try:
                binary_binding = verifier.verify_binary_binding(
                    args.archive,
                    archive_app,
                    ipa_app,
                    "codesign",
                    "dwarfdump",
                    args.expected_main_bundle_id,
                )
            except Exception as error:
                verification_errors.append(f"binary/dSYM binding: {error}")

        report["distribution_verification"] = {
            "status": "verified" if not verification_errors else "failed",
            "verifier_result": distribution,
            "binary_binding": binary_binding,
            "errors": verification_errors,
        }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    if verification_errors:
        raise ValueError(
            "exported IPA verification failed; see the retained boundary report"
        )


if __name__ == "__main__":
    main()
