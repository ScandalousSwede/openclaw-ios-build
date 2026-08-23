from __future__ import annotations

import argparse
import pathlib
import plistlib
import tempfile
import unittest
from unittest import mock

import write_build_manifest


class BuildManifestTests(unittest.TestCase):
    def test_manifest_uses_archived_metadata_and_hashes_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = temp / "OpenClaw.xcarchive"
            app = archive / "Products" / "Applications" / "OpenClaw.app"
            self.write_plist(
                app / "Info.plist",
                {
                    "CFBundleExecutable": "OpenClaw",
                    "CFBundleIdentifier": "ai.openclaw.client",
                    "CFBundleShortVersionString": "2026.6.2",
                    "CFBundleVersion": "17",
                    "OpenClawBuildGitSHA": "a" * 40,
                    "OpenClawBuildGitBranch": "aies/test",
                    "OpenClawBuildTimestamp": "2026-08-22T20:00:00Z",
                    "OpenClawBuildXcodeVersion": "Xcode 26.2 (17C52)",
                    "OpenClawBuildSwiftVersion": "Swift 6.2",
                    "OpenClawBuildSDKVersion": "26.2",
                    "OpenClawBuildConfiguration": "Debug",
                    "OpenClawBuildArchiveUUID": "12345678-1234-5678-1234-567812345678",
                    "OpenClawBuildAPSEnvironmentIfSigned": "development",
                    "OpenClawBuildExtensionBundleIDs": ["ai.openclaw.client.share"],
                    "OpenClawBuildWatchBundleIDs": ["ai.openclaw.client.watchkitapp"],
                },
            )
            (app / "OpenClaw").write_bytes(b"binary")
            self.write_plist(
                app / "PlugIns" / "Share.appex" / "Info.plist",
                {"CFBundleIdentifier": "ai.openclaw.client.share"},
            )
            self.write_plist(
                app / "Watch" / "OpenClaw Watch.app" / "Info.plist",
                {"CFBundleIdentifier": "ai.openclaw.client.watchkitapp"},
            )
            (archive / "dSYMs" / "OpenClaw.app.dSYM").mkdir(parents=True)
            ipa = self.write_artifact(temp / "OpenClaw.ipa", b"ipa")
            archive_zip = self.write_artifact(temp / "OpenClaw.xcarchive.zip", b"archive")
            dsym_zip = self.write_artifact(temp / "OpenClaw-dSYMs.zip", b"dsyms")
            args = argparse.Namespace(
                archive=archive,
                output=temp / "manifest.json",
                git_sha="a" * 40,
                git_branch="aies/test",
                build_timestamp="2026-08-22T20:00:00Z",
                xcode_version="Xcode 26.2 (17C52)",
                swift_version="Swift 6.2",
                sdk_version="26.2",
                configuration="Debug",
                archive_uuid="12345678-1234-5678-1234-567812345678",
                ipa=ipa,
                archive_zip=archive_zip,
                dsym_zip=dsym_zip,
                github_run_id="42",
                dwarfdump="dwarfdump",
                codesign="codesign",
            )

            slices = [{"uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "architecture": "arm64"}]
            with (
                mock.patch.object(write_build_manifest, "run_dwarfdump", return_value=slices),
                mock.patch.object(write_build_manifest, "signed_aps_environment", return_value="development"),
            ):
                manifest = write_build_manifest.build_manifest(args)

            self.assertEqual(manifest["schema"], write_build_manifest.SCHEMA)
            self.assertEqual(manifest["git_sha"], "a" * 40)
            self.assertEqual(manifest["version"], "2026.6.2")
            self.assertEqual(manifest["build_number"], "17")
            self.assertEqual(manifest["main_bundle_id"], "ai.openclaw.client")
            self.assertEqual(manifest["extension_bundle_ids"], ["ai.openclaw.client.share"])
            self.assertEqual(manifest["watch_bundle_ids_if_present"], ["ai.openclaw.client.watchkitapp"])
            self.assertEqual(manifest["dsym_uuids"], ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
            self.assertEqual(manifest["aps_environment_if_signed"], "development")
            self.assertEqual([item["kind"] for item in manifest["artifacts"]], ["ipa", "xcarchive", "dsyms"])
            self.assertNotIn(str(temp), str(manifest))

    def test_manifest_rejects_main_binary_without_matching_dsym(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = temp / "OpenClaw.xcarchive"
            app = archive / "Products" / "Applications" / "OpenClaw.app"
            info = self.complete_info(aps_environment="")
            info["OpenClawBuildExtensionBundleIDs"] = []
            info["OpenClawBuildWatchBundleIDs"] = []
            self.write_plist(app / "Info.plist", info)
            (app / "OpenClaw").write_bytes(b"binary")
            (archive / "dSYMs" / "OpenClaw.app.dSYM").mkdir(parents=True)
            args = self.make_args(temp=temp, archive=archive)
            main = [{"uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "architecture": "arm64"}]
            unrelated = [{"uuid": "11111111-2222-3333-4444-555555555555", "architecture": "arm64"}]
            with (
                mock.patch.object(write_build_manifest, "run_dwarfdump", side_effect=[main, unrelated]),
                mock.patch.object(write_build_manifest, "signed_aps_environment", return_value=None),
            ):
                with self.assertRaisesRegex(ValueError, "main app binary UUIDs have no matching dSYM"):
                    write_build_manifest.build_manifest(args)

    def test_manifest_rejects_embedded_provenance_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = temp / "OpenClaw.xcarchive"
            app = archive / "Products" / "Applications" / "OpenClaw.app"
            info = self.complete_info(aps_environment="")
            info["OpenClawBuildGitSHA"] = "b" * 40
            info["OpenClawBuildExtensionBundleIDs"] = []
            info["OpenClawBuildWatchBundleIDs"] = []
            self.write_plist(app / "Info.plist", info)
            (app / "OpenClaw").write_bytes(b"binary")
            (archive / "dSYMs" / "OpenClaw.app.dSYM").mkdir(parents=True)
            args = self.make_args(temp=temp, archive=archive)
            slices = [{"uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "architecture": "arm64"}]
            with (
                mock.patch.object(write_build_manifest, "run_dwarfdump", return_value=slices),
                mock.patch.object(write_build_manifest, "signed_aps_environment", return_value=None),
            ):
                with self.assertRaisesRegex(ValueError, "embedded OpenClawBuildGitSHA mismatch"):
                    write_build_manifest.build_manifest(args)

    def test_manifest_rejects_archive_without_dsyms(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = temp / "OpenClaw.xcarchive"
            app = archive / "Products" / "Applications" / "OpenClaw.app"
            self.write_plist(
                app / "Info.plist",
                {
                    "CFBundleExecutable": "OpenClaw",
                    "CFBundleIdentifier": "ai.openclaw.client",
                    "CFBundleShortVersionString": "2026.6.2",
                    "CFBundleVersion": "17",
                },
            )
            (app / "OpenClaw").write_bytes(b"binary")
            artifact = self.write_artifact(temp / "artifact", b"artifact")
            args = argparse.Namespace(
                archive=archive,
                output=temp / "manifest.json",
                git_sha="a" * 40,
                git_branch="aies/test",
                build_timestamp="2026-08-22T20:00:00Z",
                xcode_version="Xcode 26.2",
                swift_version="Swift 6.2",
                sdk_version="26.2",
                configuration="Debug",
                archive_uuid="12345678-1234-5678-1234-567812345678",
                ipa=artifact,
                archive_zip=artifact,
                dsym_zip=artifact,
                github_run_id=None,
                dwarfdump="dwarfdump",
                codesign="codesign",
            )
            with mock.patch.object(
                write_build_manifest,
                "run_dwarfdump",
                return_value=[{"uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "architecture": "arm64"}],
            ):
                with self.assertRaisesRegex(ValueError, "no attributable dSYM UUIDs"):
                    write_build_manifest.build_manifest(args)

    @staticmethod
    def complete_info(aps_environment: str) -> dict[str, object]:
        return {
            "CFBundleExecutable": "OpenClaw",
            "CFBundleIdentifier": "ai.openclaw.client",
            "CFBundleShortVersionString": "2026.6.2",
            "CFBundleVersion": "17",
            "OpenClawBuildGitSHA": "a" * 40,
            "OpenClawBuildGitBranch": "aies/test",
            "OpenClawBuildTimestamp": "2026-08-22T20:00:00Z",
            "OpenClawBuildXcodeVersion": "Xcode 26.2 (17C52)",
            "OpenClawBuildSwiftVersion": "Swift 6.2",
            "OpenClawBuildSDKVersion": "26.2",
            "OpenClawBuildConfiguration": "Debug",
            "OpenClawBuildArchiveUUID": "12345678-1234-5678-1234-567812345678",
            "OpenClawBuildAPSEnvironmentIfSigned": aps_environment,
            "OpenClawBuildExtensionBundleIDs": [],
            "OpenClawBuildWatchBundleIDs": [],
        }

    @classmethod
    def make_args(cls, temp: pathlib.Path, archive: pathlib.Path) -> argparse.Namespace:
        ipa = cls.write_artifact(temp / "OpenClaw.ipa", b"ipa")
        archive_zip = cls.write_artifact(temp / "OpenClaw.xcarchive.zip", b"archive")
        dsym_zip = cls.write_artifact(temp / "OpenClaw-dSYMs.zip", b"dsyms")
        return argparse.Namespace(
            archive=archive,
            output=temp / "manifest.json",
            git_sha="a" * 40,
            git_branch="aies/test",
            build_timestamp="2026-08-22T20:00:00Z",
            xcode_version="Xcode 26.2 (17C52)",
            swift_version="Swift 6.2",
            sdk_version="26.2",
            configuration="Debug",
            archive_uuid="12345678-1234-5678-1234-567812345678",
            ipa=ipa,
            archive_zip=archive_zip,
            dsym_zip=dsym_zip,
            github_run_id="42",
            dwarfdump="dwarfdump",
            codesign="codesign",
        )

    @staticmethod
    def write_plist(path: pathlib.Path, value: dict[str, object]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as handle:
            plistlib.dump(value, handle)

    @staticmethod
    def write_artifact(path: pathlib.Path, value: bytes) -> pathlib.Path:
        path.write_bytes(value)
        return path


if __name__ == "__main__":
    unittest.main()
