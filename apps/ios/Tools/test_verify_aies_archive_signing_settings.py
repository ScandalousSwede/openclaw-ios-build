from __future__ import annotations

import copy
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
        self.payload = self.valid_payload()

    def test_accepts_five_signed_products_and_four_codeless_resources(self) -> None:
        report = verifier.build_report(self.payloads(), MAIN_ID, TEAM_ID)

        self.assertEqual(report["status"], "verified")
        self.assertEqual(report["target_count"], 9)
        self.assertEqual(report["signed_product_target_count"], 5)
        self.assertEqual(report["archive_action_product_target_count"], 5)
        self.assertEqual(report["unsigned_resource_target_count"], 4)
        self.assertFalse(report["manual_archive_identity_override"])
        self.assertFalse(report["manual_archive_profile_override"])
        classifications = {
            record["target"]: record["classification"]
            for record in report["targets"]
        }
        self.assertEqual(
            set(classifications),
            set(verifier.expected_product_targets(MAIN_ID))
            | verifier.RESOURCE_TARGETS,
        )
        for target in verifier.RESOURCE_TARGETS:
            self.assertEqual(
                classifications[target],
                "package_resource_bundle_target_signing_disabled",
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
            verifier.build_report(self.payloads(), MAIN_ID, TEAM_ID)

    def test_rejects_manual_profile_overrides(self) -> None:
        for name in ("PROVISIONING_PROFILE", "PROVISIONING_PROFILE_SPECIFIER"):
            with self.subTest(name=name):
                payload = copy.deepcopy(self.payload)
                self.settings("OpenClawShareExtension", payload)[name] = "manual"
                with self.assertRaisesRegex(ValueError, f"must not set {name}"):
                    verifier.build_report(self.payloads(payload), MAIN_ID, TEAM_ID)

    def test_rejects_product_team_style_or_signing_drift(self) -> None:
        cases = {
            "DEVELOPMENT_TEAM": "OTHERTEAM1",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
        }
        for name, value in cases.items():
            with self.subTest(name=name):
                payload = copy.deepcopy(self.payload)
                self.settings("OpenClawActivityWidget", payload)[name] = value
                with self.assertRaisesRegex(ValueError, f"{name} mismatch"):
                    verifier.build_report(self.payloads(payload), MAIN_ID, TEAM_ID)

    def test_rejects_resource_signing_or_identity_drift(self) -> None:
        cases = {
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_REQUIRED": "YES",
            "CODE_SIGN_IDENTITY": "A" * 40,
            "DEVELOPMENT_TEAM": "OTHERTEAM1",
            "CODE_SIGN_STYLE": "Manual",
            "PROVISIONING_PROFILE_SPECIFIER": "Manual Profile",
        }
        for name, value in cases.items():
            with self.subTest(name=name):
                payload = copy.deepcopy(self.payload)
                self.settings("GRDB_GRDB", payload)[name] = value
                with self.assertRaises(ValueError):
                    verifier.build_report(self.payloads(payload), MAIN_ID, TEAM_ID)

    def test_accepts_harmless_inherited_resource_settings(self) -> None:
        settings = self.settings("GRDB_GRDB")
        settings.update(
            {
                "CODE_SIGN_STYLE": "Automatic",
                "DEVELOPMENT_TEAM": TEAM_ID,
                "CODE_SIGN_IDENTITY": "Apple Development",
                "EXECUTABLE_NAME": "GRDB_GRDB",
                "EXECUTABLE_PATH": "GRDB_GRDB.bundle/GRDB_GRDB",
                "MACH_O_TYPE": "mh_bundle",
            }
        )

        report = verifier.build_report(self.payloads(), MAIN_ID, TEAM_ID)

        resource = next(
            record for record in report["targets"] if record["target"] == "GRDB_GRDB"
        )
        self.assertEqual(resource["signing"]["CODE_SIGNING_ALLOWED"], "NO")
        self.assertEqual(
            resource["occurrences"][0]["observed_nonoperative_settings"][
                "DEVELOPMENT_TEAM"
            ],
            TEAM_ID,
        )

    def test_archive_proves_resource_bundles_are_codeless_and_unsigned(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            archive = pathlib.Path(raw) / "OpenClaw.xcarchive"
            app = archive / "Products/Applications/OpenClaw.app"
            for relative in verifier.ARCHIVE_RESOURCE_BUNDLES:
                bundle = app.joinpath(*relative.parts)
                bundle.mkdir(parents=True, exist_ok=True)
                (bundle / "Info.plist").write_bytes(
                    plistlib.dumps({"CFBundleIdentifier": f"fixture.{bundle.stem}"})
                )
                (bundle / "resource.txt").write_text("fixture", encoding="utf-8")

            report = verifier.verify_archive_resource_bundles(archive)

            self.assertEqual(report["status"], "verified_codeless_and_unsigned")
            self.assertEqual(
                report["resource_bundle_count"], len(verifier.ARCHIVE_RESOURCE_BUNDLES)
            )

    def test_archive_rejects_resource_code_signature_executable_or_macho(self) -> None:
        cases = ("signature", "declared_executable", "macho")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as raw:
                archive = pathlib.Path(raw) / "OpenClaw.xcarchive"
                app = archive / "Products/Applications/OpenClaw.app"
                for relative in verifier.ARCHIVE_RESOURCE_BUNDLES:
                    bundle = app.joinpath(*relative.parts)
                    bundle.mkdir(parents=True, exist_ok=True)
                    (bundle / "Info.plist").write_bytes(
                        plistlib.dumps({"CFBundleIdentifier": f"fixture.{bundle.stem}"})
                    )
                target = app / "GRDB_GRDB.bundle"
                if case == "signature":
                    (target / "_CodeSignature").mkdir()
                elif case == "declared_executable":
                    (target / "Info.plist").write_bytes(
                        plistlib.dumps({"CFBundleExecutable": "GRDB_GRDB"})
                    )
                else:
                    (target / "payload").write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
                with self.assertRaises(ValueError):
                    verifier.verify_archive_resource_bundles(archive)

    def test_rejects_missing_or_unexpected_resource_target(self) -> None:
        missing = [
            entry for entry in self.payload if entry["target"] != "textual_Textual"
        ]
        with self.assertRaisesRegex(ValueError, "archive-index.*textual_Textual"):
            verifier.build_report(self.payloads(missing), MAIN_ID, TEAM_ID)

        unexpected = copy.deepcopy(self.payload)
        unexpected_record = (
            {
                "target": "Unexpected_Resources",
                "buildSettings": self.resource_settings(),
            }
        )
        inputs = self.payloads(unexpected)
        inputs[1].append(unexpected_record)
        with self.assertRaisesRegex(ValueError, "unexpected package resource-bundle"):
            verifier.build_report(inputs, MAIN_ID, TEAM_ID)

    def test_rejects_conflicting_duplicate_target_settings(self) -> None:
        duplicate = copy.deepcopy(self.payload[0])
        duplicate["buildSettings"]["PRODUCT_TYPE"] = (
            "com.apple.product-type.app-extension"
        )
        inputs = self.payloads()
        inputs[0].append(duplicate)
        with self.assertRaisesRegex(ValueError, "conflicting archive settings"):
            verifier.build_report(inputs, MAIN_ID, TEAM_ID)

    def test_archive_action_input_must_contain_all_product_targets(self) -> None:
        with self.assertRaisesRegex(
            ValueError, "archive-action build-settings input omitted product targets"
        ):
            verifier.build_report([[], self.payloads()[1]], MAIN_ID, TEAM_ID)

    def test_archive_and_index_inputs_are_both_required(self) -> None:
        with self.assertRaisesRegex(ValueError, "both required"):
            verifier.build_report([self.payloads()[0]], MAIN_ID, TEAM_ID)

    def payloads(
        self, payload: list[dict[str, object]] | None = None
    ) -> list[list[dict[str, object]]]:
        source = self.payload if payload is None else payload
        products = set(verifier.expected_product_targets(MAIN_ID))
        return [
            [entry for entry in source if entry["target"] in products],
            [entry for entry in source if entry["target"] in verifier.RESOURCE_TARGETS],
        ]

    def settings(
        self,
        target: str,
        payload: list[dict[str, object]] | None = None,
    ) -> dict[str, str]:
        source = self.payload if payload is None else payload
        return next(
            entry["buildSettings"]
            for entry in source
            if entry["target"] == target
        )  # type: ignore[return-value]

    @staticmethod
    def resource_settings() -> dict[str, str]:
        return {
            "PRODUCT_TYPE": "com.apple.product-type.bundle",
            "WRAPPER_EXTENSION": "bundle",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": "",
            "CODE_SIGN_IDENTITY": "",
            "PROVISIONING_PROFILE": "",
            "PROVISIONING_PROFILE_SPECIFIER": "",
            "EXECUTABLE_NAME": "",
            "EXECUTABLE_PATH": "",
            "MACH_O_TYPE": "",
        }

    @classmethod
    def valid_payload(cls) -> list[dict[str, object]]:
        product_types = {
            "OpenClaw": "com.apple.product-type.application",
            "OpenClawShareExtension": "com.apple.product-type.app-extension",
            "OpenClawActivityWidget": "com.apple.product-type.app-extension",
            "OpenClawWatchApp": "com.apple.product-type.application.watchapp2",
            "OpenClawWatchExtension": (
                "com.apple.product-type.watchkit2-extension"
            ),
        }
        payload: list[dict[str, object]] = []
        for target, bundle_id in verifier.expected_product_targets(MAIN_ID).items():
            payload.append(
                {
                    "target": target,
                    "buildSettings": {
                        "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
                        "PRODUCT_TYPE": product_types[target],
                        "WRAPPER_EXTENSION": (
                            "app" if target in {"OpenClaw", "OpenClawWatchApp"} else "appex"
                        ),
                        "CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGNING_REQUIRED": "YES",
                        "CODE_SIGN_STYLE": "Automatic",
                        "DEVELOPMENT_TEAM": TEAM_ID,
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "PROVISIONING_PROFILE": "",
                        "PROVISIONING_PROFILE_SPECIFIER": "",
                    },
                }
            )
        payload.extend(
            {
                "target": target,
                "buildSettings": cls.resource_settings(),
            }
            for target in sorted(verifier.RESOURCE_TARGETS)
        )
        return payload


if __name__ == "__main__":
    unittest.main()
