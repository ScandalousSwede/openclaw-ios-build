from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

import verify_aies_internal_signing as verifier

MAIN_ID = "ai.openclaw.client"
TEAM_ID = "Y5PE65HELJ"
GIT_SHA = "a" * 40
ARCHIVE_UUID = "12345678-1234-5678-1234-567812345678"
MACHO_UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
OTHER_MACHO_UUID = "11111111-2222-3333-4444-555555555555"
SIGNING_CERTIFICATE = b"aies-signing-certificate"
SIGNING_CERTIFICATE_SHA256 = hashlib.sha256(SIGNING_CERTIFICATE).hexdigest()
REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
BUNDLE_PATHS = {
    MAIN_ID: pathlib.PurePosixPath("."),
    f"{MAIN_ID}.share": pathlib.PurePosixPath("PlugIns/OpenClawShareExtension.appex"),
    f"{MAIN_ID}.activitywidget": pathlib.PurePosixPath(
        "PlugIns/OpenClawActivityWidget.appex"
    ),
    f"{MAIN_ID}.watchkitapp": pathlib.PurePosixPath("Watch/OpenClawWatchApp.app"),
    f"{MAIN_ID}.watchkitapp.extension": pathlib.PurePosixPath(
        "Watch/OpenClawWatchApp.app/PlugIns/OpenClawWatchExtension.appex"
    ),
}
BUNDLE_EXECUTABLES = {
    MAIN_ID: "OpenClaw",
    f"{MAIN_ID}.share": "OpenClawShareExtension",
    f"{MAIN_ID}.activitywidget": "OpenClawActivityWidget",
    f"{MAIN_ID}.watchkitapp": "OpenClawWatchApp",
    f"{MAIN_ID}.watchkitapp.extension": "OpenClawWatchExtension",
}
MISSING = object()
MACHO_PREFIX = b"\xcf\xfa\xed\xfe"


