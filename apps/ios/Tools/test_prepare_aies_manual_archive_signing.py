from __future__ import annotations

import copy
import datetime as dt
import json
import pathlib
import tempfile
import unittest
import unittest.mock

import prepare_aies_manual_archive_signing as signing


CERTIFICATE_SHA256 = "a" * 64
NOW = dt.datetime(2026, 9, 4, tzinfo=dt.timezone.utc)


def profile_import_receipt() -> dict[str, object]:
    profiles = []
    for index, target in enumerate(reversed(signing.EXPECTED_TARGETS)):
        profiles.append(
            {
                "apple_resource_id": f"PROFILE-RESOURCE-{index}",
                "aps_environment": target["aps_environment"],
                "application_identifier": (
                    f"{signing.TEAM_ID}.{target['bundle_id']}"
                ),
                "bundle_id": target["bundle_id"],
                "bundle_resource_id": f"BUNDLE-RESOURCE-{index}",
                "developer_certificate_sha256": [CERTIFICATE_SHA256],
                "get_task_allow": True,
                "profile_expiration_at": "2027-09-03T21:12:13Z",
                "profile_name": f"AIES manual development {index}",
                "profile_state": "ACTIVE",
                "profile_type": "IOS_APP_DEVELOPMENT",
                "profile_uuid": target["profile_uuid"],
                "provisioned_device_count": 1,
                "source_sha256": f"{index + 1:064x}",
                "target": target["logical_target"],
                "xcode_managed": False,
            }
        )
    return {
        "archive_allows_provisioning_updates": False,
        "archive_receives_apple_authentication_arguments": False,
        "certificate_sha256": CERTIFICATE_SHA256,
        "profile_count": 5,
        "profiles": profiles,
        "schema": "aies.apple-development-profile-import.v1",
        "source_operation": "read_only_apple_profile_fetch",
        "spaceship_minimum_log_level": "WARN",
        "spaceship_request_clients": [
            "provisioning_request_client",
            "test_flight_request_client",
            "tunes_request_client",
            "users_request_client",
        ],
        "spaceship_response_body_logging_suppressed": True,
        "status": "five_governed_profiles_installed_for_offline_archive",
        "team_id": signing.TEAM_ID,
    }


class Fixture:
    def __init__(self, root: pathlib.Path, receipt: object | None = None) -> None:
        self.root = root
        self.base = root / "generated" / "BetaRelease.xcconfig"
        self.profile_receipt = (
            root / "release" / "OpenClaw-development-profile-import.json"
        )
        self.overlay = root / "archive" / "AIESManualArchiveSigning.xcconfig"
        self.output_receipt = root / "release" / "OpenClaw-manual-archive-signing.json"
        self.base.parent.mkdir(parents=True)
        self.profile_receipt.parent.mkdir(parents=True)
        self.base.write_text(
            "OPENCLAW_APP_BUNDLE_ID = ai.openclaw.client.J76B47MZ6V\n",
            encoding="utf-8",
        )
        self.profile_receipt.write_text(
            json.dumps(profile_import_receipt() if receipt is None else receipt),
            encoding="utf-8",
        )

    def prepare(self) -> dict[str, object]:
        return signing.prepare_manual_archive_signing(
            policy_path=signing.DEFAULT_POLICY_PATH,
            profile_import_receipt_path=self.profile_receipt,
            base_xcconfig_path=self.base,
            output_xcconfig_path=self.overlay,
            output_receipt_path=self.output_receipt,
            allowed_output_root=self.root,
            expected_certificate_sha256=CERTIFICATE_SHA256,
            now=NOW,
        )


