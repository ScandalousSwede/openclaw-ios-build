from __future__ import annotations

import copy
import json
import pathlib
import tempfile
import unittest
import unittest.mock

import verify_aies_development_identity_reuse as verifier


TEAM_ID = "J76B47MZ6V"
CERTIFICATE_SHA256 = "a" * 64
MAIN_BUNDLE_ID = "ai.openclaw.client.J76B47MZ6V"


def signing_identity() -> dict[str, object]:
    return {
        "leaf_certificate_sha256": CERTIFICATE_SHA256,
        "leaf_common_name": "Apple Development: AIES CI (J76B47MZ6V)",
        "team_identifier": TEAM_ID,
        "trust_verified": True,
    }


def report() -> dict[str, object]:
    bundle_paths = {
        MAIN_BUNDLE_ID: "OpenClaw.app",
        f"{MAIN_BUNDLE_ID}.share": "OpenClaw.app/PlugIns/OpenClawShareExtension.appex",
        f"{MAIN_BUNDLE_ID}.activitywidget": (
            "OpenClaw.app/PlugIns/OpenClawActivityWidget.appex"
        ),
        f"{MAIN_BUNDLE_ID}.watchkitapp": "OpenClaw.app/Watch/OpenClawWatchApp.app",
        f"{MAIN_BUNDLE_ID}.watchkitapp.extension": (
            "OpenClaw.app/Watch/OpenClawWatchApp.app/PlugIns/"
            "OpenClawWatchExtension.appex"
        ),
    }
    return {
        "status": "archive_integrity_verified",
        "expected_team_id": TEAM_ID,
        "archive": {
            "verification_stage": "archive_integrity",
            "bundles": [
                {
                    "bundle_id": bundle_id,
                    "relative_path": bundle_path,
                    "team_identifier": TEAM_ID,
                    "application_identifier": f"{TEAM_ID}.{bundle_id}",
                    "get_task_allow": True,
                    "aps_environment": (
                        "development" if bundle_id == MAIN_BUNDLE_ID else None
                    ),
                    "signing_identity": signing_identity(),
                    "profile": {
                        "uuid": f"profile-{index}",
                        "name": f"AIES fixture profile {index}",
                        "profile_type": "development",
                        "application_identifier": f"{TEAM_ID}.{bundle_id}",
                        "get_task_allow": True,
                        "aps_environment": (
                            "development" if bundle_id == MAIN_BUNDLE_ID else None
                        ),
                        "provisioned_device_count": 1,
                        "provisions_all_devices": False,
                        "expiration_at": "2099-01-01T00:00:00Z",
                        "developer_certificate_sha256": [CERTIFICATE_SHA256],
                        "team_identifiers": [TEAM_ID],
                    },
                }
                for index, (bundle_id, bundle_path) in enumerate(bundle_paths.items())
            ],
            "auxiliary_code_objects": [
                {
                    "bundle_id": "org.webrtc.WebRTC",
                    "kind": "embedded_dynamic_framework",
                    "executable_relative_path": "Frameworks/WebRTC.framework/WebRTC",
                    "profile": None,
                    "profile_requirement": "not_applicable_embedded_framework",
                    "signing_identity": signing_identity(),
                }
            ],
        },
    }


class DevelopmentIdentityReuseTests(unittest.TestCase):
    def test_accepts_exact_identity_for_all_five_profiles_and_auxiliary_code(self) -> None:
        receipt = verifier.verify_report(
            report(),
            expected_sha256=CERTIFICATE_SHA256,
            expected_team_id=TEAM_ID,
            expected_main_bundle_id=MAIN_BUNDLE_ID,
        )
        self.assertEqual(receipt["status"], "reusable_development_identity_verified")
        self.assertEqual(receipt["bundle_count"], 5)
        self.assertEqual(len(receipt["profiles"]), 5)
        self.assertEqual(receipt["auxiliary_code_object_count"], 1)

    def test_rejects_wrong_leaf_missing_profile_binding_and_partial_coverage(self) -> None:
        cases: list[dict[str, object]] = []

        wrong_leaf = copy.deepcopy(report())
        wrong_leaf["archive"]["bundles"][0]["signing_identity"][
            "leaf_certificate_sha256"
        ] = "b" * 64
        cases.append(wrong_leaf)

        missing_binding = copy.deepcopy(report())
        missing_binding["archive"]["bundles"][0]["profile"][
            "developer_certificate_sha256"
        ] = []
        cases.append(missing_binding)

        partial = copy.deepcopy(report())
        partial["archive"]["bundles"].pop()
        cases.append(partial)

        auxiliary_mismatch = copy.deepcopy(report())
        auxiliary_mismatch["archive"]["auxiliary_code_objects"][0][
            "signing_identity"
        ]["leaf_certificate_sha256"] = "c" * 64
        cases.append(auxiliary_mismatch)

        ambiguous_team = copy.deepcopy(report())
        ambiguous_team["archive"]["bundles"][0]["profile"]["team_identifiers"] = [
            TEAM_ID,
            "AAAAAAAAAA",
        ]
        cases.append(ambiguous_team)

        expired_profile = copy.deepcopy(report())
        expired_profile["archive"]["bundles"][0]["profile"][
            "expiration_at"
        ] = "2020-01-01T00:00:00Z"
        cases.append(expired_profile)

        distribution_leaf = copy.deepcopy(report())
        distribution_leaf["archive"]["bundles"][0]["signing_identity"][
            "leaf_common_name"
        ] = "Apple Distribution: AIES CI (J76B47MZ6V)"
        cases.append(distribution_leaf)

        boolean_device_count = copy.deepcopy(report())
        boolean_device_count["archive"]["bundles"][0]["profile"][
            "provisioned_device_count"
        ] = True
        cases.append(boolean_device_count)

        for candidate in cases:
            with self.subTest(candidate=candidate):
                with self.assertRaises(verifier.VerificationError):
                    verifier.verify_report(
                        candidate,
                        expected_sha256=CERTIFICATE_SHA256,
                        expected_team_id=TEAM_ID,
                        expected_main_bundle_id=MAIN_BUNDLE_ID,
                    )

    def test_cli_writes_deterministic_nonsecret_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            source = temp / "archive.json"
            output = temp / "receipt.json"
            source.write_text(json.dumps(report()), encoding="utf-8")
            with unittest.mock.patch(
                "sys.argv",
                [
                    "verify_aies_development_identity_reuse.py",
                    "--archive-signing-report",
                    str(source),
                    "--expected-certificate-sha256",
                    CERTIFICATE_SHA256,
                    "--expected-team-id",
                    TEAM_ID,
                    "--expected-main-bundle-id",
                    MAIN_BUNDLE_ID,
                    "--output",
                    str(output),
                ],
            ):
                self.assertEqual(verifier.main(), 0)
            first = output.read_bytes()
            with unittest.mock.patch(
                "sys.argv",
                [
                    "verify_aies_development_identity_reuse.py",
                    "--archive-signing-report",
                    str(source),
                    "--expected-certificate-sha256",
                    CERTIFICATE_SHA256,
                    "--expected-team-id",
                    TEAM_ID,
                    "--expected-main-bundle-id",
                    MAIN_BUNDLE_ID,
                    "--output",
                    str(output),
                ],
            ):
                self.assertEqual(verifier.main(), 0)
            self.assertEqual(output.read_bytes(), first)
            self.assertNotIn(b"private", first.lower())


if __name__ == "__main__":
    unittest.main()
