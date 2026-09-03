#!/usr/bin/env python3
"""Fail closed unless an archive used the governed reusable dev identity."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
from typing import Any


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")


class VerificationError(ValueError):
    """Raised when the archive does not use the governed identity."""


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise VerificationError(f"{label} must be an object")
    return value


def _text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise VerificationError(f"{label} must be a non-empty string")
    return value


def verify_report(
    report: object,
    *,
    expected_sha256: str,
    expected_team_id: str,
    expected_main_bundle_id: str,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    if not SHA256_RE.fullmatch(expected_sha256):
        raise VerificationError("expected certificate SHA-256 must be lowercase hex")
    if not TEAM_ID_RE.fullmatch(expected_team_id):
        raise VerificationError("expected Team ID is malformed")
    if not expected_main_bundle_id or not expected_main_bundle_id.startswith("ai."):
        raise VerificationError("expected main bundle ID is malformed")

    expected_paths = {
        expected_main_bundle_id: "OpenClaw.app",
        f"{expected_main_bundle_id}.share": (
            "OpenClaw.app/PlugIns/OpenClawShareExtension.appex"
        ),
        f"{expected_main_bundle_id}.activitywidget": (
            "OpenClaw.app/PlugIns/OpenClawActivityWidget.appex"
        ),
        f"{expected_main_bundle_id}.watchkitapp": (
            "OpenClaw.app/Watch/OpenClawWatchApp.app"
        ),
        f"{expected_main_bundle_id}.watchkitapp.extension": (
            "OpenClaw.app/Watch/OpenClawWatchApp.app/PlugIns/"
            "OpenClawWatchExtension.appex"
        ),
    }
    current_time = now or dt.datetime.now(dt.timezone.utc)
    if current_time.tzinfo is None:
        raise VerificationError("verification time must be timezone-aware")

    root = _mapping(report, "report")
    if root.get("status") != "archive_integrity_verified":
        raise VerificationError("archive integrity receipt is not successful")
    if root.get("expected_team_id") != expected_team_id:
        raise VerificationError("archive receipt Team ID does not match")

    archive = _mapping(root.get("archive"), "archive")
    if archive.get("verification_stage") != "archive_integrity":
        raise VerificationError("receipt is not an archive-integrity verification")
    bundles = archive.get("bundles")
    if not isinstance(bundles, list) or len(bundles) != 5:
        raise VerificationError("archive must contain exactly five bundle records")
    observed_bundle_ids = {
        item.get("bundle_id") for item in bundles if isinstance(item, dict)
    }
    if observed_bundle_ids != set(expected_paths):
        raise VerificationError("archive bundle topology does not match AIES")

    verified_bundle_ids: list[str] = []
    profiles: list[dict[str, str]] = []
    for index, raw_bundle in enumerate(bundles):
        bundle = _mapping(raw_bundle, f"bundle[{index}]")
        bundle_id = _text(bundle.get("bundle_id"), f"bundle[{index}].bundle_id")
        if bundle_id in verified_bundle_ids:
            raise VerificationError(f"duplicate bundle record: {bundle_id}")
        if bundle.get("relative_path") != expected_paths[bundle_id]:
            raise VerificationError(f"bundle containment mismatch: {bundle_id}")
        if bundle.get("team_identifier") != expected_team_id:
            raise VerificationError(f"bundle Team ID mismatch: {bundle_id}")
        expected_application_identifier = f"{expected_team_id}.{bundle_id}"
        if bundle.get("application_identifier") != expected_application_identifier:
            raise VerificationError(f"application identifier mismatch: {bundle_id}")
        if bundle.get("get_task_allow") is not True:
            raise VerificationError(f"archive get-task-allow mismatch: {bundle_id}")
        expected_aps = "development" if bundle_id == expected_main_bundle_id else None
        if bundle.get("aps_environment") != expected_aps:
            raise VerificationError(f"archive APS entitlement mismatch: {bundle_id}")

        signing = _mapping(
            bundle.get("signing_identity"), f"bundle[{index}].signing_identity"
        )
        if signing.get("leaf_certificate_sha256") != expected_sha256:
            raise VerificationError(
                f"bundle did not use governed development identity: {bundle_id}"
            )
        if signing.get("team_identifier") != expected_team_id:
            raise VerificationError(f"signing Team ID mismatch: {bundle_id}")
        common_name = _text(
            signing.get("leaf_common_name"),
            f"bundle[{index}].signing_identity.leaf_common_name",
        )
        if not common_name.startswith("Apple Development:"):
            raise VerificationError(f"bundle leaf is not Apple Development: {bundle_id}")
        if signing.get("trust_verified") is not True:
            raise VerificationError(f"bundle signing trust is not verified: {bundle_id}")

        profile = _mapping(bundle.get("profile"), f"bundle[{index}].profile")
        if profile.get("profile_type") != "development":
            raise VerificationError(f"bundle profile is not development: {bundle_id}")
        if profile.get("application_identifier") != expected_application_identifier:
            raise VerificationError(f"profile application identifier mismatch: {bundle_id}")
        if profile.get("get_task_allow") is not True:
            raise VerificationError(f"profile get-task-allow mismatch: {bundle_id}")
        if profile.get("aps_environment") != expected_aps:
            raise VerificationError(f"profile APS entitlement mismatch: {bundle_id}")
        if type(profile.get("provisioned_device_count")) is not int or profile[
            "provisioned_device_count"
        ] < 1:
            raise VerificationError(f"profile has no development device: {bundle_id}")
        if profile.get("provisions_all_devices") is not False:
            raise VerificationError(f"profile device scope is malformed: {bundle_id}")
        profile_certificates = profile.get("developer_certificate_sha256")
        if (
            not isinstance(profile_certificates, list)
            or expected_sha256 not in profile_certificates
        ):
            raise VerificationError(
                f"profile does not authorize governed development identity: {bundle_id}"
            )
        if profile.get("team_identifiers") != [expected_team_id]:
            raise VerificationError(f"profile Team ID mismatch: {bundle_id}")

        profile_uuid = _text(profile.get("uuid"), f"bundle[{index}].profile.uuid")
        profile_name = _text(profile.get("name"), f"bundle[{index}].profile.name")
        expiration_raw = _text(
            profile.get("expiration_at"), f"bundle[{index}].profile.expiration_at"
        )
        try:
            expiration = dt.datetime.fromisoformat(expiration_raw.replace("Z", "+00:00"))
        except ValueError as exc:
            raise VerificationError(
                f"profile expiration is malformed: {bundle_id}"
            ) from exc
        if expiration.tzinfo is None or expiration <= current_time:
            raise VerificationError(f"profile is expired: {bundle_id}")
        verified_bundle_ids.append(bundle_id)
        profiles.append(
            {
                "bundle_id": bundle_id,
                "profile_uuid": profile_uuid,
                "profile_name": profile_name,
                "profile_expiration_at": expiration.astimezone(
                    dt.timezone.utc
                ).isoformat().replace("+00:00", "Z"),
            }
        )

    auxiliaries = archive.get("auxiliary_code_objects")
    if not isinstance(auxiliaries, list) or len(auxiliaries) != 1:
        raise VerificationError("archive must contain the exact WebRTC auxiliary record")
    for index, raw_auxiliary in enumerate(auxiliaries):
        auxiliary = _mapping(raw_auxiliary, f"auxiliary[{index}]")
        if (
            auxiliary.get("bundle_id") != "org.webrtc.WebRTC"
            or auxiliary.get("kind") != "embedded_dynamic_framework"
            or auxiliary.get("executable_relative_path")
            != "Frameworks/WebRTC.framework/WebRTC"
            or auxiliary.get("profile") is not None
            or auxiliary.get("profile_requirement")
            != "not_applicable_embedded_framework"
        ):
            raise VerificationError("archive WebRTC auxiliary topology is malformed")
        signing = _mapping(
            auxiliary.get("signing_identity"),
            f"auxiliary[{index}].signing_identity",
        )
        if signing.get("leaf_certificate_sha256") != expected_sha256:
            raise VerificationError("auxiliary code object used another signing identity")
        if signing.get("team_identifier") != expected_team_id:
            raise VerificationError("auxiliary code object Team ID mismatch")

    return {
        "schema": "aies.apple-development-identity-reuse.v1",
        "status": "reusable_development_identity_verified",
        "certificate_sha256": expected_sha256,
        "team_id": expected_team_id,
        "bundle_count": len(verified_bundle_ids),
        "bundle_ids": sorted(verified_bundle_ids),
        "profiles": sorted(profiles, key=lambda item: item["bundle_id"]),
        "auxiliary_code_object_count": len(auxiliaries),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive-signing-report", required=True, type=pathlib.Path)
    parser.add_argument("--expected-certificate-sha256", required=True)
    parser.add_argument("--expected-team-id", required=True)
    parser.add_argument("--expected-main-bundle-id", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        report = json.loads(args.archive_signing_report.read_text(encoding="utf-8"))
        receipt = verify_report(
            report,
            expected_sha256=args.expected_certificate_sha256,
            expected_team_id=args.expected_team_id,
            expected_main_bundle_id=args.expected_main_bundle_id,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    except (OSError, json.JSONDecodeError, VerificationError) as exc:
        raise SystemExit(f"development identity reuse verification failed: {exc}") from exc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
