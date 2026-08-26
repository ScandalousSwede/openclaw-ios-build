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

MAIN_ID = "ai.openclaw.client.J76B47MZ6V"
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


class AIESUnsignedArchiveTests(unittest.TestCase):
    def test_valid_unsigned_archive_ipa_and_zip(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(pathlib.Path(raw_temp))
            with mock.patch.object(verifier, "macho_uuids", side_effect=self.uuids):
                report = verifier.build_report(args)

            self.assertEqual(report["status"], "verified")
            self.assertEqual(report["bundle_count"], 5)
            self.assertEqual(len(report["archive"]["bundles"]), 5)
            self.assertEqual(len(report["ipa"]["bundles"]), 5)
            self.assertEqual(len(report["binary_binding"]["bundles"]), 5)
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

    def test_rejects_dsym_uuid_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.make_fixture(
                pathlib.Path(raw_temp),
                mismatched_dsym_bundle=f"{MAIN_ID}.watchkitapp.extension",
            )
            with (
                mock.patch.object(verifier, "macho_uuids", side_effect=self.uuids),
                self.assertRaisesRegex(ValueError, "dSYM UUIDs differ.*extension"),
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
        with (path / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle_id,
                    "CFBundleExecutable": executable_name,
                },
                handle,
            )
        (path / executable_name).write_bytes(f"unsigned:{bundle_id}".encode())

    @staticmethod
    def bundle_path(app: pathlib.Path, bundle_id: str) -> pathlib.Path:
        relative = BUNDLE_PATHS[bundle_id]
        return app if str(relative) == "." else app / relative

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
