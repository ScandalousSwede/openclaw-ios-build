from __future__ import annotations

import argparse
import hashlib
import pathlib
import plistlib
import shutil
import tempfile
import unittest
import zipfile
from unittest import mock

import verify_aies_unsigned_archive as verifier

MAIN_ID = "ai.openclaw.client"
MACHO_UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
OTHER_MACHO_UUID = "11111111-2222-3333-4444-555555555555"
BUNDLE_PATHS = {
    MAIN_ID: pathlib.PurePosixPath("."),
    f"{MAIN_ID}.share": pathlib.PurePosixPath(
        "PlugIns/OpenClawShareExtension.appex"
    ),
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


class AIESUnsignedBuildSettingsTests(unittest.TestCase):
    def test_accepts_canonical_five_target_unsigned_settings(self) -> None:
        report = verifier.build_settings_topology_report(
            self.build_settings_payload(), MAIN_ID
        )

        self.assertEqual(
            report["schema"],
            "argus.openclaw-ios.unsigned-build-settings-report.v2",
        )
        self.assertEqual(report["status"], "verified")
        self.assertEqual(report["target_count"], 5)
        self.assertEqual(report["required_entry_count"], 5)
        self.assertEqual(
            {item["bundle_id"] for item in report["targets"]}, set(BUNDLE_PATHS)
        )
        self.assertTrue(
            all(item["occurrence_count"] == 1 for item in report["targets"])
        )
        self.assertTrue(
            all(
                item["debug_information_format"] == "dwarf-with-dsym"
                for item in report["targets"]
            )
        )

    def test_rejects_missing_required_target(self) -> None:
        payload = self.build_settings_payload()
        payload = [item for item in payload if item["target"] != "OpenClawWatchApp"]
        with self.assertRaisesRegex(ValueError, "missing required.*OpenClawWatchApp"):
            verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_accepts_and_records_every_valid_required_target_occurrence(self) -> None:
        payload = self.build_settings_payload()
        payload[0]["buildSettings"].update(
            {
                "SDKROOT": "iphonesimulator",
                "PLATFORM_NAME": "iphonesimulator",
                "EFFECTIVE_PLATFORM_NAME": "-iphonesimulator",
                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            }
        )
        payload.append(
            {
                **payload[0],
                "buildSettings": {
                    **payload[0]["buildSettings"],
                    "SDKROOT": "iphoneos",
                    "PLATFORM_NAME": "iphoneos",
                    "EFFECTIVE_PLATFORM_NAME": "-iphoneos",
                },
            }
        )

        report = verifier.build_settings_topology_report(payload, MAIN_ID)

        self.assertEqual(report["target_count"], 5)
        self.assertEqual(report["required_entry_count"], 6)
        main = next(item for item in report["targets"] if item["target"] == "OpenClaw")
        self.assertEqual(main["occurrence_count"], 2)
        self.assertEqual(
            [item["source_index"] for item in main["occurrences"]], [0, 6]
        )
        self.assertEqual(
            [item["context"]["SDKROOT"] for item in main["occurrences"]],
            ["iphonesimulator", "iphoneos"],
        )
        self.assertEqual(
            len(
                {
                    item["full_build_settings_sha256"]
                    for item in main["occurrences"]
                }
            ),
            2,
        )

    def test_rejects_invalid_bundle_identifier_in_later_occurrence(self) -> None:
        payload = self.build_settings_payload()
        payload.append(
            {
                **payload[0],
                "buildSettings": {
                    **payload[0]["buildSettings"],
                    "PRODUCT_BUNDLE_IDENTIFIER": "ai.openclaw.client.J76B47MZ6V",
                },
            }
        )
        with self.assertRaisesRegex(ValueError, "bundle identifier mismatch.*index 6"):
            verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_rejects_invalid_topology_variable_in_later_occurrence(self) -> None:
        payload = self.build_settings_payload()
        payload.append(
            {
                **payload[0],
                "buildSettings": {
                    **payload[0]["buildSettings"],
                    "OPENCLAW_SHARE_BUNDLE_ID": (
                        "ai.openclaw.client.J76B47MZ6V.share"
                    ),
                },
            }
        )
        with self.assertRaisesRegex(ValueError, "topology variable mismatch.*index 6"):
            verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_rejects_enabled_signing_in_later_occurrence(self) -> None:
        payload = self.build_settings_payload()
        payload.append(
            {
                **payload[0],
                "buildSettings": {
                    **payload[0]["buildSettings"],
                    "CODE_SIGNING_ALLOWED": "YES",
                },
            }
        )
        with self.assertRaisesRegex(ValueError, "CODE_SIGNING_ALLOWED.*index 6"):
            verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_rejects_wrong_dsym_format_for_every_required_target(self) -> None:
        for source_index, item in enumerate(self.build_settings_payload()[:5]):
            with self.subTest(target=item["target"]):
                payload = self.build_settings_payload()
                payload[source_index]["buildSettings"][
                    "DEBUG_INFORMATION_FORMAT"
                ] = "dwarf"
                with self.assertRaisesRegex(
                    ValueError,
                    f"DEBUG_INFORMATION_FORMAT.*index {source_index}",
                ):
                    verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_rejects_missing_dsym_format_for_every_required_target(self) -> None:
        for source_index, item in enumerate(self.build_settings_payload()[:5]):
            with self.subTest(target=item["target"]):
                payload = self.build_settings_payload()
                del payload[source_index]["buildSettings"][
                    "DEBUG_INFORMATION_FORMAT"
                ]
                with self.assertRaisesRegex(
                    ValueError,
                    f"DEBUG_INFORMATION_FORMAT.*index {source_index}",
                ):
                    verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_rejects_wrong_dsym_format_in_later_occurrence(self) -> None:
        payload = self.build_settings_payload()
        payload.append(
            {
                **payload[0],
                "buildSettings": {
                    **payload[0]["buildSettings"],
                    "DEBUG_INFORMATION_FORMAT": "dwarf",
                },
            }
        )
        with self.assertRaisesRegex(ValueError, "DEBUG_INFORMATION_FORMAT.*index 6"):
            verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_rejects_missing_settings_in_later_occurrence(self) -> None:
        payload = self.build_settings_payload()
        payload.append({"target": "OpenClaw"})
        with self.assertRaisesRegex(ValueError, "missing buildSettings.*index 6"):
            verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_rejects_build_72_bundle_identifier(self) -> None:
        payload = self.build_settings_payload()
        payload[0]["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] = (
            "ai.openclaw.client.J76B47MZ6V"
        )
        with self.assertRaisesRegex(ValueError, "rendered bundle identifier mismatch"):
            verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_rejects_mismatched_canonical_variable(self) -> None:
        payload = self.build_settings_payload()
        payload[1]["buildSettings"]["OPENCLAW_SHARE_BUNDLE_ID"] = (
            "ai.openclaw.client.J76B47MZ6V.share"
        )
        with self.assertRaisesRegex(ValueError, "topology variable mismatch"):
            verifier.build_settings_topology_report(payload, MAIN_ID)

    def test_rejects_enabled_signing(self) -> None:
        payload = self.build_settings_payload()
        payload[2]["buildSettings"]["CODE_SIGNING_ALLOWED"] = "YES"
        with self.assertRaisesRegex(ValueError, "CODE_SIGNING_ALLOWED must be NO"):
            verifier.build_settings_topology_report(payload, MAIN_ID)

    @staticmethod
    def build_settings_payload() -> list[dict[str, object]]:
        identifiers = verifier.expected_target_bundle_identifiers(MAIN_ID)
        variables = {
            "OPENCLAW_APP_BUNDLE_ID": MAIN_ID,
            "OPENCLAW_SHARE_BUNDLE_ID": f"{MAIN_ID}.share",
            "OPENCLAW_ACTIVITY_WIDGET_BUNDLE_ID": f"{MAIN_ID}.activitywidget",
            "OPENCLAW_WATCH_APP_BUNDLE_ID": f"{MAIN_ID}.watchkitapp",
            "OPENCLAW_WATCH_EXTENSION_BUNDLE_ID": (
                f"{MAIN_ID}.watchkitapp.extension"
            ),
        }
        return [
            {
                "target": target,
                "buildSettings": {
                    **variables,
                    "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
                    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGNING_REQUIRED": "NO",
                    "CODE_SIGN_IDENTITY": "",
                    "DEVELOPMENT_TEAM": "",
                    "PROVISIONING_PROFILE_SPECIFIER": "",
                },
            }
            for target, bundle_id in identifiers.items()
        ] + [{"target": "OpenClawTests", "buildSettings": {}}]


class AIESUnsignedArchiveTests(unittest.TestCase):
    def test_valid_unsigned_archive_ipa_and_zip(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with mock.patch.object(verifier, "macho_uuids", side_effect=self.uuids):
                report = verifier.build_report(args)

            self.assertEqual(report["status"], "verified")
            self.assertEqual(
                report["schema"],
                "argus.openclaw-ios.unsigned-archive-report.v2",
            )
            self.assertEqual(report["bundle_count"], 5)
            self.assertEqual(len(report["archive"]["bundles"]), 5)
            self.assertEqual(len(report["ipa"]["bundles"]), 5)
            self.assertEqual(len(report["binary_binding"]["bundles"]), 5)
            self.assertEqual(report["binary_binding"]["bundle_count"], 5)
            self.assertEqual(
                report["binary_binding"]["compiled_executable_count"], 4
            )
            self.assertEqual(
                report["binary_binding"]["sdk_watchkit_stub_count"], 1
            )
            self.assertEqual(report["binary_binding"]["required_dsym_count"], 4)
            self.assertEqual(report["binary_binding"]["verified_dsym_count"], 4)
            self.assertEqual(
                report["ipa"]["artifact"]["sha256"],
                hashlib.sha256(args.ipa.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                report["archive_zip"]["sha256"],
                hashlib.sha256(args.archive_zip.read_bytes()).hexdigest(),
            )
            self.assertRegex(report["archive"]["tree"]["sha256"], r"^[0-9a-f]{64}$")
            for binding in report["binary_binding"]["bundles"]:
                self.assertEqual(
                    binding["archive_executable"], binding["ipa_executable"]
                )
                if binding["bundle_id"] == f"{MAIN_ID}.watchkitapp":
                    self.assertEqual(binding["executable_role"], "sdk_watchkit_stub")
                    self.assertIsNone(binding["dsym"])
                    self.assertEqual(binding["dsym_status"], "not_emitted")
                    self.assertEqual(
                        binding["watchkit_stub"]["archive"],
                        binding["watchkit_stub"]["ipa"],
                    )
                else:
                    self.assertEqual(binding["executable_role"], "compiled_product")
                    self.assertEqual(
                        binding["archive_executable"]["uuids"],
                        binding["dsym"]["uuids"],
                    )

    def test_rejects_missing_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(
                pathlib.Path(raw_temp), omit_bundle=f"{MAIN_ID}.share"
            )
            with (
                mock.patch.object(verifier, "macho_uuids", side_effect=self.uuids),
                self.assertRaisesRegex(ValueError, "bundle topology mismatch"),
            ):
                verifier.build_report(args)

    def test_rejects_extra_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp), add_extra_bundle=True)
            with (
                mock.patch.object(verifier, "macho_uuids", side_effect=self.uuids),
                self.assertRaisesRegex(ValueError, "bundle topology mismatch"),
            ):
                verifier.build_report(args)

    def test_rejects_dsym_uuid_mismatch_for_every_compiled_product(self) -> None:
        compiled = [
            bundle_id
            for bundle_id in BUNDLE_PATHS
            if bundle_id != f"{MAIN_ID}.watchkitapp"
        ]
        for bundle_id in compiled:
            with self.subTest(bundle_id=bundle_id):
                with tempfile.TemporaryDirectory() as raw_temp:
                    args = self.make_fixture(
                        pathlib.Path(raw_temp), mismatched_dsym_bundle=bundle_id
                    )
                    with (
                        mock.patch.object(
                            verifier, "macho_uuids", side_effect=self.uuids
                        ),
                        self.assertRaisesRegex(ValueError, "dSYM UUIDs differ"),
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
                        mock.patch.object(
                            verifier, "macho_uuids", side_effect=self.uuids
                        ),
                        self.assertRaisesRegex(ValueError, "missing matching dSYM"),
                    ):
                        verifier.build_report(args)

    def test_rejects_missing_or_mismatched_watchkit_stub(self) -> None:
        mutations = ("missing", "mismatched")
        for mutation in mutations:
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
                        mock.patch.object(
                            verifier, "macho_uuids", side_effect=self.uuids
                        ),
                        self.assertRaisesRegex(
                            ValueError, "WatchKit SDK stub|does not match"
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
                mock.patch.object(verifier, "macho_uuids", side_effect=self.uuids),
                self.assertRaisesRegex(ValueError, "companion identifier mismatch"),
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
                        mock.patch.object(
                            verifier, "macho_uuids", side_effect=self.uuids
                        ),
                        self.assertRaisesRegex(
                            ValueError, "WatchKit SDK stub|does not match"
                        ),
                    ):
                        verifier.build_report(args)

    def test_rejects_unexpected_watchkit_stub_dsym(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            dsym = self.dsym_binary(args.archive, f"{MAIN_ID}.watchkitapp")
            dsym.parent.mkdir(parents=True, exist_ok=True)
            dsym.write_bytes(b"unexpected-watch-stub-dsym")
            with (
                mock.patch.object(verifier, "macho_uuids", side_effect=self.uuids),
                self.assertRaisesRegex(ValueError, "unexpected dSYM"),
            ):
                verifier.build_report(args)

    def test_rejects_unsafe_ipa_zip(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with zipfile.ZipFile(args.ipa, "a") as archive:
                archive.writestr("../escaped", b"unsafe")
            with self.assertRaisesRegex(ValueError, "unsafe path"):
                verifier.build_report(args)

    def test_rejects_unsafe_archive_zip(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with zipfile.ZipFile(args.archive_zip, "a") as archive:
                archive.writestr("/absolute", b"unsafe")
            with self.assertRaisesRegex(ValueError, "unsafe path"):
                verifier.build_report(args)

    def test_rejects_ipa_archive_executable_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(
                pathlib.Path(raw_temp),
                mismatched_ipa_bundle=f"{MAIN_ID}.activitywidget",
            )
            with (
                mock.patch.object(verifier, "macho_uuids", side_effect=self.uuids),
                self.assertRaisesRegex(
                    ValueError, "unsigned executable identity differ"
                ),
            ):
                verifier.build_report(args)

    def test_rejects_missing_bundle_executable(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(
                pathlib.Path(raw_temp), missing_executable_bundle=f"{MAIN_ID}.share"
            )
            with (
                mock.patch.object(verifier, "macho_uuids", side_effect=self.uuids),
                self.assertRaisesRegex(ValueError, "missing regular bundle executable"),
            ):
                verifier.build_report(args)

    def test_main_removes_stale_report_after_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            args.output.write_text('{"status":"stale"}\n', encoding="utf-8")
            with (
                mock.patch.object(verifier, "parse_args", return_value=args),
                mock.patch.object(
                    verifier, "build_report", side_effect=ValueError("fixture failure")
                ),
                self.assertRaisesRegex(ValueError, "fixture failure"),
            ):
                verifier.main()
            self.assertFalse(args.output.exists())
            self.assertFalse(args.output.with_suffix(".json.tmp").exists())

    def make_fixture(
        self,
        temp: pathlib.Path,
        *,
        omit_bundle: str | None = None,
        add_extra_bundle: bool = False,
        mismatched_dsym_bundle: str | None = None,
        mismatched_ipa_bundle: str | None = None,
        missing_executable_bundle: str | None = None,
        missing_ipa_watch_stub: bool = False,
        mismatched_ipa_watch_stub: bool = False,
    ) -> argparse.Namespace:
        archive = temp / "OpenClaw.xcarchive"
        archive_app = archive / "Products" / "Applications" / "OpenClaw.app"
        self.write_app(archive_app, omit_bundle=omit_bundle)
        if add_extra_bundle:
            self.write_bundle(
                archive_app / "PlugIns" / "Unexpected.appex",
                f"{MAIN_ID}.unexpected",
            )
        if missing_executable_bundle is not None:
            bundle = self.bundle_path(archive_app, missing_executable_bundle)
            (bundle / BUNDLE_EXECUTABLES[missing_executable_bundle]).unlink()

        for bundle_id, relative in BUNDLE_PATHS.items():
            if bundle_id == omit_bundle:
                continue
            if bundle_id == f"{MAIN_ID}.watchkitapp":
                continue
            bundle = archive_app if str(relative) == "." else archive_app / relative
            executable = BUNDLE_EXECUTABLES[bundle_id]
            dsym = (
                archive
                / "dSYMs"
                / f"{bundle.name}.dSYM"
                / "Contents"
                / "Resources"
                / "DWARF"
                / executable
            )
            dsym.parent.mkdir(parents=True, exist_ok=True)
            dsym.write_bytes(
                b"uuid-mismatch"
                if bundle_id == mismatched_dsym_bundle
                else b"fixture-dsym"
            )

        ipa_root = temp / "ipa-root"
        payload_app = ipa_root / "Payload" / "OpenClaw.app"
        shutil.copytree(archive_app, payload_app)
        if mismatched_ipa_bundle is not None:
            bundle = self.bundle_path(payload_app, mismatched_ipa_bundle)
            (bundle / BUNDLE_EXECUTABLES[mismatched_ipa_bundle]).write_bytes(
                b"different-unsigned-executable"
            )
        ipa_watch_stub = (
            self.bundle_path(payload_app, f"{MAIN_ID}.watchkitapp")
            / "_WatchKitStub"
            / "WK"
        )
        if missing_ipa_watch_stub:
            ipa_watch_stub.unlink()
        elif mismatched_ipa_watch_stub:
            ipa_watch_stub.write_bytes(b"different-ipa-sdk-stub")
        ipa = temp / "OpenClaw.ipa"
        self.zip_tree(ipa_root, ipa)

        archive_zip_root = temp / "archive-zip-root"
        shutil.copytree(archive, archive_zip_root / archive.name)
        archive_zip = temp / "OpenClaw.xcarchive.zip"
        self.zip_tree(archive_zip_root, archive_zip)
        return argparse.Namespace(
            archive=archive,
            ipa=ipa,
            archive_zip=archive_zip,
            expected_main_bundle_id=MAIN_ID,
            output=temp / "unsigned-report.json",
            dwarfdump="dwarfdump",
        )

    @classmethod
    def write_app(
        cls, app: pathlib.Path, *, omit_bundle: str | None = None
    ) -> None:
        for bundle_id, relative in BUNDLE_PATHS.items():
            if bundle_id == omit_bundle:
                continue
            path = app if str(relative) == "." else app / relative
            cls.write_bundle(path, bundle_id)

    @staticmethod
    def write_bundle(path: pathlib.Path, bundle_id: str) -> None:
        path.mkdir(parents=True, exist_ok=True)
        executable_name = BUNDLE_EXECUTABLES.get(bundle_id, "Unexpected")
        info = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleExecutable": executable_name,
        }
        if bundle_id == f"{MAIN_ID}.watchkitapp":
            info.update(
                {
                    "WKWatchKitApp": True,
                    "WKCompanionAppBundleIdentifier": MAIN_ID,
                }
            )
        with (path / "Info.plist").open("wb") as handle:
            plistlib.dump(
                info,
                handle,
            )
        executable = f"unsigned:{bundle_id}".encode()
        (path / executable_name).write_bytes(executable)
        if bundle_id == f"{MAIN_ID}.watchkitapp":
            stub = path / "_WatchKitStub" / "WK"
            stub.parent.mkdir(parents=True, exist_ok=True)
            stub.write_bytes(executable)

    @staticmethod
    def bundle_path(app: pathlib.Path, bundle_id: str) -> pathlib.Path:
        relative = BUNDLE_PATHS[bundle_id]
        return app if str(relative) == "." else app / relative

    @staticmethod
    def dsym_binary(archive: pathlib.Path, bundle_id: str) -> pathlib.Path:
        relative = BUNDLE_PATHS[bundle_id]
        bundle_name = "OpenClaw.app" if str(relative) == "." else relative.name
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
    def zip_tree(root: pathlib.Path, output: pathlib.Path) -> None:
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(root.rglob("*")):
                relative = path.relative_to(root).as_posix()
                if path.is_dir():
                    archive.writestr(relative + "/", b"")
                else:
                    archive.write(path, relative)

    @staticmethod
    def uuids(path: pathlib.Path, _dwarfdump: str) -> list[dict[str, str]]:
        uuid = OTHER_MACHO_UUID if path.read_bytes() == b"uuid-mismatch" else MACHO_UUID
        return [{"architecture": "arm64", "uuid": uuid}]


if __name__ == "__main__":
    unittest.main()
