#!/usr/bin/env python3
"""Fail-closed verification of AIES archive signing dispositions."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import sys
from typing import Any


SCHEMA = "argus.openclaw-ios.archive-signing-build-settings.v2"
FINGERPRINT_PATTERN = re.compile(r"[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64}")
PRODUCT_TARGET_SPECS = {
    "OpenClaw": {
        "suffix": "",
        "product_type": "com.apple.product-type.application",
        "wrapper_extension": "app",
        "platform_name": "iphoneos",
    },
    "OpenClawShareExtension": {
        "suffix": ".share",
        "product_type": "com.apple.product-type.app-extension",
        "wrapper_extension": "appex",
        "platform_name": "iphoneos",
    },
    "OpenClawActivityWidget": {
        "suffix": ".activitywidget",
        "product_type": "com.apple.product-type.app-extension",
        "wrapper_extension": "appex",
        "platform_name": "iphoneos",
    },
    "OpenClawWatchApp": {
        "suffix": ".watchkitapp",
        "product_type": "com.apple.product-type.application.watchapp2",
        "wrapper_extension": "app",
        "platform_name": "watchos",
    },
    "OpenClawWatchExtension": {
        "suffix": ".watchkitapp.extension",
        "product_type": "com.apple.product-type.watchkit2-extension",
        "wrapper_extension": "appex",
        "platform_name": "watchos",
    },
}
RESOURCE_TARGET_BUNDLES = {
    "GRDB_GRDB": (pathlib.PurePosixPath("GRDB_GRDB.bundle"),),
    "OpenClawKit_OpenClawKit": (
        pathlib.PurePosixPath("OpenClawKit_OpenClawKit.bundle"),
        pathlib.PurePosixPath(
            "PlugIns/OpenClawShareExtension.appex/OpenClawKit_OpenClawKit.bundle"
        ),
    ),
    "swiftui-math_SwiftUIMath": (
        pathlib.PurePosixPath("swiftui-math_SwiftUIMath.bundle"),
        pathlib.PurePosixPath(
            "swiftui-math_SwiftUIMath.bundle/mathFonts.bundle"
        ),
    ),
    "textual_Textual": (pathlib.PurePosixPath("textual_Textual.bundle"),),
}
RESOURCE_TARGETS = frozenset(RESOURCE_TARGET_BUNDLES)
ARCHIVE_RESOURCE_BUNDLES = frozenset(
    path
    for paths in RESOURCE_TARGET_BUNDLES.values()
    for path in paths
)
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
        target: f"{main_bundle_id}{spec['suffix']}"
        for target, spec in PRODUCT_TARGET_SPECS.items()
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
    spec = PRODUCT_TARGET_SPECS[target]
    _require_no_fingerprint_identity(settings, target)
    expected = {
        "ACTION": "archive",
        "CONFIGURATION": "Release",
        "PRODUCT_BUNDLE_IDENTIFIER": expected_bundle_id,
        "PRODUCT_TYPE": spec["product_type"],
        "WRAPPER_EXTENSION": spec["wrapper_extension"],
        "PLATFORM_NAME": spec["platform_name"],
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
    return {
        "target": target,
        "classification": "signed_application_product",
        "bundle_id": expected_bundle_id,
        "configuration": "Release",
        "action": "archive",
        "platform_name": spec["platform_name"],
        "product_type": spec["product_type"],
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
        "settings_context": "explicit_target_release_archive_action",
        "full_build_settings_sha256": _canonical_settings_hash(settings),
    }


def _product_records(
    payloads: dict[str, Any],
    expected_main_bundle_id: str,
    expected_team_id: str,
) -> list[dict[str, Any]]:
    expected = expected_product_targets(expected_main_bundle_id)
    if set(payloads) != set(expected):
        missing = sorted(set(expected) - set(payloads))
        extra = sorted(set(payloads) - set(expected))
        raise ValueError(
            f"product settings inputs mismatch: missing={missing!r} extra={extra!r}"
        )
    records = []
    for target in PRODUCT_TARGET_SPECS:
        payload = payloads[target]
        if isinstance(payload, dict):
            raise ValueError(
                f"{target} settings input is an object; "
                "showBuildSettingsForIndex metadata is not build-settings evidence"
            )
        if not isinstance(payload, list) or len(payload) != 1:
            raise ValueError(
                f"{target} settings input must contain exactly one target record"
            )
        item = payload[0]
        if not isinstance(item, dict):
            raise ValueError(f"{target} settings record must be an object")
        observed_target = item.get("target")
        settings = item.get("buildSettings")
        if observed_target != target or not isinstance(settings, dict):
            raise ValueError(
                f"{target} settings input is not role-bound to the expected target"
            )
        records.append(
            _product_record(target, settings, expected[target], expected_team_id)
        )
    return records


def verify_archive_resource_bundles(archive: pathlib.Path) -> dict[str, Any]:
    """Prove the exact synthesized SwiftPM resources contain no signable code."""

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

    bundle_records: dict[pathlib.PurePosixPath, dict[str, Any]] = {}
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
        bundle_records[relative] = {
            "relative_path": str(relative),
            "info_plist_present": info_path.is_file(),
            "cf_bundle_executable": None,
            "code_signature_present": False,
            "mach_o_present": False,
            "symlink_present": False,
            "regular_file_count": regular_file_count,
        }

    logical_targets = []
    for target, paths in RESOURCE_TARGET_BUNDLES.items():
        logical_targets.append(
            {
                "target": target,
                "classification": (
                    "codeless_package_resource_bundle_signing_not_applicable"
                ),
                "swiftpm_product_type": "bundle",
                "package_resource_target_kind": "resource",
                "explicit_code_signing_setting_claimed": False,
                "archive_bundle_instances": [bundle_records[path] for path in paths],
            }
        )
    return {
        "status": "verified_codeless_signing_not_applicable",
        "logical_resource_target_count": len(logical_targets),
        "resource_bundle_instance_count": len(bundle_records),
        "logical_targets": logical_targets,
    }


def build_report(
    payloads: dict[str, Any],
    expected_main_bundle_id: str,
    expected_team_id: str,
    archive: pathlib.Path | None = None,
) -> dict[str, Any]:
    if not re.fullmatch(r"[A-Z0-9]{10}", expected_team_id):
        raise ValueError("expected Team ID must contain ten uppercase letters or digits")
    products = _product_records(
        payloads, expected_main_bundle_id, expected_team_id
    )
    resource_verification: dict[str, Any] = {
        "status": "deferred_until_archive_artifact",
        "logical_resource_target_count": len(RESOURCE_TARGETS),
        "resource_bundle_instance_count": len(ARCHIVE_RESOURCE_BUNDLES),
    }
    resources: list[dict[str, Any]] = []
    status = "product_settings_verified_resource_artifact_deferred"
    if archive is not None:
        resource_verification = verify_archive_resource_bundles(archive)
        resources = resource_verification["logical_targets"]
        status = "verified"
    targets = [*products, *resources]
    return {
        "schema": SCHEMA,
        "status": status,
        "expected_main_bundle_id": expected_main_bundle_id,
        "expected_team_id": expected_team_id,
        "target_count": len(targets),
        "expected_logical_target_count": len(PRODUCT_TARGET_SPECS) + len(RESOURCE_TARGETS),
        "signed_product_target_count": len(products),
        "codeless_resource_target_count": len(RESOURCE_TARGETS),
        "resource_bundle_instance_count": len(ARCHIVE_RESOURCE_BUNDLES),
        "resource_signing_settings_claimed": False,
        "resource_disposition_basis": (
            "swiftpm_synthesized_codeless_bundle_plus_archive_artifact"
        ),
        "manual_archive_identity_override": False,
        "manual_archive_profile_override": False,
        "targets": targets,
        "archive_resource_bundle_verification": resource_verification,
    }


def diagnostic_summary(payloads: dict[str, Any]) -> list[dict[str, Any]]:
    """Return only non-secret target/signing fields for a failed CI probe."""

    allowed = (
        "ACTION",
        "CONFIGURATION",
        "PRODUCT_BUNDLE_IDENTIFIER",
        "PRODUCT_TYPE",
        "WRAPPER_EXTENSION",
        "PLATFORM_NAME",
        "CODE_SIGNING_ALLOWED",
        "CODE_SIGNING_REQUIRED",
        "CODE_SIGN_STYLE",
        "DEVELOPMENT_TEAM",
        "CODE_SIGN_IDENTITY",
        "PROVISIONING_PROFILE",
        "PROVISIONING_PROFILE_SPECIFIER",
    )
    records: list[dict[str, Any]] = []
    for requested_target, payload in sorted(payloads.items()):
        if not isinstance(payload, list):
            records.append(
                {
                    "requested_target": requested_target,
                    "payload_type": type(payload).__name__,
                    "accepted_as_build_settings": False,
                }
            )
            continue
        for item in payload:
            if not isinstance(item, dict):
                continue
            settings = item.get("buildSettings")
            if not isinstance(settings, dict):
                continue
            records.append(
                {
                    "requested_target": requested_target,
                    "observed_target": item.get("target"),
                    **{name: _setting(settings, name) for name in allowed},
                }
            )
    return records


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--product-settings",
        action="append",
        required=True,
        metavar="TARGET=PATH",
    )
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--expected-main-bundle-id", required=True)
    parser.add_argument("--expected-team-id", required=True)
    parser.add_argument("--archive", type=pathlib.Path)
    return parser.parse_args()


def _load_product_payloads(arguments: list[str]) -> dict[str, Any]:
    payloads: dict[str, Any] = {}
    for argument in arguments:
        if "=" not in argument:
            raise ValueError("product settings argument must be TARGET=PATH")
        target, raw_path = argument.split("=", 1)
        if target in payloads:
            raise ValueError(f"duplicate product settings input: {target}")
        if target not in PRODUCT_TARGET_SPECS:
            raise ValueError(f"unexpected product settings target: {target}")
        path = pathlib.Path(raw_path)
        payloads[target] = json.loads(path.read_text(encoding="utf-8"))
    return payloads


def main() -> int:
    args = parse_args()
    args.output.unlink(missing_ok=True)
    payloads = _load_product_payloads(args.product_settings)
    try:
        report = build_report(
            payloads,
            args.expected_main_bundle_id,
            args.expected_team_id,
            archive=args.archive,
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
