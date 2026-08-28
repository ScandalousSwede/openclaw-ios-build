from __future__ import annotations

import argparse
import copy
import json
import pathlib
import plistlib
import tempfile
import unittest
from unittest import mock

import test_verify_aies_internal_signing as signing_tests
import verify_aies_internal_signing as signing_verifier
import write_build_manifest


class BuildManifestTests(unittest.TestCase):
    def test_unsigned_manifest_uses_archived_metadata_and_hashes_artifacts(self) -> None:
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
                security="security",
                artifact_stage=write_build_manifest.UNSIGNED_ARCHIVE_QUALIFICATION,
                distribution_verification=None,
                archive_verification=None,
                expected_main_bundle_id=None,
                expected_team_id=None,
            )

            slices = [{"uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "architecture": "arm64"}]
            with (
                mock.patch.object(write_build_manifest, "run_dwarfdump", return_value=slices),
                mock.patch.object(write_build_manifest, "signed_aps_environment", return_value="development"),
            ):
                manifest = write_build_manifest.build_manifest(args)

            self.assertEqual(manifest["schema"], write_build_manifest.SCHEMA)
            self.assertEqual(
                manifest["artifact_stage"],
                write_build_manifest.UNSIGNED_ARCHIVE_QUALIFICATION,
            )
            self.assertEqual(manifest["evidence_stage"], "unsigned")
            self.assertEqual(
                manifest["distribution_readiness"],
                {
                    "status": "NOT_APPLICABLE_UNSIGNED",
                    "final_distribution_verified": False,
                    "upload_eligible": False,
                },
            )
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

    def test_archive_only_manifest_omits_ipa_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = self.write_full_archive(temp)
            args = self.make_args(temp=temp, archive=archive)
            args.archive_only = True
            args.ipa = None
            args.artifact_stage = write_build_manifest.ARCHIVE_PRE_EXPORT
            receipt_path = self.write_valid_stage_a_receipt(temp)
            args.archive_verification = receipt_path
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            slices = [
                {
                    "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    "architecture": "arm64",
                }
            ]
            with (
                mock.patch.object(write_build_manifest, "run_dwarfdump", return_value=slices),
                mock.patch.object(
                    write_build_manifest,
                    "signed_aps_environment",
                    return_value="development",
                ),
                mock.patch.object(
                    write_build_manifest,
                    "replay_signing_verification",
                    return_value=receipt,
                ),
            ):
                manifest = write_build_manifest.build_manifest(args)

            self.assertEqual(manifest["evidence_stage"], "archive")
            self.assertEqual(
                manifest["artifact_stage"], write_build_manifest.ARCHIVE_PRE_EXPORT
            )
            self.assertEqual(
                manifest["embedded_distribution_expectations"][
                    "main_app_aps_environment"
                ],
                "production",
            )
            self.assertEqual(
                manifest["observed_archive_signing"][
                    "main_app_aps_environment"
                ],
                "development",
            )
            self.assertEqual(
                manifest["distribution_readiness"],
                {
                    "status": "NOT_FINAL_PRE_EXPORT",
                    "final_distribution_verified": False,
                    "upload_eligible": False,
                },
            )
            self.assertEqual(
                manifest["final_distribution_verification"]["status"],
                "pending_exported_ipa_stage_b",
            )
            self.assertEqual(
                [item["kind"] for item in manifest["artifacts"]],
                ["xcarchive", "dsyms"],
            )

    def test_post_export_manifest_binds_complete_stage_b_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = self.write_full_archive(temp)
            args = self.make_args(temp=temp, archive=archive)
            receipt_path = self.write_valid_stage_b_receipt(temp)
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            slices = [
                {
                    "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    "architecture": "arm64",
                }
            ]
            with (
                mock.patch.object(write_build_manifest, "run_dwarfdump", return_value=slices),
                mock.patch.object(
                    write_build_manifest,
                    "signed_aps_environment",
                    return_value="development",
                ),
                mock.patch.object(
                    write_build_manifest,
                    "replay_signing_verification",
                    return_value=receipt,
                ),
            ):
                manifest = write_build_manifest.build_manifest(args)

            self.assertEqual(
                manifest["artifact_stage"],
                write_build_manifest.EXPORTED_IPA_POST_EXPORT,
            )
            self.assertEqual(
                manifest["distribution_readiness"],
                {
                    "status": "VERIFIED_POST_EXPORT",
                    "final_distribution_verified": True,
                    "upload_eligible": True,
                },
            )
            verification = manifest["final_distribution_verification"]
            self.assertEqual(
                verification["status"], "exported_ipa_distribution_verified"
            )
            self.assertEqual(
                verification["receipt_sha256"],
                write_build_manifest.sha256(receipt_path),
            )
            self.assertEqual(
                verification["ipa_sha256"], write_build_manifest.sha256(args.ipa)
            )
            self.assertEqual(
                manifest["observed_archive_signing"]["main_app_aps_environment"],
                "development",
            )

    def test_post_export_manifest_rejects_missing_or_malformed_stage_b_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = self.write_full_archive(temp)
            args = self.make_args(temp=temp, archive=archive)
            slices = [
                {
                    "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    "architecture": "arm64",
                }
            ]
            with (
                mock.patch.object(write_build_manifest, "run_dwarfdump", return_value=slices),
                mock.patch.object(
                    write_build_manifest,
                    "signed_aps_environment",
                    return_value="development",
                ),
            ):
                with self.assertRaisesRegex(ValueError, "missing regular Stage-B"):
                    write_build_manifest.build_manifest(args)
                malformed = temp / write_build_manifest.STAGE_B_RECEIPT_NAME
                malformed.write_text("not-json\n", encoding="utf-8")
                args.distribution_verification = malformed
                with self.assertRaisesRegex(ValueError, "invalid Stage-B"):
                    write_build_manifest.build_manifest(args)

    def test_post_export_manifest_rejects_partial_or_nonfinal_stage_b_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = self.write_full_archive(temp)
            args = self.make_args(temp=temp, archive=archive)
            receipt_path = self.write_valid_stage_b_receipt(temp)
            valid = json.loads(receipt_path.read_text(encoding="utf-8"))
            cases: list[dict[str, object]] = []
            partial = copy.deepcopy(valid)
            partial["ipa"]["bundles"].pop()
            cases.append(partial)
            development_aps = copy.deepcopy(valid)
            main = next(
                item
                for item in development_aps["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )
            main["aps_environment"] = "development"
            cases.append(development_aps)
            task_allow = copy.deepcopy(valid)
            next(
                item
                for item in task_allow["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )["get_task_allow"] = True
            cases.append(task_allow)
            wrong_identity = copy.deepcopy(valid)
            wrong_identity["expected_git_sha"] = "b" * 40
            cases.append(wrong_identity)
            wrong_team = self.replace_json_string(
                valid, signing_tests.TEAM_ID, "ZZZZZZZZZZ"
            )
            cases.append(wrong_team)
            wrong_application_id = copy.deepcopy(valid)
            wrong_application_main = next(
                item
                for item in wrong_application_id["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )
            wrong_application_main["application_identifier"] = (
                f"{signing_tests.TEAM_ID}.wrong"
            )
            wrong_application_main["profile"]["application_identifier"] = (
                f"{signing_tests.TEAM_ID}.wrong"
            )
            cases.append(wrong_application_id)
            inactive_beta = copy.deepcopy(valid)
            next(
                item
                for item in inactive_beta["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )["profile"]["beta_reports_active"] = False
            cases.append(inactive_beta)
            wrong_profile_team = copy.deepcopy(valid)
            next(
                item
                for item in wrong_profile_team["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )["profile"]["team_identifiers"] = ["ZZZZZZZZZZ"]
            cases.append(wrong_profile_team)
            untrusted_identity = copy.deepcopy(valid)
            next(
                item
                for item in untrusted_identity["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )["signing_identity"]["trust_verified"] = False
            cases.append(untrusted_identity)
            wrong_code_identifier = copy.deepcopy(valid)
            next(
                item
                for item in wrong_code_identifier["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )["signing_identity"]["code_identifier"] = "wrong"
            cases.append(wrong_code_identifier)
            false_as_zero = copy.deepcopy(valid)
            next(
                item
                for item in false_as_zero["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )["get_task_allow"] = 0
            cases.append(false_as_zero)
            true_as_one = copy.deepcopy(valid)
            next(
                item
                for item in true_as_one["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )["profile"]["beta_reports_active"] = 1
            cases.append(true_as_one)
            integer_as_float = copy.deepcopy(valid)
            next(
                item
                for item in integer_as_float["ipa"]["bundles"]
                if item["bundle_id"] == signing_tests.MAIN_ID
            )["profile"]["provisioned_device_count"] = 0.0
            cases.append(integer_as_float)

            slices = [
                {
                    "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    "architecture": "arm64",
                }
            ]
            with (
                mock.patch.object(write_build_manifest, "run_dwarfdump", return_value=slices),
                mock.patch.object(
                    write_build_manifest,
                    "signed_aps_environment",
                    return_value="development",
                ),
                mock.patch.object(
                    write_build_manifest,
                    "replay_signing_verification",
                    return_value=valid,
                ),
            ):
                for index, payload in enumerate(cases):
                    with self.subTest(index=index):
                        receipt_path.write_text(
                            json.dumps(payload, indent=2, sort_keys=True) + "\n",
                            encoding="utf-8",
                        )
                        args.distribution_verification = receipt_path
                        with self.assertRaises(ValueError):
                            write_build_manifest.build_manifest(args)

    def test_post_export_manifest_rejects_ipa_change_during_receipt_replay(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = self.write_full_archive(temp)
            args = self.make_args(temp=temp, archive=archive)
            receipt_path = self.write_valid_stage_b_receipt(temp)
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            slices = [
                {
                    "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    "architecture": "arm64",
                }
            ]

            def mutate_ipa(*_: object, **__: object) -> dict[str, object]:
                args.ipa.write_bytes(b"changed-after-stage-b-start")
                return receipt

            with (
                mock.patch.object(
                    write_build_manifest, "run_dwarfdump", return_value=slices
                ),
                mock.patch.object(
                    write_build_manifest,
                    "signed_aps_environment",
                    return_value="development",
                ),
                mock.patch.object(
                    write_build_manifest,
                    "replay_signing_verification",
                    side_effect=mutate_ipa,
                ),
                self.assertRaisesRegex(ValueError, "changed during Stage-B"),
            ):
                write_build_manifest.build_manifest(args)

    def test_signed_stage_requires_trusted_release_identity(self) -> None:
        args = argparse.Namespace(
            expected_main_bundle_id="ai.openclaw.wrong",
            expected_team_id=signing_tests.TEAM_ID,
        )
        with self.assertRaisesRegex(ValueError, "main bundle ID mismatch"):
            write_build_manifest.trusted_release_identity(
                args, signing_tests.MAIN_ID
            )
        args.expected_main_bundle_id = signing_tests.MAIN_ID
        args.expected_team_id = "bad"
        with self.assertRaisesRegex(ValueError, "Team ID"):
            write_build_manifest.trusted_release_identity(
                args, signing_tests.MAIN_ID
            )

    def test_stage_and_payload_combinations_fail_closed(self) -> None:
        args = argparse.Namespace(
            archive_only=True,
            ipa=None,
            artifact_stage=write_build_manifest.EXPORTED_IPA_POST_EXPORT,
        )
        with self.assertRaisesRegex(ValueError, "--archive-only requires"):
            write_build_manifest.resolve_artifact_stage(args)

        args = argparse.Namespace(
            archive_only=False,
            ipa=pathlib.Path("OpenClaw.ipa"),
            artifact_stage=write_build_manifest.ARCHIVE_PRE_EXPORT,
        )
        with self.assertRaisesRegex(ValueError, "must use --archive-only"):
            write_build_manifest.resolve_artifact_stage(args)

        args.artifact_stage = "UNKNOWN_STAGE"
        with self.assertRaisesRegex(ValueError, "unsupported artifact stage"):
            write_build_manifest.resolve_artifact_stage(args)

        args.artifact_stage = None
        with mock.patch.dict("os.environ", {}, clear=True):
            with self.assertRaisesRegex(ValueError, "requires explicit"):
                write_build_manifest.resolve_artifact_stage(args)
        with mock.patch.dict(
            "os.environ", {"AIES_INTERNAL_ONLY_CONFIRMED": "true"}, clear=True
        ):
            self.assertEqual(
                write_build_manifest.resolve_artifact_stage(args),
                write_build_manifest.EXPORTED_IPA_POST_EXPORT,
            )

    def test_non_export_stages_reject_distribution_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            archive = self.write_full_archive(temp)
            args = self.make_args(temp=temp, archive=archive)
            args.archive_only = True
            args.ipa = None
            args.artifact_stage = write_build_manifest.ARCHIVE_PRE_EXPORT
            args.distribution_verification = temp / "receipt.json"
            slices = [
                {
                    "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    "architecture": "arm64",
                }
            ]
            with (
                mock.patch.object(write_build_manifest, "run_dwarfdump", return_value=slices),
                mock.patch.object(
                    write_build_manifest,
                    "signed_aps_environment",
                    return_value="development",
                ),
                self.assertRaisesRegex(ValueError, "must not consume"),
            ):
                write_build_manifest.build_manifest(args)

    def test_main_removes_stale_manifest_when_generation_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            output = temp / "manifest.json"
            output.write_text('{"status":"stale"}\n', encoding="utf-8")
            args = argparse.Namespace(output=output)
            with (
                mock.patch.object(write_build_manifest, "parse_args", return_value=args),
                mock.patch.object(
                    write_build_manifest,
                    "build_manifest",
                    side_effect=ValueError("fixture failure"),
                ),
                self.assertRaisesRegex(ValueError, "fixture failure"),
            ):
                write_build_manifest.main()
            self.assertFalse(output.exists())
            self.assertFalse(output.with_suffix(".json.tmp").exists())

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
                security="security",
                archive_only=False,
                artifact_stage=write_build_manifest.UNSIGNED_ARCHIVE_QUALIFICATION,
                distribution_verification=None,
                archive_verification=None,
                expected_main_bundle_id=None,
                expected_team_id=None,
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
    def write_full_archive(cls, temp: pathlib.Path) -> pathlib.Path:
        archive = temp / "OpenClaw.xcarchive"
        app = archive / "Products" / "Applications" / "OpenClaw.app"
        info = cls.complete_info(aps_environment="production")
        info["CFBundleShortVersionString"] = "2026.8.23"
        info["OpenClawBuildExtensionBundleIDs"] = [
            f"{signing_tests.MAIN_ID}.share",
            f"{signing_tests.MAIN_ID}.activitywidget",
        ]
        info["OpenClawBuildWatchBundleIDs"] = [
            f"{signing_tests.MAIN_ID}.watchkitapp",
            f"{signing_tests.MAIN_ID}.watchkitapp.extension",
        ]
        cls.write_plist(app / "Info.plist", info)
        (app / "OpenClaw").write_bytes(b"binary")
        cls.write_plist(
            app / "PlugIns" / "OpenClawShareExtension.appex" / "Info.plist",
            {"CFBundleIdentifier": f"{signing_tests.MAIN_ID}.share"},
        )
        cls.write_plist(
            app / "PlugIns" / "OpenClawActivityWidget.appex" / "Info.plist",
            {"CFBundleIdentifier": f"{signing_tests.MAIN_ID}.activitywidget"},
        )
        watch_app = app / "Watch" / "OpenClawWatchApp.app"
        cls.write_plist(
            watch_app / "Info.plist",
            {"CFBundleIdentifier": f"{signing_tests.MAIN_ID}.watchkitapp"},
        )
        cls.write_plist(
            watch_app / "PlugIns" / "OpenClawWatchExtension.appex" / "Info.plist",
            {
                "CFBundleIdentifier": (
                    f"{signing_tests.MAIN_ID}.watchkitapp.extension"
                )
            },
        )
        (archive / "dSYMs" / "OpenClaw.app.dSYM").mkdir(parents=True)
        return archive

    @staticmethod
    def write_valid_stage_b_receipt(temp: pathlib.Path) -> pathlib.Path:
        helper = signing_tests.AIESInternalSigningTests()
        signing_args = helper.make_fixture(temp / "stage-b-fixture")
        with helper.mock_signing():
            receipt = signing_verifier.build_report(signing_args)
        path = temp / write_build_manifest.STAGE_B_RECEIPT_NAME
        path.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        return path

    @staticmethod
    def write_valid_stage_a_receipt(temp: pathlib.Path) -> pathlib.Path:
        helper = signing_tests.AIESInternalSigningTests()
        signing_args = helper.make_fixture(temp / "stage-a-fixture")
        signing_args.archive_only = True
        signing_args.ipa = None
        with helper.mock_signing():
            receipt = signing_verifier.build_report(signing_args)
        path = temp / write_build_manifest.STAGE_A_RECEIPT_NAME
        path.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        return path

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
            security="security",
            archive_only=False,
            artifact_stage=write_build_manifest.EXPORTED_IPA_POST_EXPORT,
            distribution_verification=None,
            archive_verification=None,
            expected_main_bundle_id=signing_tests.MAIN_ID,
            expected_team_id=signing_tests.TEAM_ID,
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

    @classmethod
    def replace_json_string(
        cls, value: object, before: str, after: str
    ) -> object:
        if isinstance(value, dict):
            return {
                key: cls.replace_json_string(item, before, after)
                for key, item in value.items()
            }
        if isinstance(value, list):
            return [cls.replace_json_string(item, before, after) for item in value]
        if isinstance(value, str):
            return value.replace(before, after)
        return value


if __name__ == "__main__":
    unittest.main()