class AIESInternalSigningTests(unittest.TestCase):
    def test_valid_full_bundle_direct_distribution(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with self.mock_signing():
                report = verifier.build_report(args)
            self.assertEqual(report["status"], "exported_ipa_distribution_verified")
            self.assertEqual(
                report["schema"], "argus.openclaw-ios.signing-report.v4"
            )
            self.assertEqual(report["push_contract"]["transport"], "direct")
            self.assertEqual(report["push_contract"]["relay_base_url"], "")
            self.assertFalse(report["push_contract"]["relay_base_url_present"])
            self.assertEqual(len(report["ipa"]["bundles"]), 5)
            self.assertEqual(len(report["binary_binding"]["bundles"]), 5)
            self.assertEqual(len(report["ipa"]["auxiliary_code_objects"]), 1)
            self.assertEqual(
                len(report["binary_binding"]["auxiliary_code_objects"]), 1
            )
            self.assertEqual(
                report["binary_binding"]["auxiliary_code_objects"][0][
                    "archive_to_ipa_payload_equivalence"
                ]["mach_o_file_type"],
                verifier.MH_DYLIB,
            )
            self.assertEqual(
                report["ipa"]["global_code_object_topology"][
                    "discovered_mach_o_count"
                ],
                8,
            )
            for binding in report["binary_binding"]["bundles"]:
                self.assertNotEqual(
                    binding["archive_executable"]["raw_sha256"],
                    binding["ipa_executable"]["raw_sha256"],
                )
                self.assertEqual(
                    binding["archive_to_ipa_payload_equivalence"]["status"],
                    "signature_aware_payload_equivalent",
                )
                if binding["bundle_id"] == f"{MAIN_ID}.watchkitapp":
                    self.assertEqual(binding["executable_role"], "sdk_watchkit_stub")
                    self.assertIsNone(binding["dsym"])
                    self.assertNotEqual(
                        binding["archive_executable"]["raw_sha256"],
                        binding["watchkit_stub"]["archive"]["embedded_stub"][
                            "raw_sha256"
                        ],
                    )
                    self.assertEqual(
                        binding["watchkit_stub"][
                            "archive_to_ipa_payload_equivalence"
                        ]["status"],
                        "signature_aware_payload_equivalent",
                    )
                else:
                    self.assertEqual(binding["executable_role"], "compiled_product")
                    self.assertEqual(
                        binding["archive_executable"]["uuids"],
                        binding["dsym"]["uuids"],
                    )
            self.assertTrue(
                all(
                    item["signing_identity"]["trust_verified"]
                    for item in report["ipa"]["bundles"]
                )
            )
            self.assertNotIn("private", str(report).lower())
            self.assertTrue(
                all(
                    item["profile"]["beta_reports_active"]
                    for item in report["ipa"]["bundles"]
                )
            )
            self.assertNotIn("cms_signature_verified", str(report))

    def test_archive_only_report_verifies_five_bundles_and_dsyms(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            args.archive_only = True
            args.ipa = None
            with self.mock_signing():
                report = verifier.build_report(args)
            self.assertEqual(report["status"], "archive_integrity_verified")
            self.assertEqual(len(report["archive"]["bundles"]), 5)
            self.assertEqual(len(report["binary_binding"]["bundles"]), 5)
            self.assertEqual(report["binary_binding"]["required_dsym_count"], 4)
            self.assertEqual(report["binary_binding"]["verified_dsym_count"], 4)
            self.assertEqual(
                report["binary_binding"]["archive_global_code_object_topology"][
                    "discovered_mach_o_count"
                ],
                12,
            )
            self.assertEqual(
                len(report["binary_binding"]["auxiliary_code_objects"]), 1
            )
            self.assertNotIn("ipa", report)
            for binding in report["binary_binding"]["bundles"]:
                self.assertNotIn("ipa_executable", binding)
                if binding["bundle_id"] == f"{MAIN_ID}.watchkitapp":
                    self.assertEqual(binding["executable_role"], "sdk_watchkit_stub")
                    self.assertIsNone(binding["dsym"])
                    self.assertIn("archive", binding["watchkit_stub"])
                    self.assertNotIn("ipa", binding["watchkit_stub"])
                else:
                    self.assertEqual(
                        binding["archive_executable"]["uuids"],
                        binding["dsym"]["uuids"],
                    )

            archive_bundles = report["archive"]["bundles"]
            self.assertTrue(
                all(item["get_task_allow"] is True for item in archive_bundles)
            )
            self.assertTrue(
                all(
                    item["profile"]["profile_type"] == "development"
                    for item in archive_bundles
                )
            )

    def test_stage_b_rejects_development_signed_ipa(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with (
                self.mock_signing(
                    ipa_get_task_allow=True,
                    ipa_provisioned_devices=["fixture-device"],
                    ipa_leaf_common_name="Apple Development: Example (Y5PE65HELJ)",
                ),
                self.assertRaisesRegex(ValueError, "get-task-allow"),
            ):
                verifier.build_report(args)

    def test_stage_b_rejects_missing_get_task_allow(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with (
                self.mock_signing(ipa_get_task_allow=MISSING),
                self.assertRaisesRegex(ValueError, "explicitly disable get-task-allow"),
            ):
                verifier.build_report(args)

    def test_stage_b_rejects_non_distribution_authority(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with (
                self.mock_signing(
                    ipa_leaf_common_name="Apple Development: Example (Y5PE65HELJ)"
                ),
                self.assertRaisesRegex(ValueError, "not signed by Apple Distribution"),
            ):
                verifier.build_report(args)

    def test_stage_b_rejects_devices_and_enterprise_profiles(self) -> None:
        cases = (
            {"ipa_provisioned_devices": ["fixture-device"]},
            {"ipa_provisions_all_devices": True},
        )
        for options in cases:
            with self.subTest(options=options):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp))
                    with (
                        self.mock_signing(**options),
                        self.assertRaisesRegex(
                            ValueError,
                            "not App Store Connect distribution|non-App-Store",
                        ),
                    ):
                        verifier.build_report(args)

    def test_stage_b_rejects_missing_main_or_unexpected_child_aps(self) -> None:
        cases = (
            {"main_aps": None},
            {"ipa_child_aps": "production"},
        )
        for options in cases:
            with self.subTest(options=options):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp))
                    with (
                        self.mock_signing(**options),
                        self.assertRaisesRegex(
                            ValueError,
                            "aps-environment is not production|unexpected signed aps-environment",
                        ),
                    ):
                        verifier.build_report(args)

    def test_rejects_missing_bundle_executable(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            archive_app = args.archive / "Products" / "Applications" / "OpenClaw.app"
            bundle = self.bundle_path(archive_app, f"{MAIN_ID}.share")
            (bundle / BUNDLE_EXECUTABLES[f"{MAIN_ID}.share"]).unlink()
            with (
                self.mock_signing(),
                self.assertRaisesRegex(ValueError, "missing regular bundle executable"),
            ):
                verifier.build_report(args)

    def test_profile_and_entitlement_parsers_fail_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing profile entitlements"):
            verifier.selected_profile_fields({}, "fixture")
        self.assertFalse(
            verifier.entitlement_value_authorized(
                {"allowed": True}, {"unrecognized": True}
            )
        )

    def test_rejects_relay_configuration_in_exported_ipa(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp), ipa_push_transport="relay")
            with self.mock_signing():
                with self.assertRaisesRegex(
                    ValueError, "OpenClawPushTransport mismatch"
                ):
                    verifier.build_report(args)

    def test_rejects_whitespace_only_relay_value(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp), relay_value="   ")
            with self.mock_signing():
                with self.assertRaisesRegex(ValueError, "exact empty string"):
                    verifier.build_report(args)

    def test_rejects_missing_watch_extension(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(
                pathlib.Path(raw_temp),
                omit_bundle=f"{MAIN_ID}.watchkitapp.extension",
            )
            with self.mock_signing():
                with self.assertRaisesRegex(
                    ValueError, "packaged bundle topology mismatch"
                ):
                    verifier.build_report(args)

    def test_rejects_sixth_bundle_with_duplicate_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp), add_duplicate_bundle=True)
            with self.mock_signing():
                with self.assertRaisesRegex(
                    ValueError, "packaged bundle topology mismatch"
                ):
                    verifier.build_report(args)

    def test_rejects_extra_archive_application(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(
                pathlib.Path(raw_temp), add_archive_sibling_app=True
            )
            with self.mock_signing():
                with self.assertRaisesRegex(ValueError, "archive must contain exactly"):
                    verifier.build_report(args)

    def test_rejects_nonproduction_main_aps_entitlement(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with self.mock_signing(main_aps="development"):
                with self.assertRaisesRegex(
                    ValueError, "aps-environment is not production"
                ):
                    verifier.build_report(args)

    def test_rejects_wrong_signing_team(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with self.mock_signing(team_id="WRONGTEAM1"):
                with self.assertRaisesRegex(ValueError, "signed team mismatch"):
                    verifier.build_report(args)

    def test_rejects_wrong_signed_or_profile_application_identifier(self) -> None:
        cases = (
            {"signed_application_identifier": f"{TEAM_ID}.wrong"},
            {"profile_application_identifier": f"{TEAM_ID}.wrong"},
        )
        for options in cases:
            with self.subTest(options=options):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp))
                    with (
                        self.mock_signing(**options),
                        self.assertRaisesRegex(
                            ValueError, "application identifier mismatch"
                        ),
                    ):
                        verifier.build_report(args)

    def test_rejects_expired_distribution_profile(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            expiration = dt.datetime(2020, 1, 1, tzinfo=dt.timezone.utc)
            with self.mock_signing(profile_expiration=expiration):
                with self.assertRaisesRegex(ValueError, "expired provisioning profile"):
                    verifier.build_report(args)

    def test_rejects_signing_certificate_not_bound_to_profile(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with self.mock_signing(profile_certificate=b"different-certificate"):
                with self.assertRaisesRegex(
                    ValueError, "signing certificate is not authorized"
                ):
                    verifier.build_report(args)

    def test_rejects_profile_without_beta_reports_active(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with self.mock_signing(beta_reports_active=MISSING):
                with self.assertRaisesRegex(
                    ValueError, "not App Store Connect distribution"
                ):
                    verifier.build_report(args)

    def test_rejects_profile_with_false_beta_reports_active(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with self.mock_signing(beta_reports_active=False):
                with self.assertRaisesRegex(
                    ValueError, "not App Store Connect distribution"
                ):
                    verifier.build_report(args)

    def test_rejects_signed_associated_domains_absent_from_profile(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            signed_extra = {
                "com.apple.developer.associated-domains": ["applinks:argus.example"]
            }
            with self.mock_signing(signed_extra=signed_extra):
                with self.assertRaisesRegex(ValueError, "associated-domains"):
                    verifier.build_report(args)

    def test_profile_wildcards_authorize_narrow_signed_values(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            signed_extra = {
                "com.apple.developer.associated-domains": ["applinks:argus.example"]
            }
            profile_extra = {"com.apple.developer.associated-domains": ["applinks:*"]}
            with self.mock_signing(
                profile_application_identifier=f"{TEAM_ID}.*",
                signed_extra=signed_extra,
                profile_extra=profile_extra,
            ):
                report = verifier.build_report(args)
            main = next(
                item
                for item in report["ipa"]["bundles"]
                if item["bundle_id"] == MAIN_ID
            )
            self.assertIn(
                "com.apple.developer.associated-domains",
                main["authorized_entitlement_keys"],
            )

    def test_rejects_archive_and_ipa_nested_executable_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(
                pathlib.Path(raw_temp),
                mismatched_ipa_bundle=f"{MAIN_ID}.activitywidget",
            )
            with self.mock_signing():
                with self.assertRaisesRegex(
                    ValueError, "payload differ.*OpenClawActivityWidget"
                ):
                    verifier.build_report(args)

    def test_rejects_nested_archive_and_dsym_uuid_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(
                pathlib.Path(raw_temp),
                mismatched_dsym_bundle=f"{MAIN_ID}.watchkitapp.extension",
            )
            with self.mock_signing():
                with self.assertRaisesRegex(
                    ValueError, "dSYM UUIDs differ.*watchkitapp.extension"
                ):
                    verifier.build_report(args)

    def test_rejects_missing_dsym_for_every_compiled_product(self) -> None:
        compiled = [
            bundle_id
            for bundle_id in BUNDLE_PATHS
            if bundle_id != f"{MAIN_ID}.watchkitapp"
        ]
        for bundle_id in compiled:
            with self.subTest(bundle_id=bundle_id):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp))
                    self.dsym_binary(args.archive, bundle_id).unlink()
                    with (
                        self.mock_signing(),
                        self.assertRaisesRegex(ValueError, "missing matching dSYM"),
                    ):
                        verifier.build_report(args)

    def test_rejects_missing_or_mismatched_watchkit_stub(self) -> None:
        for mutation in ("missing", "mismatched"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp))
                    watch_bundle = self.bundle_path(
                        args.archive / "Products" / "Applications" / "OpenClaw.app",
                        f"{MAIN_ID}.watchkitapp",
                    )
                    stub = watch_bundle / "_WatchKitStub" / "WK"
                    if mutation == "missing":
                        stub.unlink()
                    else:
                        stub.write_bytes(b"different-sdk-stub")
                    with (
                        self.mock_signing(),
                        self.assertRaisesRegex(
                            ValueError,
                            "WatchKit SDK stub|does not match|payload differ|code-object topology",
                        ),
                    ):
                        verifier.build_report(args)

    def test_rejects_missing_or_mismatched_ipa_watchkit_stub(self) -> None:
        cases = (
            {"missing_ipa_watch_stub": True},
            {"mismatched_ipa_watch_stub": True},
        )
        for options in cases:
            with self.subTest(options=options):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp), **options)
                    with (
                        self.mock_signing(),
                        self.assertRaisesRegex(
                            ValueError,
                            "WatchKit SDK stub|does not match|payload differ|code-object topology",
                        ),
                    ):
                        verifier.build_report(args)

    def test_rejects_wrong_watchkit_plist_contract(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            watch_bundle = self.bundle_path(
                args.archive / "Products" / "Applications" / "OpenClaw.app",
                f"{MAIN_ID}.watchkitapp",
            )
            info_path = watch_bundle / "Info.plist"
            info = verifier.read_plist(info_path)
            info["WKCompanionAppBundleIdentifier"] = "ai.openclaw.invalid"
            with info_path.open("wb") as handle:
                plistlib.dump(info, handle)
            with (
                self.mock_signing(),
                self.assertRaisesRegex(ValueError, "companion identifier mismatch"),
            ):
                verifier.build_report(args)

    def test_rejects_unexpected_watchkit_stub_dsym(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            dsym = self.dsym_binary(args.archive, f"{MAIN_ID}.watchkitapp")
            dsym.parent.mkdir(parents=True, exist_ok=True)
            dsym.write_bytes(b"unexpected-watch-stub-dsym")
            with (
                self.mock_signing(),
                self.assertRaisesRegex(ValueError, "unexpected dSYM"),
            ):
                verifier.build_report(args)

    def test_auxiliary_framework_stage_a_topology_is_fail_closed(self) -> None:
        mutations = ("missing", "extra", "wrong-bundle-id", "profile")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp))
                    app = (
                        args.archive
                        / "Products"
                        / "Applications"
                        / "OpenClaw.app"
                    )
                    framework = app / verifier.WEBRTC_FRAMEWORK_RELATIVE_PATH
                    if mutation == "missing":
                        framework.rename(framework.with_suffix(".removed"))
                    elif mutation == "extra":
                        extra = app / "Frameworks" / "Unexpected.framework"
                        extra.mkdir(parents=True)
                        (extra / "Unexpected").write_bytes(
                            MACHO_PREFIX + b"unexpected-framework"
                        )
                    elif mutation == "wrong-bundle-id":
                        info_path = framework / "Info.plist"
                        info = verifier.read_plist(info_path)
                        info["CFBundleIdentifier"] = "org.example.replaced"
                        with info_path.open("wb") as handle:
                            plistlib.dump(info, handle)
                    else:
                        (framework / "embedded.mobileprovision").write_bytes(b"profile")
                    args.archive_only = True
                    args.ipa = None
                    with (
                        self.mock_signing(),
                        self.assertRaisesRegex(
                            ValueError,
                            "framework topology|WebRTC framework|provisioning profile",
                        ),
                    ):
                        verifier.build_report(args)

    def test_rejects_unexpected_auxiliary_code_containers(self) -> None:
        mutations = ("dylib", "xpc", "resource-mach-o", "signature-container")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp))
                    app = (
                        args.archive
                        / "Products"
                        / "Applications"
                        / "OpenClaw.app"
                    )
                    if mutation == "dylib":
                        (app / "Unexpected.dylib").write_bytes(
                            MACHO_PREFIX + b"unexpected-dylib"
                        )
                    elif mutation == "xpc":
                        (app / "XPCServices" / "Unexpected.xpc").mkdir(
                            parents=True
                        )
                    elif mutation == "resource-mach-o":
                        (app / "GRDB_GRDB.bundle" / "Unexpected").write_bytes(
                            MACHO_PREFIX + b"unexpected-resource-code"
                        )
                    else:
                        (app / "Unexpected.bundle" / "_CodeSignature").mkdir(
                            parents=True
                        )
                    args.archive_only = True
                    args.ipa = None
                    with (
                        self.mock_signing(),
                        self.assertRaisesRegex(
                            ValueError,
                            "dylib topology|XPC topology|code-object topology|bundle topology|signed code-container",
                        ),
                    ):
                        verifier.build_report(args)

    def test_auxiliary_framework_stage_b_identity_and_payload_are_fail_closed(self) -> None:
        cases = (
            ({"ipa_aux_leaf_common_name": "Apple Development: Example"}, None),
            ({"ipa_aux_team_identifier": "WRONGTEAM"}, None),
            ({"ipa_aux_code_identifier": "org.example.replaced"}, None),
            ({"auxiliary_entitlements": {"get-task-allow": False}}, None),
            ({}, "payload"),
            ({}, "uuid"),
        )
        for signing_options, mutation in cases:
            with self.subTest(signing_options=signing_options, mutation=mutation):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp))
                    if mutation:
                        root = args.ipa.parent / "ipa-root"
                        executable = (
                            root
                            / "Payload"
                            / "OpenClaw.app"
                            / verifier.WEBRTC_EXECUTABLE_RELATIVE_PATH
                        )
                        executable.write_bytes(
                            MACHO_PREFIX
                            + (
                                b"ipa-signature:changed-webrtc"
                                if mutation == "payload"
                                else b"uuid-mismatch"
                            )
                        )
                        self.rewrite_ipa(args)
                    with (
                        self.mock_signing(**signing_options),
                        self.assertRaisesRegex(
                            ValueError,
                            "Apple Distribution|identity mismatch|entitlements|payload differ|UUIDs differ",
                        ),
                    ):
                        verifier.build_report(args)

    def test_watchkit_support_and_global_ipa_topology_are_fail_closed(self) -> None:
        mutations = ("missing-support", "changed-support", "extra-top-level-mach-o")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(pathlib.Path(raw_temp))
                    root = args.ipa.parent / "ipa-root"
                    support = root / "WatchKitSupport2" / "WK"
                    if mutation == "missing-support":
                        support.unlink()
                    elif mutation == "changed-support":
                        support.write_bytes(MACHO_PREFIX + b"changed-support")
                    else:
                        (root / "UnexpectedMachO").write_bytes(
                            MACHO_PREFIX + b"unexpected-top-level"
                        )
                    self.rewrite_ipa(args)
                    with (
                        self.mock_signing(),
                        self.assertRaisesRegex(
                            ValueError,
                            "global Mach-O topology|WatchKitSupport2",
                        ),
                    ):
                        verifier.build_report(args)

    def test_signing_identity_verifies_entire_extracted_chain(self) -> None:
        commands: list[list[str]] = []

        def fake_run(command: list[str], *, combine_output: bool = False) -> bytes:
            del combine_output
            commands.append(command)
            if command[0] == "codesign" and any(
                item.startswith("--extract-certificates=") for item in command
            ):
                prefix = next(
                    item.split("=", 1)[1]
                    for item in command
                    if item.startswith("--extract-certificates=")
                )
                pathlib.Path(f"{prefix}0").write_bytes(SIGNING_CERTIFICATE)
                pathlib.Path(f"{prefix}1").write_bytes(b"apple-intermediate")
            if command[0] == "codesign":
                return (
                    b"Authority=Apple Distribution: Example (Y5PE65HELJ)\n"
                    + f"TeamIdentifier={TEAM_ID}\nIdentifier={MAIN_ID}\n".encode()
                )
            return b""

        with mock.patch.object(verifier, "run_tool", side_effect=fake_run):
            result = verifier.verify_signing_identity(
                pathlib.Path("OpenClaw.app"),
                "codesign",
                "security",
                TEAM_ID,
                MAIN_ID,
            )
        self.assertEqual(result["certificate_chain_count"], 2)
        self.assertEqual(result["leaf_certificate_sha256"], SIGNING_CERTIFICATE_SHA256)
        self.assertEqual(
            result["leaf_common_name"], "Apple Distribution: Example (Y5PE65HELJ)"
        )
        trust_command = next(command for command in commands if command[0] == "security")
        self.assertEqual(trust_command[:2], ["security", "verify-cert"])
        self.assertEqual(trust_command[-3:], ["-p", "codeSign", "-L"])
        self.assertEqual(trust_command.count("-c"), 2)

    def test_signing_identity_fails_when_leaf_trust_fails(self) -> None:
        def fake_run(command: list[str], *, combine_output: bool = False) -> bytes:
            del combine_output
            if command[0] == "codesign":
                prefix = next(
                    item.split("=", 1)[1]
                    for item in command
                    if item.startswith("--extract-certificates=")
                )
                pathlib.Path(f"{prefix}0").write_bytes(SIGNING_CERTIFICATE)
                return b""
            raise ValueError("security verification failed")

        with (
            mock.patch.object(verifier, "run_tool", side_effect=fake_run),
            self.assertRaisesRegex(ValueError, "security verification failed"),
        ):
            verifier.verify_signing_identity(
                pathlib.Path("OpenClaw.app"),
                "codesign",
                "security",
                TEAM_ID,
                MAIN_ID,
            )

    def test_macho_uuid_binding_keeps_architecture(self) -> None:
        output = (
            f"UUID: {MACHO_UUID.upper()} (arm64) binary\n"
            f"UUID: {OTHER_MACHO_UUID.upper()} (x86_64) binary\n"
        ).encode()
        with mock.patch.object(verifier, "run_tool", return_value=output):
            values = verifier.macho_uuids(pathlib.Path("binary"), "dwarfdump")
        self.assertEqual(
            values,
            [
                {"architecture": "arm64", "uuid": MACHO_UUID},
                {"architecture": "x86_64", "uuid": OTHER_MACHO_UUID},
            ],
        )

    def test_rejects_unsafe_ipa_member(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            ipa = temp / "unsafe.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("../outside", b"unsafe")
            with self.assertRaisesRegex(ValueError, "unsafe path"):
                verifier.safely_extract_ipa(ipa, temp / "extract")

    def test_main_removes_stale_report_when_verification_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            args.output.write_text('{"status":"stale"}\n', encoding="utf-8")
            with (
                mock.patch.object(verifier, "parse_args", return_value=args),
                mock.patch.object(
                    verifier, "build_report", side_effect=ValueError("hostile fixture")
                ),
                self.assertRaisesRegex(ValueError, "hostile fixture"),
            ):
                verifier.main()
            self.assertFalse(args.output.exists())
            self.assertFalse(args.output.with_suffix(".json.tmp").exists())

    def test_main_writes_only_a_complete_valid_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with (
                self.mock_signing(),
                mock.patch.object(verifier, "parse_args", return_value=args),
            ):
                verifier.main()
            payload = json.loads(args.output.read_text(encoding="utf-8"))
            self.assertEqual(
                payload["status"], "exported_ipa_distribution_verified"
            )

    def test_receipt_validator_rejects_missing_malformed_and_partial_results(self) -> None:
        malformed = (None, {}, {"schema": verifier.SCHEMA})
        for value in malformed:
            with self.subTest(value=value), self.assertRaises(ValueError):
                verifier.validate_report_contract(value, archive_only=False)

        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with self.mock_signing():
                valid = verifier.build_report(args)
            cases = []
            missing_ipa = dict(valid)
            missing_ipa.pop("ipa")
            cases.append(missing_ipa)
            partial_ipa = copy.deepcopy(valid)
            partial_ipa["ipa"]["bundles"].pop()
            cases.append(partial_ipa)
            missing_binding = copy.deepcopy(valid)
            missing_binding["binary_binding"]["bundles"][0].pop(
                "archive_to_ipa_payload_equivalence"
            )
            cases.append(missing_binding)
            missing_auxiliary = copy.deepcopy(valid)
            missing_auxiliary["ipa"]["auxiliary_code_objects"].clear()
            cases.append(missing_auxiliary)
            missing_auxiliary_binding = copy.deepcopy(valid)
            missing_auxiliary_binding["binary_binding"][
                "auxiliary_code_objects"
            ].clear()
            cases.append(missing_auxiliary_binding)
            missing_watch_support = copy.deepcopy(valid)
            missing_watch_support["binary_binding"].pop("watchkit_support")
            cases.append(missing_watch_support)
            partial_global_topology = copy.deepcopy(valid)
            partial_global_topology["ipa"]["global_code_object_topology"][
                "discovered_mach_o_count"
            ] = 7
            cases.append(partial_global_topology)
            malformed_status = copy.deepcopy(valid)
            malformed_status["status"] = "verified-ish"
            cases.append(malformed_status)
            for value in cases:
                with self.subTest(case=value.get("status")), self.assertRaises(
                    ValueError
                ):
                    verifier.validate_report_contract(value, archive_only=False)

    def test_main_rejects_zero_exit_style_malformed_report_and_removes_output(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            args.output.write_text('{"status":"stale"}\n', encoding="utf-8")
            with (
                mock.patch.object(verifier, "parse_args", return_value=args),
                mock.patch.object(
                    verifier,
                    "build_report",
                    return_value={"schema": verifier.SCHEMA, "status": "verified-ish"},
                ),
                self.assertRaisesRegex(ValueError, "invalid schema or status"),
            ):
                verifier.main()
            self.assertFalse(args.output.exists())

    def test_cli_returns_nonzero_and_no_receipt_when_verifier_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            output = root / "missing-report.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(pathlib.Path(verifier.__file__).resolve()),
                    "--archive",
                    str(root / "missing.xcarchive"),
                    "--archive-only",
                    "--output",
                    str(output),
                    "--expected-main-bundle-id",
                    MAIN_ID,
                    "--expected-team-id",
                    TEAM_ID,
                    "--expected-git-sha",
                    GIT_SHA,
                    "--expected-archive-uuid",
                    ARCHIVE_UUID,
                ],
                check=False,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def make_fixture(
        self,
        temp: pathlib.Path,
        *,
        ipa_push_transport: str = "direct",
        relay_value: str = "",
        omit_bundle: str | None = None,
        add_duplicate_bundle: bool = False,
        add_archive_sibling_app: bool = False,
        mismatched_ipa_bundle: str | None = None,
        mismatched_dsym_bundle: str | None = None,
        missing_ipa_watch_stub: bool = False,
        mismatched_ipa_watch_stub: bool = False,
    ) -> argparse.Namespace:
        archive = temp / "OpenClaw.xcarchive"
        archive_app = archive / "Products" / "Applications" / "OpenClaw.app"
        archive_executables = {
            bundle_id: MACHO_PREFIX + f"archive-signature:{bundle_id}".encode()
            for bundle_id in BUNDLE_PATHS
        }
        self.write_app_tree(
            archive_app,
            relay_value=relay_value,
            omit_bundle=omit_bundle,
            executables=archive_executables,
            add_duplicate_bundle=add_duplicate_bundle,
            auxiliary_executable=MACHO_PREFIX + b"archive-signature:webrtc",
        )
        if add_archive_sibling_app:
            self.write_bundle(
                archive / "Products" / "Applications" / "Other.app",
                "ai.openclaw.other",
            )
        for bundle_id, relative_path in BUNDLE_PATHS.items():
            if bundle_id == omit_bundle:
                continue
            if bundle_id == f"{MAIN_ID}.watchkitapp":
                continue
            bundle_path = (
                archive_app
                if relative_path == pathlib.PurePosixPath(".")
                else archive_app / relative_path
            )
            dsym = (
                archive
                / "dSYMs"
                / f"{bundle_path.name}.dSYM"
                / "Contents"
                / "Resources"
                / "DWARF"
                / BUNDLE_EXECUTABLES[bundle_id]
            )
            dsym.parent.mkdir(parents=True, exist_ok=True)
            dsym.write_bytes(
                MACHO_PREFIX + b"uuid-mismatch"
                if bundle_id == mismatched_dsym_bundle
                else MACHO_PREFIX + f"matching-dsym:{bundle_id}".encode()
            )

        ipa_root = temp / "ipa-root" / "Payload" / "OpenClaw.app"
        ipa_executables = {
            bundle_id: MACHO_PREFIX + f"ipa-signature:{bundle_id}".encode()
            for bundle_id in BUNDLE_PATHS
        }
        if mismatched_ipa_bundle is not None:
            ipa_executables[mismatched_ipa_bundle] = (
                MACHO_PREFIX + f"tampered-executable:{mismatched_ipa_bundle}".encode()
            )
        self.write_app_tree(
            ipa_root,
            push_transport=ipa_push_transport,
            relay_value=relay_value,
            omit_bundle=omit_bundle,
            executables=ipa_executables,
            add_duplicate_bundle=add_duplicate_bundle,
            auxiliary_executable=MACHO_PREFIX + b"ipa-signature:webrtc",
        )
        ipa_watch_stub = (
            self.bundle_path(ipa_root, f"{MAIN_ID}.watchkitapp")
            / "_WatchKitStub"
            / "WK"
        )
        if missing_ipa_watch_stub:
            ipa_watch_stub.unlink()
        elif mismatched_ipa_watch_stub:
            ipa_watch_stub.write_bytes(
                MACHO_PREFIX + b"sdk-stub-signature:different-payload"
            )
        archive_watch_support = archive / "WatchKitSupport2" / "WK"
        archive_watch_support.parent.mkdir(parents=True, exist_ok=True)
        archive_watch_support.write_bytes(
            self.bundle_path(archive_app, f"{MAIN_ID}.watchkitapp")
            .joinpath("_WatchKitStub", "WK")
            .read_bytes()
        )
        ipa_watch_support = temp / "ipa-root" / "WatchKitSupport2" / "WK"
        ipa_watch_support.parent.mkdir(parents=True, exist_ok=True)
        ipa_watch_support.write_bytes(
            ipa_watch_stub.read_bytes()
            if ipa_watch_stub.is_file()
            else archive_watch_support.read_bytes()
        )
        ipa = temp / "OpenClaw.ipa"
        with zipfile.ZipFile(ipa, "w") as output:
            for path in sorted((temp / "ipa-root").rglob("*")):
                if path.is_file():
                    output.write(path, path.relative_to(temp / "ipa-root"))
        return argparse.Namespace(
            archive=archive,
            ipa=ipa,
            output=temp / "report.json",
            expected_main_bundle_id=MAIN_ID,
            expected_team_id=TEAM_ID,
            expected_git_sha=GIT_SHA,
            expected_archive_uuid=ARCHIVE_UUID,
            codesign="codesign",
            dwarfdump="dwarfdump",
            security="security",
        )

    @classmethod
    def write_app_tree(
        cls,
        app: pathlib.Path,
        *,
        push_transport: str = "direct",
        relay_value: str = "",
        omit_bundle: str | None = None,
        executables: dict[str, bytes] | None = None,
        add_duplicate_bundle: bool = False,
        auxiliary_executable: bytes = MACHO_PREFIX + b"signature:webrtc",
    ) -> None:
        executables = executables or {
            bundle_id: f"binary:{bundle_id}".encode() for bundle_id in BUNDLE_PATHS
        }
        cls.write_bundle(
            app,
            MAIN_ID,
            main=True,
            push_transport=push_transport,
            relay_value=relay_value,
            executable=executables[MAIN_ID],
        )
        for bundle_id, relative_path in BUNDLE_PATHS.items():
            if bundle_id == MAIN_ID:
                continue
            path = app / relative_path
            if bundle_id != omit_bundle:
                cls.write_bundle(path, bundle_id, executable=executables[bundle_id])
        if add_duplicate_bundle:
            cls.write_bundle(
                app / "PlugIns" / "UnexpectedDuplicate.appex", f"{MAIN_ID}.share"
            )
        framework = app / verifier.WEBRTC_FRAMEWORK_RELATIVE_PATH
        framework.mkdir(parents=True, exist_ok=True)
        with (framework / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleExecutable": "WebRTC",
                    "CFBundleIdentifier": verifier.WEBRTC_BUNDLE_ID,
                    "CFBundlePackageType": "FMWK",
                },
                handle,
            )
        (framework / "WebRTC").write_bytes(auxiliary_executable)
        (framework / "_CodeSignature").mkdir(parents=True, exist_ok=True)
        (framework / "_CodeSignature" / "CodeResources").write_bytes(b"signature")
        for relative in verifier.EXPECTED_RESOURCE_BUNDLES:
            resource = app / relative
            resource.mkdir(parents=True, exist_ok=True)
            with (resource / "Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundlePackageType": "BNDL"}, handle)

    @staticmethod
    def write_bundle(
        path: pathlib.Path,
        bundle_id: str,
        *,
        main: bool = False,
        push_transport: str = "direct",
        relay_value: str = "",
        executable: bytes = b"fixture-executable",
    ) -> None:
        path.mkdir(parents=True, exist_ok=True)
        executable_name = BUNDLE_EXECUTABLES.get(bundle_id, "Other")
        info: dict[str, object] = {
            "CFBundleExecutable": executable_name,
            "CFBundleIdentifier": bundle_id,
        }
        if bundle_id == f"{MAIN_ID}.watchkitapp":
            info.update(
                {
                    "WKWatchKitApp": True,
                    "WKCompanionAppBundleIdentifier": MAIN_ID,
                }
            )
        (path / executable_name).write_bytes(executable)
        if bundle_id == f"{MAIN_ID}.watchkitapp":
            stub = path / "_WatchKitStub" / "WK"
            stub.parent.mkdir(parents=True, exist_ok=True)
            normalized = executable
            if normalized.startswith(MACHO_PREFIX):
                normalized = normalized[len(MACHO_PREFIX) :]
            for prefix in (b"archive-signature:", b"ipa-signature:"):
                if normalized.startswith(prefix):
                    normalized = normalized[len(prefix) :]
                    break
            stub.write_bytes(MACHO_PREFIX + b"sdk-stub-signature:" + normalized)
        if main:
            info.update(
                {
                    "CFBundleShortVersionString": "2026.8.23",
                    "CFBundleVersion": "17",
                    "OpenClawPushTransport": push_transport,
                    "OpenClawPushDistribution": "local",
                    "OpenClawPushRelayBaseURL": relay_value,
                    "OpenClawPushAPNsEnvironment": "production",
                    "OpenClawBuildGitSHA": GIT_SHA,
                    "OpenClawBuildConfiguration": "Release",
                    "OpenClawBuildArchiveUUID": ARCHIVE_UUID,
                    "OpenClawBuildAPSEnvironmentIfSigned": "production",
                }
            )
        with (path / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        (path / "embedded.mobileprovision").write_bytes(b"profile")
        (path / "_CodeSignature").mkdir(parents=True, exist_ok=True)
        (path / "_CodeSignature" / "CodeResources").write_bytes(b"signature")

    @staticmethod
    def bundle_path(app: pathlib.Path, bundle_id: str) -> pathlib.Path:
        relative = BUNDLE_PATHS[bundle_id]
        return app if relative == pathlib.PurePosixPath(".") else app / relative

    @staticmethod
    def rewrite_ipa(args: argparse.Namespace) -> pathlib.Path:
        root = args.ipa.parent / "ipa-root"
        with zipfile.ZipFile(args.ipa, "w") as output:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    output.write(path, path.relative_to(root))
        return root

    @staticmethod
    def dsym_binary(archive: pathlib.Path, bundle_id: str) -> pathlib.Path:
        relative = BUNDLE_PATHS[bundle_id]
        bundle_name = (
            "OpenClaw.app"
            if relative == pathlib.PurePosixPath(".")
            else relative.name
        )
        return (
            archive
            / "dSYMs"
            / f"{bundle_name}.dSYM"
            / "Contents"
            / "Resources"
            / "DWARF"
            / BUNDLE_EXECUTABLES[bundle_id]
        )

    @staticmethod
    def mock_signing(
        *,
        team_id: str = TEAM_ID,
        main_aps: str = "production",
        profile_expiration: dt.datetime = dt.datetime(
            2027, 8, 23, tzinfo=dt.timezone.utc
        ),
        profile_certificate: bytes = SIGNING_CERTIFICATE,
        profile_application_identifier: str | None = None,
        beta_reports_active: object = True,
        signed_extra: dict[str, object] | None = None,
        profile_extra: dict[str, object] | None = None,
        signed_application_identifier: str | None = None,
        ipa_get_task_allow: object = False,
        ipa_child_aps: str | None = None,
        ipa_provisioned_devices: list[str] | None = None,
        ipa_provisions_all_devices: bool = False,
        ipa_leaf_common_name: str = "Apple Distribution: Example (Y5PE65HELJ)",
        ipa_aux_leaf_common_name: str | None = None,
        ipa_aux_team_identifier: str | None = None,
        ipa_aux_code_identifier: str | None = None,
        auxiliary_entitlements: dict[str, object] | None = None,
    ):
        def entitlements(path: pathlib.Path, _codesign: str) -> dict[str, object]:
            bundle_id = verifier.read_plist(path / "Info.plist")["CFBundleIdentifier"]
            archive = ".xcarchive" in str(path)
            result: dict[str, object] = {
                "com.apple.developer.team-identifier": team_id,
                "application-identifier": signed_application_identifier
                or f"{team_id}.{bundle_id}",
                "get-task-allow": True if archive else ipa_get_task_allow,
            }
            if bundle_id == MAIN_ID:
                result["aps-environment"] = "development" if archive else main_aps
                result.update(signed_extra or {})
            elif not archive and ipa_child_aps is not None:
                result["aps-environment"] = ipa_child_aps
            return result

        def profile(path: pathlib.Path, _security: str) -> dict[str, object]:
            bundle_id = verifier.read_plist(path / "Info.plist")["CFBundleIdentifier"]
            archive = ".xcarchive" in str(path)
            profile_entitlements: dict[str, object] = {
                "application-identifier": profile_application_identifier
                or f"{team_id}.{bundle_id}",
                "get-task-allow": True if archive else ipa_get_task_allow,
            }
            if not archive and beta_reports_active is not MISSING:
                profile_entitlements["beta-reports-active"] = beta_reports_active
            if bundle_id == MAIN_ID:
                profile_entitlements["aps-environment"] = (
                    "development" if archive else main_aps
                )
                profile_entitlements.update(profile_extra or {})
            elif not archive and ipa_child_aps is not None:
                profile_entitlements["aps-environment"] = ipa_child_aps
            return {
                "UUID": f"profile-{bundle_id}",
                "Name": f"Profile {bundle_id}",
                "TeamIdentifier": [team_id],
                "ExpirationDate": profile_expiration,
                "DeveloperCertificates": [profile_certificate],
                "Entitlements": profile_entitlements,
                "ProvisionedDevices": (
                    ["fixture-development-device"]
                    if archive
                    else list(ipa_provisioned_devices or [])
                ),
                "ProvisionsAllDevices": False if archive else ipa_provisions_all_devices,
            }

        def uuids(path: pathlib.Path, _dwarfdump: str) -> list[dict[str, str]]:
            return (
                [{"architecture": "arm64", "uuid": OTHER_MACHO_UUID}]
                if path.read_bytes().endswith(b"uuid-mismatch")
                else [{"architecture": "arm64", "uuid": MACHO_UUID}]
            )

        def normalized_payload(path: pathlib.Path) -> bytes:
            content = path.read_bytes()
            if content.startswith(MACHO_PREFIX):
                content = content[len(MACHO_PREFIX) :]
            for prefix in (
                b"archive-signature:",
                b"ipa-signature:",
                b"sdk-stub-signature:",
            ):
                if content.startswith(prefix):
                    content = content[len(prefix) :]
                    break
            return content

        def payload_equivalence(
            archive_path: pathlib.Path,
            ipa_path: pathlib.Path,
            *,
            expected_file_type: int = 2,
        ) -> dict[str, object]:
            if normalized_payload(archive_path) != normalized_payload(ipa_path):
                raise ValueError(
                    "archive and exported IPA executable payload differ: "
                    + archive_path.parent.name
                )
            return {
                "schema": "aies.macho-signature-equivalence.v1",
                "status": "signature_aware_payload_equivalent",
                "architecture_count": 1,
                "mach_o_file_type": expected_file_type,
            }

        def signing_identity(
            path: pathlib.Path,
            _codesign: str,
            _security: str,
            expected_team_id: str,
            expected_code_identifier: str,
        ):
            archive = ".xcarchive" in str(path)
            auxiliary = path.suffix == ".framework"
            leaf_common_name = (
                "Apple Development: Example (Y5PE65HELJ)"
                if archive
                else (
                    ipa_aux_leaf_common_name
                    if auxiliary and ipa_aux_leaf_common_name is not None
                    else ipa_leaf_common_name
                )
            )
            return {
                "certificate_chain_count": 2,
                "leaf_certificate_sha256": SIGNING_CERTIFICATE_SHA256,
                "authorities": [leaf_common_name],
                "leaf_common_name": leaf_common_name,
                "team_identifier": (
                    ipa_aux_team_identifier
                    if auxiliary and not archive and ipa_aux_team_identifier
                    else expected_team_id
                ),
                "code_identifier": (
                    ipa_aux_code_identifier
                    if auxiliary and not archive and ipa_aux_code_identifier
                    else expected_code_identifier
                ),
                "trust_verified": True,
            }

        return mock.patch.multiple(
            verifier,
            read_code_entitlements=mock.Mock(side_effect=entitlements),
            read_optional_code_entitlements=mock.Mock(
                return_value=dict(auxiliary_entitlements or {})
            ),
            read_profile=mock.Mock(side_effect=profile),
            verify_code_signature=mock.Mock(return_value=None),
            verify_signing_identity=mock.Mock(side_effect=signing_identity),
            macho_uuids=mock.Mock(side_effect=uuids),
            compare_macho_payloads=mock.Mock(side_effect=payload_equivalence),
        )


class AIESReleaseConfigurationTests(unittest.TestCase):
    def test_exact_replay_workflow_is_credential_free_and_fixture_bound(self) -> None:
        workflow = (
            REPO_ROOT
            / ".github"
            / "workflows"
            / "ios-post-export-verifier-qualification.yml"
        ).read_text(encoding="utf-8")
        fixture_path = (
            REPO_ROOT
            / "apps"
            / "ios"
            / "Tools"
            / "fixtures"
            / "aies_export_boundary_run_33188911517.json"
        )
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        self.assertEqual(fixture["archive"]["artifact_id"], 9676279420)
        self.assertEqual(fixture["ipa"]["artifact_id"], 9692923415)
        self.assertEqual(fixture["diagnostic"]["artifact_id"], 9692924304)
        self.assertEqual(
            fixture["archive"]["artifact_sha256"],
            "d253acd7c1045d512dc8a1b9862d2a017f10b3ebd6005cf250ede0e539f52aa4",
        )
        self.assertEqual(
            fixture["ipa"]["ipa_sha256"],
            "6ab71eb0f64158726ce83af72de344f337447179538d82ec91e804eff431aa82",
        )
        self.assertEqual(
            fixture["diagnostic"][
                "accepted_owner_reported_evidence_zip_sha256"
            ],
            "bddbd362aa61e053ecabf412c9bb5d4a9b5d9e8fabec2ad8ae66d04e964b421a",
        )
        self.assertEqual(
            fixture["webrtc_framework"]["canonical_payload_sha256"],
            "57a623f9b84f041059af690feac199f5fb3def5a2ad09ead1e3461ad748e513e",
        )
        self.assertEqual(workflow.count("for iteration in $(seq 1 10)"), 1)
        self.assertIn("actions: read", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertNotIn("environment:", workflow)
        self.assertEqual(workflow.count('"secrets."'), 1)
        self.assertNotIn("ASC_PRIVATE_KEY", workflow)
        self.assertNotIn("OPENCLAW_APNS", workflow)
        self.assertEqual(workflow.count("upload_to_testflight"), 1)
        self.assertNotIn("xcodebuild -exportArchive", workflow)
        self.assertNotIn("fastlane ios aies_internal_testflight", workflow)
        self.assertIn("download_artifact 9692924304", workflow)
        self.assertIn("artifact_root_sha256_entries_verified", workflow)
        self.assertIn("artifact_nested_package_sha256_entries_verified", workflow)
        self.assertIn(
            "accepted-owner-metadata-not-derived-from-downloaded-artifact", workflow
        )
        self.assertIn("test_aies_release_gate_behavior.py", workflow)
        fixture_files = sorted(fixture_path.parent.rglob("*"))
        self.assertTrue(fixture_files)
        self.assertTrue(
            all(path.is_dir() or path.suffix == ".json" for path in fixture_files)
        )

    def test_workflow_pins_third_party_actions_and_defers_private_key(self) -> None:
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "ios-build-ipa.yml"
        ).read_text(encoding="utf-8")
        xcodegen_action = (
            REPO_ROOT / ".github" / "actions" / "setup-xcodegen" / "action.yml"
        ).read_text(encoding="utf-8")
        project_spec = (REPO_ROOT / "apps" / "ios" / "project.yml").read_text(
            encoding="utf-8"
        )
        package_preparation = (
            REPO_ROOT
            / "apps"
            / "ios"
            / "Tools"
            / "prepare_aies_package_build_root.py"
        ).read_text(encoding="utf-8")
        third_party_uses = re.findall(
            r"^\s*uses:\s*([^./\s][^@\s]+)@([^\s#]+)", workflow, re.MULTILINE
        )
        self.assertTrue(third_party_uses)
        self.assertTrue(
            all(re.fullmatch(r"[0-9a-f]{40}", ref) for _, ref in third_party_uses)
        )
        self.assertGreaterEqual(workflow.count('use-actions-cache: "false"'), 2)
        self.assertGreaterEqual(workflow.count('save-actions-cache: "false"'), 2)
        self.assertIn("github.ref_type", workflow)
        self.assertNotIn("prevent_self_review", workflow)
        self.assertIn("if reviewer_rules:", workflow)
        self.assertIn('("aies/ios-rc1-testflight", "branch")', workflow)
        self.assertIn("AIES_GITHUB_ACTOR: ${{ github.actor }}", workflow)
        self.assertIn(
            "AIES_GITHUB_TRIGGERING_ACTOR: ${{ github.triggering_actor }}", workflow
        )
        self.assertGreaterEqual(workflow.count('!= "ScandalousSwede"'), 2)
        self.assertIn("name: Verify exact release checkout", workflow)
        self.assertGreaterEqual(
            workflow.count("test_verify_aies_internal_signing.py"), 2
        )
        self.assertEqual(
            workflow.count("test_aies_macho_signature_equivalence.py"), 2
        )
        self.assertEqual(workflow.count("test_aies_release_gate_behavior.py"), 2)
        self.assertEqual(workflow.count("uses: ./.github/actions/setup-xcodegen"), 3)
        # The conformance job renders the tracked project twice in place. The
        # unsigned and signed lanes each delegate their two-pass generation to
        # the same exact-SHA disposable-build-root preparation contract.
        self.assertEqual(workflow.count("xcodegen generate"), 2)
        self.assertEqual(
            workflow.count("prepare_aies_package_build_root.py prepare"), 2
        )
        self.assertIn("for pass_number in (1, 2):", package_preparation)
        self.assertIn('[args.xcodegen, "generate"]', package_preparation)
        self.assertEqual(workflow.count("git -C ../.. diff --exit-code"), 1)
        self.assertEqual(
            workflow.count("git -C ../.. ls-files --others --exclude-standard"), 2
        )
        self.assertEqual(workflow.count('cmp -s "${first_diff}" "${second_diff}"'), 1)
        self.assertIn(
            "Second XcodeGen invocation produced no additional tracked or "
            "untracked changes.",
            workflow,
        )
        self.assertIn("XCODEGEN_VERSION: 2.46.0", xcodegen_action)
        self.assertIn(
            "XCODEGEN_SHA256: "
            "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
            xcodegen_action,
        )
        self.assertIn(
            '[[ "${version_output}" != "Version: ${XCODEGEN_VERSION}" ]]',
            xcodegen_action,
        )
        self.assertEqual(project_spec.count("path: Tests/Info.plist"), 1)
        self.assertEqual(project_spec.count("path: Tests/Logic/Info.plist"), 1)
        conformance_job = workflow.split("\n  xcodegen-conformance:\n", maxsplit=1)[1]
        conformance_job = conformance_job.split("\n  build:\n", maxsplit=1)[0]
        self.assertNotIn("environment:", conformance_job)
        self.assertNotIn("secrets.", conformance_job)
        self.assertEqual(conformance_job.count("xcodegen generate"), 2)
        first_generation = conformance_job.index("xcodegen generate")
        second_generation = conformance_job.index(
            "xcodegen generate", first_generation + 1
        )
        command_positions = [
            first_generation,
            conformance_job.index('git -C ../.. diff --binary > "${first_diff}"'),
            conformance_job.index(
                'first_untracked="$(git -C ../.. ls-files --others --exclude-standard)"'
            ),
            second_generation,
            conformance_job.index('git -C ../.. diff --binary > "${second_diff}"'),
            conformance_job.index(
                'second_untracked="$(git -C ../.. ls-files --others '
                '--exclude-standard)"'
            ),
            conformance_job.index('cmp -s "${first_diff}" "${second_diff}"'),
            conformance_job.index("git -C ../.. diff --exit-code"),
            conformance_job.index('if [[ -n "${second_untracked}" ]]'),
        ]
        self.assertEqual(command_positions, sorted(command_positions))
        build_job = workflow.split("\n  build:\n", maxsplit=1)[1]
        build_job = build_job.split("\n  signed-internal-testflight:\n", maxsplit=1)[0]
        self.assertIn("xcodegen-conformance", build_job)
        self.assertIn(
            "xcodegen-conformance",
            workflow.split("\n  signed-internal-testflight:\n", maxsplit=1)[1],
        )
        self.assertEqual(workflow.count("TalkModeManagerTests"), 2)
        self.assertEqual(workflow.count("TalkDurableOutboxTests"), 2)
        self.assertEqual(workflow.count("TalkModeIncrementalSpeechBufferTests"), 2)
        self.assertGreaterEqual(workflow.count("TalkTTSDiagnosticsTests"), 2)
        key_step = workflow.index("name: Materialize ephemeral App Store Connect key")
        fastlane_parse = workflow.index(
            "name: Parse Fastlane release configuration without credentials"
        )
        ios_tests = workflow.index("name: Run focused iOS reliability tests")
        release = workflow.index(
            "name: Build, verify, and upload internal TestFlight diagnostic"
        )
        self.assertLess(fastlane_parse, key_step)
        self.assertLess(ios_tests, key_step)
        self.assertLess(key_step, release)
        cleanup = workflow.index("name: Remove ephemeral App Store Connect key")
        for artifact_step in (
            "name: Upload signed IPA",
            "name: Upload signed xcarchive",
            "name: Upload signed dSYMs",
            "name: Upload signed release evidence",
        ):
            self.assertLess(workflow.index(artifact_step), cleanup)
        self.assertGreaterEqual(workflow.count("if: always() && !cancelled()"), 4)
        self.assertIn("${ASC_KEY_ID:-}", workflow)

    def test_aies_export_is_single_source_and_archive_evidence_is_failure_safe(
        self,
    ) -> None:
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "ios-build-ipa.yml"
        ).read_text(encoding="utf-8")
        fastfile = (REPO_ROOT / "apps" / "ios" / "fastlane" / "Fastfile").read_text(
            encoding="utf-8"
        )
        archive_options = fastfile.split(
            "\ndef aies_archive_build_options", maxsplit=1
        )[1].split("\ndef aies_export_build_options", maxsplit=1)[0]
        export_options = fastfile.split(
            "\ndef aies_export_build_options", maxsplit=1
        )[1].split("\ndef build_aies_beta_archive", maxsplit=1)[0]
        release_lane = fastfile.split(
            'lane :aies_internal_testflight do', maxsplit=1
        )[1].split("\n  ensure", maxsplit=1)[0]

        self.assertIn("skip_package_ipa: true", archive_options)
        self.assertIn('project: File.join(ios_root, "OpenClaw.xcodeproj")', archive_options)
        self.assertRegex(archive_options, re.compile(r"^\s+xcargs:", re.MULTILINE))
        self.assertNotIn("export_xcargs:", archive_options)
        self.assertIn("skip_build_archive: true", export_options)
        self.assertIn('project: File.join(ios_root, "OpenClaw.xcodeproj")', export_options)
        self.assertRegex(export_options, re.compile(r"^\s+xcargs:", re.MULTILINE))
        self.assertEqual(export_options.count('export_method: "app-store"'), 1)
        self.assertNotIn("export_xcargs:", export_options)
        self.assertEqual(fastfile.count("export_xcargs:"), 0)
        aies_export_options = fastfile.split(
            "\ndef aies_export_options", maxsplit=1
        )[1].split("\ndef aies_archive_build_options", maxsplit=1)[0]
        self.assertNotRegex(aies_export_options, re.compile(r"^\s+method:", re.MULTILINE))
        self.assertEqual(aies_export_options.count("manageAppVersionAndBuildNumber: false"), 1)
        self.assertEqual(aies_export_options.count("testFlightInternalTestingOnly: true"), 1)
        self.assertNotIn('"method" =>', aies_export_options)
        self.assertLess(
            release_lane.index("package_aies_archive_evidence!"),
            release_lane.index("export_aies_beta_archive"),
        )
        self.assertLess(
            release_lane.index("export_aies_beta_archive"),
            release_lane.index("package_aies_internal_evidence!"),
        )
        self.assertLess(
            release_lane.index("package_aies_internal_evidence!"),
            release_lane.index("upload_to_testflight"),
        )
        self.assertIn('File.join(context.fetch(:output_directory), "unverified-export")', fastfile)
        self.assertIn("FileUtils.mv(ipa_path, final_ipa)", fastfile)
        self.assertIn('minimum_build_number: required_env!("GITHUB_RUN_NUMBER")', fastfile)
        self.assertIn("[latest_build.to_i + 1, minimum].compact.max.to_s", fastfile)
        self.assertIn('env_present?(ENV["IOS_BETA_BUILD_NUMBER"])', fastfile)

        self.assertEqual(workflow.count("fastlane ios verify_aies_export_command"), 2)
        self.assertEqual(workflow.count("test_sanitize_aies_release_log.py"), 2)
        conformance_job = workflow.split("\n  xcodegen-conformance:\n", maxsplit=1)[1]
        conformance_job = conformance_job.split("\n  build:\n", maxsplit=1)[0]
        self.assertIn("fastlane ios verify_aies_export_command", conformance_job)
        self.assertNotIn("environment:", conformance_job)
        self.assertNotIn("secrets.", conformance_job)
        signed_job = workflow.split(
            "\n  signed-internal-testflight:\n", maxsplit=1
        )[1]
        self.assertLess(
            signed_job.index("Verify rendered AIES export command without credentials"),
            signed_job.index("Materialize ephemeral App Store Connect key"),
        )
        self.assertIn("group: aies-ios-internal-testflight", signed_job)
        self.assertIn("cancel-in-progress: false", signed_job)
        for retained in (
            "OpenClaw-archive-manifest.json",
            "OpenClaw-archive-signing-entitlements.json",
            "OpenClaw-export.log",
        ):
            self.assertIn(retained, signed_job)
        self.assertNotIn("unverified-export", workflow)
        self.assertLess(
            signed_job.index("name: Sanitize retained release log"),
            signed_job.index("name: Upload signed release evidence"),
        )
        self.assertLess(
            signed_job.index("name: Upload signed release evidence"),
            signed_job.index("name: Remove ephemeral App Store Connect key"),
        )
        lane_step = signed_job.split(
            "name: Build, verify, and upload internal TestFlight diagnostic",
            maxsplit=1,
        )[1].split("- name: Sanitize retained release log", maxsplit=1)[0]
        self.assertIn("set -uo pipefail", lane_step)
        self.assertIn('lane_status="${PIPESTATUS[0]}"', lane_step)
        self.assertIn('if [[ "${lane_status}" -ne 0 ]]', lane_step)
        self.assertIn('exit "${lane_status}"', lane_step)
        self.assertNotIn("|| true", lane_step)
        self.assertIn("OpenClaw-release-lane-status.json", signed_job)
        self.assertIn("archive_integrity_verified", signed_job)
        self.assertIn("exported_ipa_distribution_verified", signed_job)
        self.assertLess(
            signed_job.index("archive_integrity_verified"),
            signed_job.index("exported_ipa_distribution_verified"),
        )
        self.assertLess(
            signed_job.index("exported_ipa_distribution_verified"),
            signed_job.index("name: Upload signed IPA"),
        )

        package_function = fastfile.split(
            "\ndef package_aies_internal_evidence!", maxsplit=1
        )[1].split("\ndef verify_aies_asc_build!", maxsplit=1)[0]
        self.assertLess(
            package_function.index("verify_aies_internal_signing.py"),
            package_function.index("FileUtils.mv(ipa_path, final_ipa)"),
        )

    def test_rc1_single_owner_internal_release_policy_is_consistent(self) -> None:
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "ios-build-ipa.yml"
        ).read_text(encoding="utf-8")
        fastfile = (REPO_ROOT / "apps" / "ios" / "fastlane" / "Fastfile").read_text(
            encoding="utf-8"
        )
        runbook = (
            REPO_ROOT / "apps" / "ios" / "AIES_INTERNAL_TESTFLIGHT.md"
        ).read_text(encoding="utf-8")
        trigger_block = workflow.split("\npermissions:", maxsplit=1)[0]
        signed_job = workflow.split("\n  signed-internal-testflight:\n", maxsplit=1)[1]
        signed_job_header = signed_job.split("\n    steps:\n", maxsplit=1)[0]
        legacy_branch = "aies/" + "ios-tts-d1-testflight"

        self.assertEqual(trigger_block.count("workflow_dispatch:"), 1)
        for forbidden_trigger in (
            "push:",
            "pull_request:",
            "schedule:",
            "workflow_run:",
        ):
            self.assertNotIn(f"\n  {forbidden_trigger}", trigger_block)

        for policy_surface in (workflow, fastfile, runbook):
            self.assertIn("aies/ios-rc1-testflight", policy_surface)
            self.assertNotIn(legacy_branch, policy_surface)

        self.assertIn("if: >-", signed_job_header)
        self.assertIn("github.actor == 'ScandalousSwede'", signed_job_header)
        self.assertIn("github.triggering_actor == 'ScandalousSwede'", signed_job_header)
        self.assertIn("environment: aies-testflight-internal", signed_job_header)
        self.assertIn("environment: aies-testflight-internal", workflow)
        self.assertIn("AIES_TESTFLIGHT_INTERNAL_ENABLED", workflow)
        self.assertIn('required_env!("GITHUB_ACTOR") == "ScandalousSwede"', fastfile)
        self.assertIn(
            'required_env!("GITHUB_TRIGGERING_ACTOR") == "ScandalousSwede"',
            fastfile,
        )
        for selector in (
            "OpenClawChatOutboxStorageTests",
            "OpenClawChatOutboxIntegrationTests",
            "GatewayOperatorScopeTests",
            "GatewayOnboardingResetTests",
        ):
            self.assertEqual(workflow.count(selector), 2)
        self.assertIn("testFlightInternalTestingOnly", fastfile)
        self.assertIn("distribute_external: false", fastfile)
        self.assertIn("notify_external_testers: false", fastfile)
        self.assertIn("submit_beta_review: false", fastfile)
        self.assertNotIn("${{ secrets.OPENCLAW_APNS_PRIVATE_KEY", workflow)
        self.assertIn(
            "%w[OPENCLAW_APNS_PRIVATE_KEY_P8 OPENCLAW_APNS_PRIVATE_KEY_PATH]",
            fastfile,
        )
        self.assertIn("must not be stored in GitHub", runbook)

    def test_fastlane_marks_export_internal_only(self) -> None:
        fastfile = (REPO_ROOT / "apps" / "ios" / "fastlane" / "Fastfile").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'export_options["testFlightInternalTestingOnly"] = true', fastfile
        )
        self.assertIn(
            'export_options["manageAppVersionAndBuildNumber"] = false', fastfile
        )
        self.assertIn("distribute_external: false", fastfile)
        self.assertIn("submit_beta_review: false", fastfile)
        self.assertIn("skip_waiting_for_build_processing: false", fastfile)
        self.assertIn('audience_type == "INTERNAL_ONLY"', fastfile)
        self.assertIn('processing_state == "VALID"', fastfile)
        self.assertIn("unless builds.length == 1", fastfile)
        self.assertIn("external_distribution_requested: false", fastfile)
        self.assertIn("beta_review_requested: false", fastfile)
        self.assertNotIn("external_testing_enabled:", fastfile)
        self.assertNotIn("beta_review_submitted:", fastfile)

    def test_beta_prepare_validates_build_number_and_team_before_xcconfig(self) -> None:
        script = (REPO_ROOT / "scripts" / "ios-beta-prepare.sh").read_text(
            encoding="utf-8"
        )
        build_validation = '[[ ! "${BUILD_NUMBER}" =~ ^[0-9]+$ ]]'
        team_validation = '[[ ! "${TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]'
        self.assertIn(build_validation, script)
        self.assertIn(team_validation, script)
        prepare_invocation = script.index("\nprepare_build_dir\n")
        self.assertLess(script.index(build_validation), prepare_invocation)
        self.assertLess(script.index(team_validation), prepare_invocation)

    def test_beta_prepare_requires_dsyms_for_every_embedded_target(self) -> None:
        script = (REPO_ROOT / "scripts" / "ios-beta-prepare.sh").read_text(
            encoding="utf-8"
        )
        block_start = script.index(
            'write_generated_file "${BETA_XCCONFIG}" <<EOF\n'
        )
        block_end = script.index("\nEOF\n", block_start)
        beta_xcconfig = script[block_start:block_end]

        self.assertEqual(
            beta_xcconfig.count(
                "DEBUG_INFORMATION_FORMAT = dwarf-with-dsym"
            ),
            1,
        )


if __name__ == "__main__":
    unittest.main()
