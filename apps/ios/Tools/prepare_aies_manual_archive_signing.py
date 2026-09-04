#!/usr/bin/env python3
"""Create the target-scoped manual-signing overlay for the AIES archive."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
from typing import Any


TEAM_ID = "J76B47MZ6V"
POLICY_SCHEMA = "aies.manual-archive-signing-policy.v1"
RECEIPT_SCHEMA = "aies.manual-archive-signing-overlay.v1"
PROFILE_IMPORT_SCHEMA = "aies.apple-development-profile-import.v1"
DEFAULT_POLICY_PATH = (
    pathlib.Path(__file__).resolve().parent.parent
    / "Config"
    / "AIESManualArchiveSigning.json"
)

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$")
RESOURCE_ID_RE = re.compile(r"^[A-Za-z0-9-]{1,128}$")
XCCONFIG_VARIABLE_RE = re.compile(r"^OPENCLAW_[A-Z0-9_]+$")
FORBIDDEN_BASE_ASSIGNMENT_RE = re.compile(
    r"^\s*(?:CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|"
    r"PROVISIONING_PROFILE|PROVISIONING_PROFILE_SPECIFIER)"
    r"(?:\[[^\]\r\n]+\])?\s*="
)
BASE_INCLUDE_RE = re.compile(r"^\s*#include\??(?:\s|\")")

EXPECTED_TARGETS = (
    {
        "logical_target": "main",
        "xcode_target": "OpenClaw",
        "bundle_id": "ai.openclaw.client.J76B47MZ6V",
        "xcconfig_variable": "OPENCLAW_APP_PROFILE",
        "profile_uuid": "a7ed39c2-45d7-44d5-ad05-9adc5d588d2c",
        "sdk": "iphoneos",
        "aps_environment": "development",
    },
    {
        "logical_target": "share",
        "xcode_target": "OpenClawShareExtension",
        "bundle_id": "ai.openclaw.client.J76B47MZ6V.share",
        "xcconfig_variable": "OPENCLAW_SHARE_PROFILE",
        "profile_uuid": "b8522792-eacb-4bae-b745-7e7e1cbbfabc",
        "sdk": "iphoneos",
        "aps_environment": None,
    },
    {
        "logical_target": "activity_widget",
        "xcode_target": "OpenClawActivityWidget",
        "bundle_id": "ai.openclaw.client.J76B47MZ6V.activitywidget",
        "xcconfig_variable": "OPENCLAW_ACTIVITY_WIDGET_PROFILE",
        "profile_uuid": "063a7a24-a4c0-4b03-88a5-c26cc3eda945",
        "sdk": "iphoneos",
        "aps_environment": None,
    },
    {
        "logical_target": "watch_app",
        "xcode_target": "OpenClawWatchApp",
        "bundle_id": "ai.openclaw.client.J76B47MZ6V.watchkitapp",
        "xcconfig_variable": "OPENCLAW_WATCH_APP_PROFILE",
        "profile_uuid": "080628be-6eec-4043-ac5c-fecef0b87226",
        "sdk": "watchos",
        "aps_environment": None,
    },
    {
        "logical_target": "watch_extension",
        "xcode_target": "OpenClawWatchExtension",
        "bundle_id": "ai.openclaw.client.J76B47MZ6V.watchkitapp.extension",
        "xcconfig_variable": "OPENCLAW_WATCH_EXTENSION_PROFILE",
        "profile_uuid": "11a8bc1a-a4b2-491b-ada2-d40d50d3ffbf",
        "sdk": "watchos",
        "aps_environment": None,
    },
)

POLICY_KEYS = {
    "schema",
    "team_id",
    "code_sign_style",
    "code_sign_identity",
    "profile_selection_build_setting",
    "archive_allows_provisioning_updates",
    "archive_receives_apple_authentication_arguments",
    "targets",
}
TARGET_KEYS = {
    "logical_target",
    "xcode_target",
    "bundle_id",
    "xcconfig_variable",
    "profile_uuid",
    "sdk",
    "aps_environment",
}
PROFILE_IMPORT_KEYS = {
    "schema",
    "status",
    "source_operation",
    "archive_allows_provisioning_updates",
    "archive_receives_apple_authentication_arguments",
    "spaceship_minimum_log_level",
    "spaceship_request_clients",
    "spaceship_response_body_logging_suppressed",
    "team_id",
    "certificate_sha256",
    "profile_count",
    "profiles",
}
IMPORTED_PROFILE_KEYS = {
    "apple_resource_id",
    "bundle_id",
    "target",
    "profile_uuid",
    "profile_name",
    "profile_expiration_at",
    "profile_type",
    "profile_state",
    "application_identifier",
    "get_task_allow",
    "aps_environment",
    "provisioned_device_count",
    "developer_certificate_sha256",
    "xcode_managed",
    "source_sha256",
    "bundle_resource_id",
}
EXPECTED_REQUEST_CLIENTS = [
    "provisioning_request_client",
    "test_flight_request_client",
    "tunes_request_client",
    "users_request_client",
]


class SigningPreparationError(ValueError):
    """Raised when manual archive signing cannot be prepared safely."""


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SigningPreparationError(f"{label} must be an object")
    return value


def _text(value: object, label: str, *, maximum: int = 512) -> str:
    if not isinstance(value, str) or not 1 <= len(value.encode("utf-8")) <= maximum:
        raise SigningPreparationError(f"{label} must be a bounded non-empty string")
    return value


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise SigningPreparationError(
            f"{label} fields are invalid (missing={missing}, extra={extra})"
        )


def _read_json(path: pathlib.Path, label: str) -> tuple[object, bytes]:
    resolved = _regular_file(path, label)
    raw = resolved.read_bytes()
    if not 2 <= len(raw) <= 2_000_000:
        raise SigningPreparationError(f"{label} size is invalid")
    try:
        return json.loads(raw), raw
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SigningPreparationError(f"{label} is not valid JSON") from exc


def _regular_file(path: pathlib.Path, label: str) -> pathlib.Path:
    if path.is_symlink():
        raise SigningPreparationError(f"{label} must not be a symlink")
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise SigningPreparationError(f"{label} does not exist") from exc
    if not resolved.is_file():
        raise SigningPreparationError(f"{label} must be a regular file")
    return resolved


def _directory(path: pathlib.Path, label: str) -> pathlib.Path:
    if path.is_symlink():
        raise SigningPreparationError(f"{label} must not be a symlink")
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise SigningPreparationError(f"{label} does not exist") from exc
    if not resolved.is_dir():
        raise SigningPreparationError(f"{label} must be a directory")
    return resolved


def _within(path: pathlib.Path, root: pathlib.Path, label: str) -> pathlib.Path:
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise SigningPreparationError(
            f"{label} must be inside the allowed output root"
        ) from exc
    return path


def _prepare_output_path(
    path: pathlib.Path, *, root: pathlib.Path, label: str
) -> pathlib.Path:
    requested = path if path.is_absolute() else root / path
    absolute = pathlib.Path(os.path.abspath(requested))
    if absolute.exists() or absolute.is_symlink():
        raise SigningPreparationError(f"{label} must not already exist")
    unresolved_parent = absolute.parent
    missing: list[pathlib.Path] = []
    cursor = unresolved_parent
    while not cursor.exists():
        if cursor == cursor.parent:
            raise SigningPreparationError(f"{label} parent cannot be resolved")
        missing.append(cursor)
        cursor = cursor.parent
    if cursor.is_symlink() or not cursor.is_dir():
        raise SigningPreparationError(f"{label} parent is unsafe")
    parent = cursor.resolve(strict=True)
    _within(parent, root, label)
    for directory in reversed(missing):
        parent = parent / directory.name
        parent.mkdir(mode=0o700)
        if parent.is_symlink() or not parent.is_dir():
            raise SigningPreparationError(f"{label} parent is unsafe")
    candidate = parent / absolute.name
    _within(candidate, root, label)
    return candidate


def load_policy(path: pathlib.Path = DEFAULT_POLICY_PATH) -> dict[str, Any]:
    raw_policy, _ = _read_json(path, "manual archive signing policy")
    policy = _mapping(raw_policy, "manual archive signing policy")
    _exact_keys(policy, POLICY_KEYS, "manual archive signing policy")
    if (
        policy.get("schema") != POLICY_SCHEMA
        or policy.get("team_id") != TEAM_ID
        or policy.get("code_sign_style") != "Manual"
        or policy.get("code_sign_identity") != "Apple Development"
        or policy.get("profile_selection_build_setting")
        != "PROVISIONING_PROFILE_SPECIFIER"
        or policy.get("archive_allows_provisioning_updates") is not False
        or policy.get("archive_receives_apple_authentication_arguments") is not False
    ):
        raise SigningPreparationError("manual archive signing policy is not authorized")
    raw_targets = policy.get("targets")
    if not isinstance(raw_targets, list) or len(raw_targets) != len(EXPECTED_TARGETS):
        raise SigningPreparationError(
            "manual archive signing policy must contain five targets"
        )
    targets: list[dict[str, Any]] = []
    for index, (raw_target, expected_target) in enumerate(
        zip(raw_targets, EXPECTED_TARGETS, strict=True)
    ):
        target = _mapping(raw_target, f"policy target[{index}]")
        _exact_keys(target, TARGET_KEYS, f"policy target[{index}]")
        if target != expected_target:
            raise SigningPreparationError(
                f"manual archive signing policy target[{index}] is not authorized"
            )
        if not XCCONFIG_VARIABLE_RE.fullmatch(target["xcconfig_variable"]):
            raise SigningPreparationError(
                f"policy target[{index}] variable is malformed"
            )
        targets.append(dict(target))
    if len({target["bundle_id"] for target in targets}) != len(targets):
        raise SigningPreparationError(
            "manual archive signing bundle IDs are not unique"
        )
    if len({target["profile_uuid"] for target in targets}) != len(targets):
        raise SigningPreparationError(
            "manual archive signing profile UUIDs are not unique"
        )
    return {**policy, "targets": targets}


def _parse_expiration(value: object, label: str) -> dt.datetime:
    raw = _text(value, label, maximum=64)
    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise SigningPreparationError(f"{label} is malformed") from exc
    if parsed.tzinfo is None:
        raise SigningPreparationError(f"{label} must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def validate_profile_import_receipt(
    value: object,
    *,
    policy: dict[str, Any],
    expected_certificate_sha256: str,
    now: dt.datetime | None = None,
) -> list[dict[str, Any]]:
    if not SHA256_RE.fullmatch(expected_certificate_sha256):
        raise SigningPreparationError(
            "expected certificate SHA-256 must be lowercase hexadecimal"
        )
    receipt = _mapping(value, "profile import receipt")
    _exact_keys(receipt, PROFILE_IMPORT_KEYS, "profile import receipt")
    if (
        receipt.get("schema") != PROFILE_IMPORT_SCHEMA
        or receipt.get("status")
        != "five_governed_profiles_installed_for_offline_archive"
        or receipt.get("source_operation") != "read_only_apple_profile_fetch"
        or receipt.get("archive_allows_provisioning_updates") is not False
        or receipt.get("archive_receives_apple_authentication_arguments") is not False
        or receipt.get("spaceship_minimum_log_level") != "WARN"
        or receipt.get("spaceship_request_clients") != EXPECTED_REQUEST_CLIENTS
        or receipt.get("spaceship_response_body_logging_suppressed") is not True
        or receipt.get("team_id") != policy["team_id"]
        or receipt.get("certificate_sha256") != expected_certificate_sha256
        or type(receipt.get("profile_count")) is not int
        or receipt.get("profile_count") != 5
    ):
        raise SigningPreparationError("profile import receipt custody is invalid")

    raw_profiles = receipt.get("profiles")
    if not isinstance(raw_profiles, list) or len(raw_profiles) != 5:
        raise SigningPreparationError(
            "profile import receipt must contain five profiles"
        )
    expected_by_bundle = {target["bundle_id"]: target for target in policy["targets"]}
    current_time = now or dt.datetime.now(dt.timezone.utc)
    if current_time.tzinfo is None:
        raise SigningPreparationError("verification time must include a timezone")
    current_time = current_time.astimezone(dt.timezone.utc)
    profiles_by_bundle: dict[str, dict[str, Any]] = {}
    seen_targets: set[str] = set()
    seen_uuids: set[str] = set()

    for index, raw_profile in enumerate(raw_profiles):
        profile = _mapping(raw_profile, f"profile[{index}]")
        _exact_keys(profile, IMPORTED_PROFILE_KEYS, f"profile[{index}]")
        bundle_id = _text(profile.get("bundle_id"), f"profile[{index}].bundle_id")
        expected = expected_by_bundle.get(bundle_id)
        if expected is None:
            raise SigningPreparationError(
                f"unexpected development profile: {bundle_id}"
            )
        logical_target = _text(profile.get("target"), f"profile[{index}].target")
        profile_uuid = _text(
            profile.get("profile_uuid"), f"profile[{index}].profile_uuid", maximum=36
        )
        if bundle_id in profiles_by_bundle:
            raise SigningPreparationError(f"duplicate development profile: {bundle_id}")
        if logical_target in seen_targets:
            raise SigningPreparationError(
                f"duplicate development target: {logical_target}"
            )
        if profile_uuid in seen_uuids:
            raise SigningPreparationError(
                f"duplicate development profile UUID: {profile_uuid}"
            )
        if (
            logical_target != expected["logical_target"]
            or not UUID_RE.fullmatch(profile_uuid)
            or profile_uuid != expected["profile_uuid"]
        ):
            raise SigningPreparationError(
                f"development profile mapping is invalid: {bundle_id}"
            )

        expiration = _parse_expiration(
            profile.get("profile_expiration_at"),
            f"profile[{index}].profile_expiration_at",
        )
        certificates = profile.get("developer_certificate_sha256")
        device_count = profile.get("provisioned_device_count")
        expected_application_identifier = f"{policy['team_id']}.{bundle_id}"
        if (
            profile.get("profile_type") != "IOS_APP_DEVELOPMENT"
            or profile.get("profile_state") != "ACTIVE"
            or profile.get("application_identifier")
            != expected_application_identifier
            or profile.get("get_task_allow") is not True
            or profile.get("aps_environment") != expected["aps_environment"]
            or type(device_count) is not int
            or not 1 <= device_count <= 1_000
            or profile.get("xcode_managed") is not False
            or not isinstance(certificates, list)
            or not 1 <= len(certificates) <= 50
            or certificates != sorted(set(certificates))
            or not all(
                isinstance(fingerprint, str) and SHA256_RE.fullmatch(fingerprint)
                for fingerprint in certificates
            )
            or expected_certificate_sha256 not in certificates
            or expiration <= current_time
        ):
            raise SigningPreparationError(
                f"development profile semantics are invalid: {bundle_id}"
            )
        source_sha256 = _text(
            profile.get("source_sha256"), f"profile[{index}].source_sha256", maximum=64
        )
        if not SHA256_RE.fullmatch(source_sha256):
            raise SigningPreparationError(
                f"development profile source hash is invalid: {bundle_id}"
            )
        for key in ("apple_resource_id", "bundle_resource_id"):
            resource_id = _text(
                profile.get(key), f"profile[{index}].{key}", maximum=128
            )
            if not RESOURCE_ID_RE.fullmatch(resource_id):
                raise SigningPreparationError(
                    f"development profile resource identity is invalid: {bundle_id}"
                )
        _text(
            profile.get("profile_name"),
            f"profile[{index}].profile_name",
            maximum=256,
        )
        profiles_by_bundle[bundle_id] = profile
        seen_targets.add(logical_target)
        seen_uuids.add(profile_uuid)

    if set(profiles_by_bundle) != set(expected_by_bundle):
        raise SigningPreparationError("development profile coverage is incomplete")
    return [profiles_by_bundle[target["bundle_id"]] for target in policy["targets"]]


def _overlay_bytes(policy: dict[str, Any], include_path: str) -> bytes:
    if not include_path or any(
        character in include_path for character in ('"', "\r", "\n")
    ):
        raise SigningPreparationError("base xcconfig include path is unsafe")
    lines = [
        f'#include "{include_path}"',
        f"OPENCLAW_CODE_SIGN_STYLE = {policy['code_sign_style']}",
        f"OPENCLAW_DEVELOPMENT_TEAM = {policy['team_id']}",
    ]
    lines.extend(
        f"{target['xcconfig_variable']} = {target['profile_uuid']}"
        for target in policy["targets"]
    )
    return ("\n".join(lines) + "\n").encode("utf-8")


def _validate_base_xcconfig(raw: bytes) -> None:
    if not 1 <= len(raw) <= 131_072 or b"\0" in raw:
        raise SigningPreparationError("base xcconfig size or encoding is invalid")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise SigningPreparationError("base xcconfig is not UTF-8") from exc
    for line in lines:
        if BASE_INCLUDE_RE.match(line):
            raise SigningPreparationError(
                "base xcconfig must not introduce another include"
            )
        if FORBIDDEN_BASE_ASSIGNMENT_RE.match(line):
            raise SigningPreparationError(
                "base xcconfig contains a global signing or profile assignment"
            )


def _atomic_write(path: pathlib.Path, payload: bytes) -> None:
    temporary = path.with_name(f".{path.name}.aies-tmp")
    if temporary.exists() or temporary.is_symlink():
        raise SigningPreparationError(
            f"temporary output already exists: {temporary.name}"
        )
    try:
        with temporary.open("xb") as handle:
            os.chmod(temporary, 0o600)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists() or temporary.is_symlink():
            temporary.unlink()


def prepare_manual_archive_signing(
    *,
    policy_path: pathlib.Path,
    profile_import_receipt_path: pathlib.Path,
    base_xcconfig_path: pathlib.Path,
    output_xcconfig_path: pathlib.Path,
    output_receipt_path: pathlib.Path,
    allowed_output_root: pathlib.Path,
    expected_certificate_sha256: str,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    policy = load_policy(policy_path)
    policy_resolved = _regular_file(policy_path, "manual archive signing policy")
    allowed_root = _directory(allowed_output_root, "allowed output root")
    base_xcconfig = _regular_file(base_xcconfig_path, "base xcconfig")
    profile_receipt_path = _regular_file(
        profile_import_receipt_path, "profile import receipt"
    )
    output_xcconfig = _prepare_output_path(
        output_xcconfig_path, root=allowed_root, label="output xcconfig"
    )
    output_receipt = _prepare_output_path(
        output_receipt_path, root=allowed_root, label="output receipt"
    )
    if output_xcconfig == output_receipt:
        raise SigningPreparationError("output xcconfig and receipt must be distinct")

    raw_receipt, profile_receipt_bytes = _read_json(
        profile_receipt_path, "profile import receipt"
    )
    profiles = validate_profile_import_receipt(
        raw_receipt,
        policy=policy,
        expected_certificate_sha256=expected_certificate_sha256,
        now=now,
    )
    include_path = os.path.relpath(
        base_xcconfig, start=output_xcconfig.parent
    ).replace(os.sep, "/")
    overlay = _overlay_bytes(policy, include_path)
    policy_bytes = policy_resolved.read_bytes()
    base_bytes = base_xcconfig.read_bytes()
    _validate_base_xcconfig(base_bytes)

    targets = []
    for target, profile in zip(policy["targets"], profiles, strict=True):
        targets.append(
            {
                "aps_environment": target["aps_environment"],
                "bundle_id": target["bundle_id"],
                "logical_target": target["logical_target"],
                "profile_expiration_at": profile["profile_expiration_at"],
                "profile_source_sha256": profile["source_sha256"],
                "profile_uuid": target["profile_uuid"],
                "sdk": target["sdk"],
                "xcconfig_variable": target["xcconfig_variable"],
                "xcode_target": target["xcode_target"],
            }
        )
    receipt = {
        "archive_allows_provisioning_updates": False,
        "archive_receives_apple_authentication_arguments": False,
        "base_xcconfig_sha256": hashlib.sha256(base_bytes).hexdigest(),
        "base_xcconfig_global_signing_overrides_absent": True,
        "certificate_sha256": expected_certificate_sha256,
        "code_sign_identity": policy["code_sign_identity"],
        "code_sign_style": policy["code_sign_style"],
        "export_signing_unchanged": True,
        "global_profile_override": False,
        "only_namespaced_archive_overrides": True,
        "overlay_sha256": hashlib.sha256(overlay).hexdigest(),
        "policy_sha256": hashlib.sha256(policy_bytes).hexdigest(),
        "profile_bijection_verified": True,
        "profile_count": len(targets),
        "profile_import_receipt_sha256": hashlib.sha256(
            profile_receipt_bytes
        ).hexdigest(),
        "profile_selection_build_setting": policy[
            "profile_selection_build_setting"
        ],
        "schema": RECEIPT_SCHEMA,
        "status": "manual_archive_signing_overlay_verified",
        "targets": targets,
        "team_id": policy["team_id"],
    }
    receipt_bytes = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode(
        "utf-8"
    )
    try:
        _atomic_write(output_xcconfig, overlay)
        _atomic_write(output_receipt, receipt_bytes)
    except Exception:
        for output in (output_receipt, output_xcconfig):
            if output.exists() and output.is_file() and not output.is_symlink():
                output.unlink()
        raise
    return receipt


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", type=pathlib.Path, default=DEFAULT_POLICY_PATH)
    parser.add_argument("--profile-import-receipt", required=True, type=pathlib.Path)
    parser.add_argument("--base-xcconfig", required=True, type=pathlib.Path)
    parser.add_argument("--output-xcconfig", required=True, type=pathlib.Path)
    parser.add_argument("--output-receipt", required=True, type=pathlib.Path)
    parser.add_argument("--allowed-output-root", required=True, type=pathlib.Path)
    parser.add_argument("--expected-certificate-sha256", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        prepare_manual_archive_signing(
            policy_path=args.policy,
            profile_import_receipt_path=args.profile_import_receipt,
            base_xcconfig_path=args.base_xcconfig,
            output_xcconfig_path=args.output_xcconfig,
            output_receipt_path=args.output_receipt,
            allowed_output_root=args.allowed_output_root,
            expected_certificate_sha256=args.expected_certificate_sha256,
        )
    except (OSError, SigningPreparationError) as exc:
        raise SystemExit(f"manual archive signing preparation failed: {exc}") from exc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
