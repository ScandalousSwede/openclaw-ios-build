#!/usr/bin/env python3
"""Fail-closed verification of the AIES archive signing build settings."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import sys
from typing import Any


SCHEMA = "argus.openclaw-ios.archive-signing-build-settings.v1"
FINGERPRINT_PATTERN = re.compile(r"[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64}")
RESOURCE_TARGETS = {
    "GRDB_GRDB",
    "OpenClawKit_OpenClawKit",
    "swiftui-math_SwiftUIMath",
    "textual_Textual",
}
ARCHIVE_RESOURCE_BUNDLES = {
    pathlib.PurePosixPath("GRDB_GRDB.bundle"),
    pathlib.PurePosixPath("OpenClawKit_OpenClawKit.bundle"),
    pathlib.PurePosixPath(
        "PlugIns/OpenClawShareExtension.appex/OpenClawKit_OpenClawKit.bundle"
    ),
    pathlib.PurePosixPath("swiftui-math_SwiftUIMath.bundle"),
    pathlib.PurePosixPath("swiftui-math_SwiftUIMath.bundle/mathFonts.bundle"),
    pathlib.PurePosixPath("textual_Textual.bundle"),
}
MACHO_MAGICS = {
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}


def expected_product_targets(main_bundle_id: str) -> dict[str, str]:
    return {
        "OpenClaw": main_bundle_id,
        "OpenClawShareExtension": f"{main_bundle_id}.share",
        "OpenClawActivityWidget": f"{main_bundle_id}.activitywidget",
        "OpenClawWatchApp": f"{main_bundle_id}.watchkitapp",
        "OpenClawWatchExtension": f"{main_bundle_id}.watchkitapp.extension",
    }


def _canonical_settings_hash(settings: dict[str, Any]) -> str:
    encoded = json.dumps(
        settings,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _setting(settings: dict[str, Any], name: str) -> str:
    value = settings.get(name, "")
    if value is None:
        return ""
    if not isinstance(value, (str, int, float, bool)):
        raise ValueError(f"build setting {name} must be scalar")
    return str(value)


def _require_empty(settings: dict[str, Any], target: str, names: tuple[str, ...]) -> None:
    for name in names:
        value = _setting(settings, name)
        if value:
            raise ValueError(f"{target} must not set {name}: actual={value!r}")


def _require_no_fingerprint_identity(settings: dict[str, Any], target: str) -> None:
    identity = _setting(settings, "CODE_SIGN_IDENTITY")
    if FINGERPRINT_PATTERN.fullmatch(identity):
        raise ValueError(
            f"{target} CODE_SIGN_IDENTITY must be a certificate class, not a fingerprint"
        )


def _product_record(
    target: str,
    settings: dict[str, Any],
    expected_bundle_id: str,
    expected_team_id: str,
) -> dict[str, Any]:
    _require_no_fingerprint_identity(settings, target)
    expected = {
        "PRODUCT_BUNDLE_IDENTIFIER": expected_bundle_id,
        "CODE_SIGNING_ALLOWED": "YES",
        "CODE_SIGNING_REQUIRED": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": expected_team_id,
        "CODE_SIGN_IDENTITY": "Apple Development",
    }
    for name, expected_value in expected.items():
        actual = _setting(settings, name)
        if actual != expected_value:
            raise ValueError(
                f"{target} {name} mismatch: expected={expected_value!r} actual={actual!r}"
            )
    _require_empty(
        settings,
        target,
        ("PROVISIONING_PROFILE", "PROVISIONING_PROFILE_SPECIFIER"),
    )
    product_type = _setting(settings, "PRODUCT_TYPE")
    if product_type == "com.apple.product-type.bundle" or not product_type:
        raise ValueError(f"{target} has invalid executable product type: {product_type!r}")
    return {
        "target": target,
        "classification": "signed_application_product",
        "bundle_id": expected_bundle_id,
        "product_type": product_type,
        "signing": {
            name: _setting(settings, name)
            for name in (
                "CODE_SIGNING_ALLOWED",
                "CODE_SIGNING_REQUIRED",
                "CODE_SIGN_STYLE",
                "DEVELOPMENT_TEAM",
                "CODE_SIGN_IDENTITY",
                "PROVISIONING_PROFILE",
                "PROVISIONING_PROFILE_SPECIFIER",
            )
        },
        "full_build_settings_sha256": _canonical_settings_hash(settings),
    }


def _resource_record(
    target: str, settings: dict[str, Any], expected_team_id: str
) -> dict[str, Any]:
    expected = {
        "PRODUCT_TYPE": "com.apple.product-type.bundle",
        "WRAPPER_EXTENSION": "bundle",
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGNING_REQUIRED": "NO",
    }
    for name, expected_value in expected.items():
        actual = _setting(settings, name)
        if actual != expected_value:
            raise ValueError(
                f"{target} {name} mismatch: expected={expected_value!r} actual={actual!r}"
            )
    _require_no_fingerprint_identity(settings, target)
    _require_empty(settings, target, ("PROVISIONING_PROFILE", "PROVISIONING_PROFILE_SPECIFIER"))
    allowed_inherited = {
        "CODE_SIGN_STYLE": {"", "Automatic"},
        "DEVELOPMENT_TEAM": {"", expected_team_id},
        "CODE_SIGN_IDENTITY": {"", "Apple Development"},
    }
    for name, allowed in allowed_inherited.items():
        actual = _setting(settings, name)
        if actual not in allowed:
            raise ValueError(
                f"{target} {name} is incompatible with its codeless disposition: "
                f"actual={actual!r}"
            )
    return {
        "target": target,
        "classification": "package_resource_bundle_target_signing_disabled",
        "product_type": _setting(settings, "PRODUCT_TYPE"),
        "wrapper_extension": _setting(settings, "WRAPPER_EXTENSION"),
        "signing": {
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "manual_profile_override": False,
        },
        "observed_nonoperative_settings": {
            name: _setting(settings, name)
            for name in (
                "CODE_SIGN_STYLE",
                "DEVELOPMENT_TEAM",
                "CODE_SIGN_IDENTITY",
                "EXECUTABLE_NAME",
                "EXECUTABLE_PATH",
                "MACH_O_TYPE",
            )
        },
        "full_build_settings_sha256": _canonical_settings_hash(settings),
    }


def verify_archive_resource_bundles(archive: pathlib.Path) -> dict[str, Any]:
    """Prove the packaged SwiftPM resources contain neither code nor signatures."""

    archive = archive.resolve()
    app = archive / "Products" / "Applications" / "OpenClaw.app"
    if not app.is_dir() or app.is_symlink():
        raise ValueError("archive does not contain a regular OpenClaw.app")
    actual = {
        pathlib.PurePosixPath(path.relative_to(app).as_posix())
        for path in app.rglob("*.bundle")
        if path.is_dir()
    }
    if actual != ARCHIVE_RESOURCE_BUNDLES:
        raise ValueError(
            "archive resource-bundle topology mismatch: "
            f"expected={sorted(map(str, ARCHIVE_RESOURCE_BUNDLES))!r} "
            f"actual={sorted(map(str, actual))!r}"
        )

    records: list[dict[str, Any]] = []
    for relative in sorted(actual, key=str):
        bundle = app.joinpath(*relative.parts)
        if bundle.is_symlink():
            raise ValueError(f"archive resource bundle is a symlink: {relative}")
        signature = bundle / "_CodeSignature"
        if signature.exists() or signature.is_symlink():
            raise ValueError(f"archive resource bundle is unexpectedly signed: {relative}")
        info_path = bundle / "Info.plist"
        info: dict[str, Any] = {}
        if info_path.exists():
            if not info_path.is_file() or info_path.is_symlink():
                raise ValueError(f"resource Info.plist is not a regular file: {relative}")
            with info_path.open("rb") as handle:
                decoded = plistlib.load(handle)
            if not isinstance(decoded, dict):
                raise ValueError(f"resource Info.plist is not a dictionary: {relative}")
            info = decoded
        executable = info.get("CFBundleExecutable")
        if executable not in (None, ""):
            raise ValueError(
                f"archive resource bundle declares CFBundleExecutable: {relative}"
            )
        regular_file_count = 0
        for path in bundle.rglob("*"):
            if path.is_symlink():
                raise ValueError(f"resource bundle contains a symlink: {relative}")
            if not path.is_file():
                continue
            regular_file_count += 1
            with path.open("rb") as handle:
                if handle.read(4) in MACHO_MAGICS:
                    raise ValueError(
                        f"archive resource bundle contains a Mach-O file: {relative}"
                    )
        records.append(
            {
                "relative_path": str(relative),
                "info_plist_present": info_path.is_file(),
                "cf_bundle_executable": None,
                "code_signature_present": False,
                "mach_o_present": False,
                "regular_file_count": regular_file_count,
            }
        )
    return {
        "status": "verified_codeless_and_unsigned",
        "resource_bundle_count": len(records),
        "resource_bundles": records,
    }


def build_report(
    payloads: list[Any], expected_main_bundle_id: str, expected_team_id: str
) -> dict[str, Any]:
    if not re.fullmatch(r"[A-Z0-9]{10}", expected_team_id):
        raise ValueError("expected Team ID must contain ten uppercase letters or digits")
    products = expected_product_targets(expected_main_bundle_id)
    if len(payloads) < 2:
        raise ValueError(
            "archive-action and archive-index build-settings inputs are both required"
        )
    expected_targets = set(products) | RESOURCE_TARGETS
    occurrences: dict[str, list[dict[str, Any]]] = {
        target: [] for target in expected_targets
    }
    unexpected_resource_targets: set[str] = set()

    for input_index, payload in enumerate(payloads):
        if not isinstance(payload, list):
            raise ValueError(f"build-settings input {input_index} must be an array")
        for source_index, item in enumerate(payload):
            if not isinstance(item, dict):
                raise ValueError(
                    f"build-settings input {input_index} entry {source_index} must be an object"
                )
            target = item.get("target")
            settings = item.get("buildSettings")
            if not isinstance(target, str) or not isinstance(settings, dict):
                continue
            if (
                input_index > 0
                and
                _setting(settings, "PRODUCT_TYPE") == "com.apple.product-type.bundle"
                and target not in RESOURCE_TARGETS
            ):
                unexpected_resource_targets.add(target)
            if target not in expected_targets:
                continue
            if target in products:
                if input_index != 0:
                    continue
                record = _product_record(
                    target,
                    settings,
                    products[target],
                    expected_team_id,
                )
                record["settings_context"] = "archive_action"
            else:
                if input_index == 0:
                    continue
                record = _resource_record(target, settings, expected_team_id)
                record["settings_context"] = "archive_index"
            record["input_index"] = input_index
            record["source_index"] = source_index
            occurrences[target].append(record)

    archive_action_missing_products = sorted(
        target for target in products if not occurrences[target]
    )
    if archive_action_missing_products:
        raise ValueError(
            "archive-action build-settings input omitted product targets: "
            f"{archive_action_missing_products!r}"
        )
    archive_index_missing_resources = sorted(
        target for target in RESOURCE_TARGETS if not occurrences[target]
    )
    if archive_index_missing_resources:
        raise ValueError(
            "archive-index build-settings input omitted resource targets: "
            f"{archive_index_missing_resources!r}"
        )
    if unexpected_resource_targets:
        raise ValueError(
            "unexpected package resource-bundle targets: "
            f"{sorted(unexpected_resource_targets)!r}"
        )

    target_records = []
    for target in sorted(expected_targets):
        records = occurrences[target]
        canonical = {
            key: value
            for key, value in records[0].items()
            if key
            not in {
                "input_index",
                "source_index",
                "full_build_settings_sha256",
                "observed_nonoperative_settings",
            }
        }
        for record in records[1:]:
            comparison = {
                key: value
                for key, value in record.items()
                if key
                not in {
                    "input_index",
                    "source_index",
                    "full_build_settings_sha256",
                    "observed_nonoperative_settings",
                }
            }
            if comparison != canonical:
                raise ValueError(f"conflicting archive settings for target {target}")
        target_records.append(
            {
                **canonical,
                "occurrence_count": len(records),
                "occurrences": [
                    {
                        "input_index": record["input_index"],
                        "settings_context": record["settings_context"],
                        "source_index": record["source_index"],
                        "full_build_settings_sha256": record[
                            "full_build_settings_sha256"
                        ],
                        **(
                            {
                                "observed_nonoperative_settings": record[
                                    "observed_nonoperative_settings"
                                ]
                            }
                            if "observed_nonoperative_settings" in record
                            else {}
                        ),
                    }
                    for record in records
                ],
            }
        )

    return {
        "schema": SCHEMA,
        "status": "verified",
        "expected_main_bundle_id": expected_main_bundle_id,
        "expected_team_id": expected_team_id,
        "target_count": len(target_records),
        "signed_product_target_count": len(products),
        "archive_action_product_target_count": len(products),
        "unsigned_resource_target_count": len(RESOURCE_TARGETS),
        "resource_settings_context": "archive_index_plus_archive_artifact",
        "manual_archive_identity_override": False,
        "manual_archive_profile_override": False,
        "targets": target_records,
    }


def diagnostic_summary(payloads: list[Any]) -> list[dict[str, str]]:
    """Return only non-secret target/signing fields for a failed CI probe."""

    allowed = (
        "PRODUCT_BUNDLE_IDENTIFIER",
        "PRODUCT_TYPE",
        "WRAPPER_EXTENSION",
        "CODE_SIGNING_ALLOWED",
        "CODE_SIGNING_REQUIRED",
        "CODE_SIGN_STYLE",
        "DEVELOPMENT_TEAM",
        "CODE_SIGN_IDENTITY",
        "PROVISIONING_PROFILE",
        "PROVISIONING_PROFILE_SPECIFIER",
        "EXECUTABLE_NAME",
        "EXECUTABLE_PATH",
        "MACH_O_TYPE",
    )
    expected_targets = set(expected_product_targets("")) | RESOURCE_TARGETS
    records = []
    for payload in payloads:
        if not isinstance(payload, list):
            continue
        for item in payload:
            if not isinstance(item, dict) or not isinstance(item.get("target"), str):
                continue
            settings = item.get("buildSettings")
            if not isinstance(settings, dict) or item["target"] not in expected_targets:
                continue
            records.append(
                {
                    "target": item["target"],
                    **{name: _setting(settings, name) for name in allowed},
                }
            )
    return sorted(records, key=lambda record: tuple(record.values()))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", action="append", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--expected-main-bundle-id", required=True)
    parser.add_argument("--expected-team-id", required=True)
    parser.add_argument("--archive", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.output.unlink(missing_ok=True)
    payloads = [
        json.loads(path.read_text(encoding="utf-8")) for path in args.input
    ]
    try:
        report = build_report(
            payloads,
            args.expected_main_bundle_id,
            args.expected_team_id,
        )
        if args.archive is not None:
            report["archive_resource_bundle_verification"] = (
                verify_archive_resource_bundles(args.archive)
            )
    except ValueError:
        print(
            json.dumps(diagnostic_summary(payloads), indent=2, sort_keys=True),
            file=sys.stderr,
        )
        raise
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
