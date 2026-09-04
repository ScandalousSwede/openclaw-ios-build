from __future__ import annotations

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
QUALIFICATION = REPO_ROOT / ".github/workflows/ios-rc1-risk-stratified-qualification.yml"
RELEASE = REPO_ROOT / ".github/workflows/ios-build-ipa.yml"
PROJECT = REPO_ROOT / "apps/ios/project.yml"


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
        self.assertEqual(qualification.count('python3 "${runner}" enumerate'), 1)
        self.assertEqual(qualification.count('python3 "${runner}" narrow-enumeration'), 1)
        self.assertEqual(qualification.count("          narrow "), 4)
        self.assertIn('value.endswith("()")', qualification)
        self.assertEqual(
            qualification.count("--reset-simulator-before-each-run"), 2
        )
        self.assertNotIn("simctl erase", qualification)
        self.assertEqual(
            release.count("prepare_aies_package_build_root.py prepare"), 2
        )
        self.assertIn("signed-internal-testflight", release)
        self.assertIn("aies-testflight-internal", release)
        self.assertIn("AIES_TESTFLIGHT_INTERNAL_ENABLED", release)

    def test_release_workflow_verifies_exact_elevenlabskit_patch_and_tests(self) -> None:
        workflow = RELEASE.read_text(encoding="utf-8")
        step = workflow.split(
            "      - name: Verify immutable ElevenLabsKit observability and PCM integrity patch\n",
            maxsplit=1,
        )[1].split(
            "      - name: Install pinned credential-free release tooling\n",
            maxsplit=1,
        )[0]

        self.assertIn("https://github.com/ScandalousSwede/ElevenLabsKit.git", step)
        self.assertIn("0f1e4c039bd0e22b03c0cb7f43c00c1865858f0b", step)
        self.assertIn("3a8eeeb4938a2ec30c46f3a90762187b2ca40fa6", step)
        self.assertIn("44a108904cbb652a876bfdb838362746631b8987", step)
        self.assertIn("72003ce50bc475c2defba379f0a62184c3e86161", step)
        self.assertIn('git -C "${dependency_root}" diff --exit-code', step)
        self.assertIn('swift test --package-path "${dependency_root}"', step)
        self.assertIn("elevenlabskit-observability.patch", step)
        self.assertIn("source-checkout.json", step)
        self.assertIn("swift-test.log", step)
        self.assertIn("test-result.json", step)
        self.assertIn("SHA256SUMS", step)
        self.assertNotIn("secrets.", step)
        self.assertNotIn("--branch", step)
        self.assertEqual(
            workflow.count(
                "Retain ElevenLabsKit observability and PCM integrity patch evidence"
            ),
            1,
        )
        self.assertIn("if: always() && !cancelled()", workflow)
        self.assertEqual(workflow.count("--filter ElevenLabsTTSValidationTests"), 2)
        self.assertEqual(
            workflow.count("--filter ElevenLabsTTSResponseValidationTests"), 2
        )

    def test_package_talk_outputs_share_one_temporary_custody_root(self) -> None:
        workflow = QUALIFICATION.read_text(encoding="utf-8")
        self.assertIn(
            'runtime="${RUNNER_TEMP}/aies-package-talk-runtime"', workflow
        )
        self.assertIn('echo "AIES_RUNTIME=${runtime}"', workflow)
        self.assertIn('echo "AIES_EVIDENCE=${runtime}/evidence"', workflow)
        self.assertIn('echo "AIES_DERIVED_DATA=${runtime}/derived-data"', workflow)
        self.assertIn('runtime="${AIES_RUNTIME}"', workflow)
        self.assertIn('--allowed-root "${runtime}"', workflow)
        self.assertIn('--evidence-dir "${AIES_EVIDENCE}/package-final"', workflow)
        self.assertIn(
            "path: ${{ runner.temp }}/aies-package-talk-runtime/evidence", workflow
        )

    def test_scoped_ios_compile_uses_the_existing_source_lint_contract(self) -> None:
        workflow = QUALIFICATION.read_text(encoding="utf-8")
        release = RELEASE.read_text(encoding="utf-8")
        project = PROJECT.read_text(encoding="utf-8")
        package_talk = workflow.split(
            "  package-and-talk-qualification:\n", maxsplit=1
        )[1].split("  compact-bootstrap-qualification:\n", maxsplit=1)[0]
        compact_bootstrap = workflow.split(
            "  compact-bootstrap-qualification:\n", maxsplit=1
        )[1]
        build_step = package_talk.split(
            "      - name: Build Talk test products exactly once without signing\n",
            maxsplit=1,
        )[1].split(
            "      - name: Seal test-product identity and enumerate exact tests\n",
            maxsplit=1,
        )[0]
        self.assertIn(
            '        env:\n          OPENCLAW_SKIP_SOURCE_LINT: "YES"\n'
            "        shell: bash\n",
            build_step,
        )
        self.assertEqual(package_talk.count("OPENCLAW_SKIP_SOURCE_LINT"), 1)
        self.assertNotIn("OPENCLAW_SKIP_SOURCE_LINT", compact_bootstrap)
        self.assertEqual(workflow.count("OPENCLAW_SKIP_SOURCE_LINT"), 1)
        self.assertEqual(
            project.count('${OPENCLAW_SKIP_SOURCE_LINT:-NO}'), 2
        )
        self.assertEqual(release.count("OPENCLAW_SKIP_SOURCE_LINT"), 2)

    def test_unsigned_archive_uses_canonical_aies_identity_without_signing(self) -> None:
        workflow = RELEASE.read_text(encoding="utf-8")
        unsigned = workflow.split("  build:\n", maxsplit=1)[1].split(
            "  signed-internal-testflight:\n", maxsplit=1
        )[0]
        self.assertEqual(unsigned.count("scripts/ios-beta-prepare.sh"), 1)
        self.assertIn('--team-id J76B47MZ6V', unsigned)
        self.assertIn('--push-mode direct', unsigned)
        self.assertIn('build_number="${GITHUB_RUN_NUMBER}"', unsigned)
        self.assertIn(
            'beta_xcconfig="${AIES_BUILD_ROOT}/apps/ios/build/BetaRelease.xcconfig"',
            unsigned,
        )
        self.assertEqual(
            unsigned.count('XCODE_XCCONFIG_FILE="${AIES_UNSIGNED_XCCONFIG}"'), 4
        )
        self.assertIn("build_settings_topology_report", unsigned)
        signing_settings = unsigned.split(
            "      - name: Verify credential-free Release archive signing dispositions\n",
            maxsplit=1,
        )[1].split(
            "      - name: Build OpenClawKit and run S0-S3 reliability tests\n",
            maxsplit=1,
        )[0]
        self.assertIn("-configuration Release", signing_settings)
        self.assertIn("-showBuildSettings", signing_settings)
        self.assertNotIn("-showBuildSettingsForIndex", signing_settings)
        self.assertIn("archive-product-settings", signing_settings)
        self.assertEqual(signing_settings.count("capture_product_settings "), 5)
        self.assertIn("capture_product_settings OpenClaw iphoneos", signing_settings)
        self.assertIn(
            "capture_product_settings OpenClawShareExtension iphoneos",
            signing_settings,
        )
        self.assertIn(
            "capture_product_settings OpenClawActivityWidget iphoneos",
            signing_settings,
        )
        self.assertIn("capture_product_settings OpenClawWatchApp watchos", signing_settings)
        self.assertIn(
            "capture_product_settings OpenClawWatchExtension watchos",
            signing_settings,
        )
        self.assertEqual(signing_settings.count("--product-settings "), 5)
        self.assertEqual(signing_settings.count("              archive \\\n"), 1)
        self.assertIn("verify_aies_archive_signing_settings.py", signing_settings)
        self.assertIn("--expected-team-id J76B47MZ6V", signing_settings)
        self.assertNotIn("CODE_SIGN_IDENTITY=", signing_settings)
        self.assertNotIn("PROVISIONING_PROFILE=", signing_settings)
        self.assertNotIn("PROVISIONING_PROFILE_SPECIFIER=", signing_settings)
        self.assertNotIn("CODE_SIGNING_ALLOWED=", signing_settings)
        self.assertNotIn("CODE_SIGNING_REQUIRED=", signing_settings)
        self.assertEqual(unsigned.count("-configuration Release"), 1)
        self.assertGreaterEqual(unsigned.count("-configuration Debug"), 3)
        self.assertIn("OPENCLAW_BUILD_CONFIGURATION=Debug", unsigned)
        self.assertIn("--configuration Debug", unsigned)
        self.assertIn(
            "--archive /tmp/OpenClaw.xcarchive", unsigned
        )
        self.assertEqual(
            unsigned.count("verify_aies_archive_signing_settings.py"), 3
        )
        self.assertIn('"ai.openclaw.client.J76B47MZ6V"', unsigned)
        self.assertGreaterEqual(unsigned.count("CODE_SIGNING_ALLOWED=NO"), 3)
        self.assertGreaterEqual(unsigned.count("CODE_SIGNING_REQUIRED=NO"), 3)
        self.assertGreaterEqual(unsigned.count('CODE_SIGN_IDENTITY=""'), 3)
        self.assertGreaterEqual(unsigned.count('DEVELOPMENT_TEAM=""'), 3)
        self.assertNotIn("secrets.", unsigned)
        self.assertNotIn("environment:", unsigned)
        self.assertNotIn("-allowProvisioningUpdates", unsigned)
        self.assertNotIn("-authenticationKey", unsigned)


if __name__ == "__main__":
    unittest.main()
