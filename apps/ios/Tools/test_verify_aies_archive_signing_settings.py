from __future__ import annotations

import copy
import json
import pathlib
import plistlib
import sys
import tempfile
import unittest


TOOLS = pathlib.Path(__file__).resolve().parent
REPO_ROOT = TOOLS.parents[2]
sys.path.insert(0, str(TOOLS))

import verify_aies_archive_signing_settings as verifier  # noqa: E402


MAIN_ID = "ai.openclaw.client.J76B47MZ6V"
TEAM_ID = "J76B47MZ6V"


class AIESArchiveSigningSettingsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.payloads = self.valid_payloads()

    def test_accepts_five_role_bound_release_archive_products(self) -> None:
        report = verifier.build_report(self.payloads, MAIN_ID, TEAM_ID)

        self.assertEqual(
            report["status"],
            "product_settings_verified_resource_artifact_deferred",
        )
        self.assertEqual(report["target_count"], 5)
        self.assertEqual(report["expected_logical_target_count"], 9)
        self.assertEqual(report["signed_product_target_count"], 5)
        self.assertEqual(report["codeless_resource_target_count"], 4)
        self.assertEqual(report["resource_bundle_instance_count"], 6)
        self.assertFalse(report["resource_signing_settings_claimed"])
        self.assertFalse(report["manual_archive_identity_override"])
        self.assertFalse(report["manual_archive_profile_override"])
        self.assertEqual(report["archive_invocation_action"], "archive")
        self.assertEqual(report["effective_build_action"], "install")
        self.assertEqual(
            {record["target"] for record in report["targets"]},
            set(verifier.PRODUCT_TARGET_SPECS),
        )
        self.assertTrue(
            all(
                record["settings_context"]
                == (
                    "explicit_target_release_archive_invocation_"
                    "effective_install_action"
                )
                for record in report["targets"]
            )
        )
        self.assertTrue(
            all(
                record["invocation_action"] == "archive"
                and record["effective_build_action"] == "install"
                for record in report["targets"]
            )
        )

    def test_project_and_beta_config_own_all_product_signing_settings(self) -> None:
        project = (REPO_ROOT / "apps/ios/project.yml").read_text(encoding="utf-8")
        target_names = list(verifier.expected_product_targets(MAIN_ID))
        for index, target in enumerate(target_names):
            start = project.index(f"  {target}:\n")
            later_starts = [
                project.find(f"  {later}:\n", start + 1)
                for later in target_names[index + 1 :]
            ]
            ends = [position for position in later_starts if position >= 0]
            end = min(ends) if ends else project.index("  OpenClawTests:\n", start)
            block = project[start:end]
            with self.subTest(target=target):
                self.assertIn('CODE_SIGN_IDENTITY: "Apple Development"', block)
                self.assertIn('CODE_SIGN_STYLE: "$(OPENCLAW_CODE_SIGN_STYLE)"', block)
                self.assertIn(
                    'DEVELOPMENT_TEAM: "$(OPENCLAW_DEVELOPMENT_TEAM)"', block
                )

        beta_prepare = (REPO_ROOT / "scripts/ios-beta-prepare.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("OPENCLAW_CODE_SIGN_STYLE = Automatic", beta_prepare)
        self.assertIn("OPENCLAW_DEVELOPMENT_TEAM = ${TEAM_ID}", beta_prepare)
        self.assertIn("OPENCLAW_APP_PROFILE =\n", beta_prepare)
        self.assertIn("OPENCLAW_SHARE_PROFILE =\n", beta_prepare)

    def test_rejects_fingerprint_identity(self) -> None:
        self.settings("OpenClaw")["CODE_SIGN_IDENTITY"] = "A" * 40
        with self.assertRaisesRegex(ValueError, "certificate class, not a fingerprint"):
            verifier.build_report(self.payloads, MAIN_ID, TEAM_ID)

    def test_rejects_manual_profile_overrides(self) -> None:
        for name in ("PROVISIONING_PROFILE", "PROVISIONING_PROFILE_SPECIFIER"):
            with self.subTest(name=name):
                payloads = copy.deepcopy(self.payloads)
                self.settings("OpenClawShareExtension", payloads)[name] = "manual"
                with self.assertRaisesRegex(ValueError, f"must not set {name}"):
                    verifier.build_report(payloads, MAIN_ID, TEAM_ID)

    def test_rejects_product_team_style_or_signing_drift(self) -> None:
        cases = {
            "DEVELOPMENT_TEAM": "OTHERTEAM1",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "CODE_SIGN_IDENTITY": "iPhone Developer",
        }
        for name, value in cases.items():
            with self.subTest(name=name):
                payloads = copy.deepcopy(self.payloads)
                self.settings("OpenClawActivityWidget", payloads)[name] = value
                with self.assertRaisesRegex(ValueError, f"{name} mismatch"):
                    verifier.build_report(payloads, MAIN_ID, TEAM_ID)

    def test_rejects_wrong_action_configuration_platform_or_product_type(self) -> None:
        cases = {
            "ACTION": "build",
            "CONFIGURATION": "Debug",
            "PLATFORM_NAME": "iphonesimulator",
            "PRODUCT_TYPE": "com.apple.product-type.bundle",
            "WRAPPER_EXTENSION": "bundle",
        }
        for name, value in cases.items():
            with self.subTest(name=name):
                payloads = copy.deepcopy(self.payloads)
                self.settings("OpenClawWatchExtension", payloads)[name] = value
                with self.assertRaisesRegex(ValueError, f"{name} mismatch"):
                    verifier.build_report(payloads, MAIN_ID, TEAM_ID)

    def test_rejects_index_metadata_object_instead_of_build_settings(self) -> None:
        payloads = copy.deepcopy(self.payloads)
        payloads["OpenClaw"] = {
            "OpenClaw": {
                "/tmp/App.swift": {
                    "swiftASTModuleName": "OpenClaw",
                    "swiftASTCommandArguments": ["swiftc"],
                }
            }
        }
        with self.assertRaisesRegex(
            ValueError, "showBuildSettingsForIndex metadata is not build-settings evidence"
        ):
            verifier.build_report(payloads, MAIN_ID, TEAM_ID)

    def test_rejects_missing_or_extra_product_input(self) -> None:
        missing = copy.deepcopy(self.payloads)
        missing.pop("OpenClawWatchExtension")
        with self.assertRaisesRegex(ValueError, "product settings inputs mismatch"):
            verifier.build_report(missing, MAIN_ID, TEAM_ID)

        extra = copy.deepcopy(self.payloads)
        extra["Unexpected"] = []
        with self.assertRaisesRegex(ValueError, "product settings inputs mismatch"):
            verifier.build_report(extra, MAIN_ID, TEAM_ID)

    def test_rejects_empty_duplicate_or_wrong_target_record(self) -> None:
        empty = copy.deepcopy(self.payloads)
        empty["OpenClaw"] = []
        with self.assertRaisesRegex(ValueError, "exactly one target record"):
            verifier.build_report(empty, MAIN_ID, TEAM_ID)

        duplicate = copy.deepcopy(self.payloads)
        duplicate["OpenClaw"].append(copy.deepcopy(duplicate["OpenClaw"][0]))
        with self.assertRaisesRegex(ValueError, "exactly one target record"):
            verifier.build_report(duplicate, MAIN_ID, TEAM_ID)

        wrong = copy.deepcopy(self.payloads)
        wrong["OpenClaw"][0]["target"] = "OpenClawShareExtension"
        with self.assertRaisesRegex(ValueError, "not role-bound"):
            verifier.build_report(wrong, MAIN_ID, TEAM_ID)

    def test_archive_proves_four_logical_targets_and_six_codeless_bundles(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            archive = self.make_archive(pathlib.Path(raw))
            report = verifier.build_report(
                self.payloads, MAIN_ID, TEAM_ID, archive=archive
            )

            self.assertEqual(report["status"], "verified")
            self.assertEqual(report["target_count"], 9)
            resource = report["archive_resource_bundle_verification"]
            self.assertEqual(
                resource["status"], "verified_codeless_signing_not_applicable"
            )
            self.assertEqual(resource["logical_resource_target_count"], 4)
            self.assertEqual(resource["resource_bundle_instance_count"], 6)
            targets = {record["target"]: record for record in resource["logical_targets"]}
            self.assertEqual(set(targets), verifier.RESOURCE_TARGETS)
            self.assertEqual(
                len(targets["OpenClawKit_OpenClawKit"]["archive_bundle_instances"]),
                2,
            )
            self.assertTrue(
                all(
                    record["classification"]
                    == "codeless_package_resource_bundle_signing_not_applicable"
                    and not record["explicit_code_signing_setting_claimed"]
                    for record in targets.values()
                )
            )

    def test_archive_rejects_signature_executable_macho_missing_or_extra_bundle(self) -> None:
        for case in ("signature", "declared_executable", "macho", "missing", "extra"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as raw:
                archive = self.make_archive(pathlib.Path(raw))
                app = archive / "Products/Applications/OpenClaw.app"
                target = app / "GRDB_GRDB.bundle"
                if case == "signature":
                    (target / "_CodeSignature").mkdir()
                elif case == "declared_executable":
                    (target / "Info.plist").write_bytes(
                        plistlib.dumps({"CFBundleExecutable": "GRDB_GRDB"})
                    )
                elif case == "macho":
                    (target / "payload").write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
                elif case == "missing":
                    for child in list(target.iterdir()):
                        child.unlink()
                    target.rmdir()
                else:
                    (app / "Unexpected.bundle").mkdir()
                with self.assertRaises(ValueError):
                    verifier.verify_archive_resource_bundles(archive)

    def test_archive_rejects_symlinked_resource_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            archive = self.make_archive(root)
            app = archive / "Products/Applications/OpenClaw.app"
            target = app / "GRDB_GRDB.bundle"
            external = root / "external.bundle"
            external.mkdir()
            for child in list(target.iterdir()):
                child.unlink()
            target.rmdir()
            try:
                target.symlink_to(external, target_is_directory=True)
            except OSError as error:
                self.skipTest(f"symlink creation unavailable: {error}")
            with self.assertRaisesRegex(ValueError, "symlink"):
                verifier.verify_archive_resource_bundles(archive)

    def test_product_settings_argument_parser_rejects_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = pathlib.Path(raw) / "settings.json"
            path.write_text(json.dumps(self.payloads["OpenClaw"]), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate product settings"):
                verifier._load_product_payloads(
                    [f"OpenClaw={path}", f"OpenClaw={path}"]
                )

    def settings(
        self,
        target: str,
        payloads: dict[str, list[dict[str, object]]] | None = None,
    ) -> dict[str, str]:
        source = self.payloads if payloads is None else payloads
        return source[target][0]["buildSettings"]  # type: ignore[return-value]

    @staticmethod
    def make_archive(raw: pathlib.Path) -> pathlib.Path:
        archive = raw / "OpenClaw.xcarchive"
        app = archive / "Products/Applications/OpenClaw.app"
        for relative in verifier.ARCHIVE_RESOURCE_BUNDLES:
            bundle = app.joinpath(*relative.parts)
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle / "Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": f"fixture.{bundle.stem}"})
            )
            (bundle / "resource.txt").write_text("fixture", encoding="utf-8")
        return archive

    @staticmethod
    def valid_payloads() -> dict[str, list[dict[str, object]]]:
        payloads: dict[str, list[dict[str, object]]] = {}
        for target, bundle_id in verifier.expected_product_targets(MAIN_ID).items():
            spec = verifier.PRODUCT_TARGET_SPECS[target]
            payloads[target] = [
                {
                    "target": target,
                    "buildSettings": {
                        "ACTION": "install",
                        "CONFIGURATION": "Release",
                        "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
                        "PRODUCT_TYPE": spec["product_type"],
                        "WRAPPER_EXTENSION": spec["wrapper_extension"],
                        "PLATFORM_NAME": spec["platform_name"],
                        "CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGNING_REQUIRED": "YES",
                        "CODE_SIGN_STYLE": "Automatic",
                        "DEVELOPMENT_TEAM": TEAM_ID,
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "PROVISIONING_PROFILE": "",
                        "PROVISIONING_PROFILE_SPECIFIER": "",
                    },
                }
            ]
        return payloads


if __name__ == "__main__":
    unittest.main()