class ManualArchiveSigningPreparationTests(unittest.TestCase):
    def test_generates_exact_target_scoped_overlay_and_sanitized_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            fixture = Fixture(pathlib.Path(raw_temp))
            receipt = fixture.prepare()

            expected_lines = [
                '#include "../generated/BetaRelease.xcconfig"',
                "OPENCLAW_CODE_SIGN_STYLE = Manual",
                f"OPENCLAW_DEVELOPMENT_TEAM = {signing.TEAM_ID}",
                *[
                    f"{target['xcconfig_variable']} = {target['profile_uuid']}"
                    for target in signing.EXPECTED_TARGETS
                ],
            ]
            actual_lines = fixture.overlay.read_text(encoding="utf-8").splitlines()
            self.assertEqual(actual_lines, expected_lines)
            self.assertTrue(
                all(line.startswith("OPENCLAW_") for line in actual_lines[1:])
            )
            self.assertFalse(
                any(
                    line.startswith(
                        (
                            "CODE_SIGN_IDENTITY =",
                            "CODE_SIGN_STYLE =",
                            "DEVELOPMENT_TEAM =",
                            "PROVISIONING_PROFILE =",
                            "PROVISIONING_PROFILE_SPECIFIER =",
                        )
                    )
                    for line in actual_lines
                )
            )
            self.assertEqual(
                receipt["status"], "manual_archive_signing_overlay_verified"
            )
            self.assertEqual(receipt["code_sign_style"], "Manual")
            self.assertEqual(receipt["code_sign_identity"], "Apple Development")
            self.assertEqual(receipt["profile_count"], 5)
            self.assertTrue(
                receipt["base_xcconfig_global_signing_overrides_absent"]
            )
            self.assertEqual(
                [
                    (item["bundle_id"], item["profile_uuid"])
                    for item in receipt["targets"]
                ],
                [
                    (target["bundle_id"], target["profile_uuid"])
                    for target in signing.EXPECTED_TARGETS
                ],
            )
            raw_receipt = fixture.output_receipt.read_text(encoding="utf-8")
            self.assertNotIn(raw_temp, raw_receipt)
            self.assertNotIn("private", raw_receipt.lower())

    def test_outputs_are_byte_deterministic_for_equivalent_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            first = Fixture(root / "first")
            second = Fixture(root / "second")
            first_receipt = first.prepare()
            second_receipt = second.prepare()
            self.assertEqual(first.overlay.read_bytes(), second.overlay.read_bytes())
            self.assertEqual(
                first.output_receipt.read_bytes(), second.output_receipt.read_bytes()
            )
            self.assertEqual(first_receipt, second_receipt)

    def test_policy_is_exact_and_cannot_remap_a_profile(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            policy = json.loads(signing.DEFAULT_POLICY_PATH.read_text(encoding="utf-8"))
            policy["targets"][0]["profile_uuid"] = policy["targets"][1]["profile_uuid"]
            path = root / "policy.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            with self.assertRaisesRegex(
                signing.SigningPreparationError, "not authorized"
            ):
                signing.load_policy(path)

    def test_policy_rejects_unknown_fields(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            policy = json.loads(signing.DEFAULT_POLICY_PATH.read_text(encoding="utf-8"))
            policy["fallback_profile"] = "anything"
            path = root / "policy.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            with self.assertRaisesRegex(
                signing.SigningPreparationError, "fields are invalid"
            ):
                signing.load_policy(path)

    def _assert_receipt_rejected(
        self, receipt: object, pattern: str | None = None
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            fixture = Fixture(pathlib.Path(raw_temp), receipt)
            context = self.assertRaises(signing.SigningPreparationError)
            with context:
                fixture.prepare()
            if pattern is not None:
                self.assertRegex(str(context.exception), pattern)
            self.assertFalse(fixture.overlay.exists())
            self.assertFalse(fixture.output_receipt.exists())

    def test_rejects_missing_extra_duplicate_and_swapped_profiles(self) -> None:
        cases: list[tuple[str, dict[str, object]]] = []

        missing = profile_import_receipt()
        missing["profiles"].pop()
        missing["profile_count"] = 4
        cases.append(("missing", missing))

        extra = profile_import_receipt()
        extra["profiles"].append(copy.deepcopy(extra["profiles"][0]))
        extra["profile_count"] = 6
        cases.append(("extra", extra))

        duplicate = profile_import_receipt()
        duplicate["profiles"][1] = copy.deepcopy(duplicate["profiles"][0])
        cases.append(("duplicate", duplicate))

        swapped = profile_import_receipt()
        first_uuid = swapped["profiles"][0]["profile_uuid"]
        swapped["profiles"][0]["profile_uuid"] = swapped["profiles"][1]["profile_uuid"]
        swapped["profiles"][1]["profile_uuid"] = first_uuid
        cases.append(("swapped", swapped))

        for name, candidate in cases:
            with self.subTest(name=name):
                self._assert_receipt_rejected(candidate)

    def test_rejects_expired_wrong_team_bundle_certificate_and_aps(self) -> None:
        cases: list[tuple[str, dict[str, object]]] = []

        expired = profile_import_receipt()
        expired["profiles"][0]["profile_expiration_at"] = "2025-01-01T00:00:00Z"
        cases.append(("expired", expired))

        wrong_team = profile_import_receipt()
        wrong_team["team_id"] = "AAAAAAAAAA"
        cases.append(("wrong_team", wrong_team))

        wrong_bundle = profile_import_receipt()
        wrong_bundle["profiles"][0]["bundle_id"] = "ai.openclaw.wrong"
        cases.append(("wrong_bundle", wrong_bundle))

        wrong_certificate = profile_import_receipt()
        wrong_certificate["profiles"][0]["developer_certificate_sha256"] = ["b" * 64]
        cases.append(("wrong_certificate", wrong_certificate))

        wrong_aps = profile_import_receipt()
        main = next(
            profile
            for profile in wrong_aps["profiles"]
            if profile["target"] == "main"
        )
        main["aps_environment"] = None
        cases.append(("wrong_aps", wrong_aps))

        unexpected_aps = profile_import_receipt()
        extension = next(
            profile
            for profile in unexpected_aps["profiles"]
            if profile["target"] == "share"
        )
        extension["aps_environment"] = "development"
        cases.append(("unexpected_aps", unexpected_aps))

        for name, candidate in cases:
            with self.subTest(name=name):
                self._assert_receipt_rejected(candidate)

    def test_rejects_wrong_application_identity_state_type_and_management(self) -> None:
        mutations = {
            "application_identifier": "AAAAAAAAAA.ai.openclaw.client.J76B47MZ6V",
            "profile_state": "INVALID",
            "profile_type": "IOS_APP_STORE",
            "get_task_allow": False,
            "provisioned_device_count": 0,
            "xcode_managed": True,
        }
        for field, replacement in mutations.items():
            with self.subTest(field=field):
                candidate = profile_import_receipt()
                candidate["profiles"][0][field] = replacement
                self._assert_receipt_rejected(candidate)

    def test_rejects_malformed_receipts_and_profile_identifiers(self) -> None:
        cases: list[object] = [[], {"schema": "wrong"}]
        malformed_uuid = profile_import_receipt()
        malformed_uuid["profiles"][0]["profile_uuid"] = "not-a-uuid"
        cases.append(malformed_uuid)
        malformed_hash = profile_import_receipt()
        malformed_hash["profiles"][0]["source_sha256"] = "short"
        cases.append(malformed_hash)
        unexpected_field = profile_import_receipt()
        unexpected_field["profiles"][0]["private_material"] = "forbidden"
        cases.append(unexpected_field)
        boolean_device_count = profile_import_receipt()
        boolean_device_count["profiles"][0]["provisioned_device_count"] = True
        cases.append(boolean_device_count)
        for index, candidate in enumerate(cases):
            with self.subTest(index=index):
                self._assert_receipt_rejected(candidate)

    def test_output_root_is_scoped_but_verified_inputs_may_be_external(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            allowed = root / "allowed"
            allowed.mkdir()
            fixture = Fixture(allowed)
            with self.assertRaisesRegex(
                signing.SigningPreparationError, "allowed output root"
            ):
                signing.prepare_manual_archive_signing(
                    policy_path=signing.DEFAULT_POLICY_PATH,
                    profile_import_receipt_path=fixture.profile_receipt,
                    base_xcconfig_path=fixture.base,
                    output_xcconfig_path=root / "escaped.xcconfig",
                    output_receipt_path=fixture.output_receipt,
                    allowed_output_root=allowed,
                    expected_certificate_sha256=CERTIFICATE_SHA256,
                    now=NOW,
                )

            external_base = root / "External.xcconfig"
            external_base.write_text("SETTING = value\n", encoding="utf-8")
            receipt = signing.prepare_manual_archive_signing(
                policy_path=signing.DEFAULT_POLICY_PATH,
                profile_import_receipt_path=fixture.profile_receipt,
                base_xcconfig_path=external_base,
                output_xcconfig_path=fixture.overlay,
                output_receipt_path=fixture.output_receipt,
                allowed_output_root=allowed,
                expected_certificate_sha256=CERTIFICATE_SHA256,
                now=NOW,
            )
            self.assertEqual(
                receipt["status"], "manual_archive_signing_overlay_verified"
            )

    def test_refuses_to_overwrite_any_output(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            fixture = Fixture(pathlib.Path(raw_temp))
            fixture.overlay.parent.mkdir(parents=True)
            fixture.overlay.write_text("untrusted\n", encoding="utf-8")
            with self.assertRaisesRegex(
                signing.SigningPreparationError, "must not already exist"
            ):
                fixture.prepare()
            self.assertEqual(fixture.overlay.read_text(encoding="utf-8"), "untrusted\n")

    def test_rejects_global_signing_assignments_or_nested_includes_in_base(self) -> None:
        cases = (
            "CODE_SIGN_STYLE = Manual\n",
            " CODE_SIGN_IDENTITY[sdk=iphoneos*] = Apple Development\n",
            "DEVELOPMENT_TEAM = J76B47MZ6V\n",
            "PROVISIONING_PROFILE = legacy\n",
            "PROVISIONING_PROFILE_SPECIFIER = global\n",
            '#include "Other.xcconfig"\n',
            '#include? "Optional.xcconfig"\n',
        )
        for content in cases:
            with self.subTest(content=content.strip()):
                with tempfile.TemporaryDirectory() as raw_temp:
                    fixture = Fixture(pathlib.Path(raw_temp))
                    fixture.base.write_text(content, encoding="utf-8")
                    with self.assertRaises(signing.SigningPreparationError):
                        fixture.prepare()
                    self.assertFalse(fixture.overlay.exists())
                    self.assertFalse(fixture.output_receipt.exists())

    def test_cli_writes_the_verified_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            fixture = Fixture(pathlib.Path(raw_temp))
            with unittest.mock.patch(
                "sys.argv",
                [
                    "prepare_aies_manual_archive_signing.py",
                    "--profile-import-receipt",
                    str(fixture.profile_receipt),
                    "--base-xcconfig",
                    str(fixture.base),
                    "--output-xcconfig",
                    str(fixture.overlay),
                    "--output-receipt",
                    str(fixture.output_receipt),
                    "--allowed-output-root",
                    str(fixture.root),
                    "--expected-certificate-sha256",
                    CERTIFICATE_SHA256,
                ],
            ):
                self.assertEqual(signing.main(), 0)
            self.assertTrue(fixture.overlay.is_file())
            self.assertEqual(
                json.loads(fixture.output_receipt.read_text(encoding="utf-8"))[
                    "status"
                ],
                "manual_archive_signing_overlay_verified",
            )


if __name__ == "__main__":
    unittest.main()
