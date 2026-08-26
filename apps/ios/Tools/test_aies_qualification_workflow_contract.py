from __future__ import annotations

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
QUALIFICATION = REPO_ROOT / ".github/workflows/ios-rc1-risk-stratified-qualification.yml"
RELEASE = REPO_ROOT / ".github/workflows/ios-build-ipa.yml"


class AIESQualificationWorkflowContractTests(unittest.TestCase):
    def test_qualification_trigger_and_permissions_are_narrow(self) -> None:
        workflow = QUALIFICATION.read_text(encoding="utf-8")
        trigger = workflow.split("permissions:\n", maxsplit=1)[0]
        self.assertIn("  push:\n", trigger)
        self.assertIn("      - aies/ios-rc1-aggregate-package-authority\n", trigger)
        self.assertNotIn("workflow_dispatch", trigger)
        self.assertEqual(trigger.count("      - aies/ios-rc1-aggregate-package-authority"), 1)
        self.assertIn("permissions:\n  contents: read\n", workflow)
        self.assertNotIn("environment:", workflow)
        self.assertNotIn("secrets.", workflow)

    def test_qualification_is_credential_free_unsigned_and_nonrelease(self) -> None:
        workflow = QUALIFICATION.read_text(encoding="utf-8")
        forbidden = (
            "ASC_PRIVATE_KEY",
            "ASC_KEY_ID",
            "ASC_ISSUER_ID",
            "APNS",
            "-allowProvisioningUpdates",
            "-authenticationKeyPath",
            "-exportArchive",
            "fastlane ios",
            "pilot",
            "upload_to_testflight",
            "app_store_connect",
            "xcodebuild archive",
        )
        for token in forbidden:
            with self.subTest(token=token):
                self.assertNotIn(token, workflow)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", workflow)
        self.assertIn("CODE_SIGNING_REQUIRED=NO", workflow)
        self.assertIn('"CODE_SIGN_IDENTITY="', workflow)
        self.assertIn('"DEVELOPMENT_TEAM="', workflow)
        self.assertNotIn("uses: ruby/setup-ruby", workflow)

    def test_actions_are_pinned_and_checkout_does_not_persist_credentials(self) -> None:
        workflow = QUALIFICATION.read_text(encoding="utf-8")
        third_party = re.findall(
            r"^\s*uses:\s*([^./\s][^@\s]+)@([^\s#]+)", workflow, re.MULTILINE
        )
        self.assertTrue(third_party)
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{40}", ref) for _, ref in third_party))
        self.assertEqual(workflow.count("uses: actions/checkout@"), 3)
        self.assertEqual(workflow.count("persist-credentials: false"), 3)

    def test_exact_risk_stratified_counts_and_shared_preparation_are_present(self) -> None:
        qualification = QUALIFICATION.read_text(encoding="utf-8")
        release = RELEASE.read_text(encoding="utf-8")
        self.assertEqual(qualification.count("--count 40 --expected-test-count 1"), 2)
        self.assertIn("--only-testing \"${filter}\" --count 40", qualification)
        self.assertIn("--count 10 --expected-test-count 43", qualification)
        self.assertIn("--filter ChatViewModelTests --count 10", qualification)
        self.assertIn("compactTargetTotal", qualification)
        self.assertEqual(
            release.count("prepare_aies_package_build_root.py prepare"), 2
        )
        self.assertIn("signed-internal-testflight", release)
        self.assertIn("aies-testflight-internal", release)
        self.assertIn("AIES_TESTFLIGHT_INTERNAL_ENABLED", release)


if __name__ == "__main__":
    unittest.main()
