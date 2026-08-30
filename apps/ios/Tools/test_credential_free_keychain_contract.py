from __future__ import annotations

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
WORKFLOW = REPO_ROOT / ".github/workflows/ios-build-ipa.yml"
KEYCHAIN = (
    REPO_ROOT
    / "apps/shared/OpenClawKit/Sources/OpenClawKit/GenericPasswordKeychainStore.swift"
)
TLS_STORE = REPO_ROOT / "apps/shared/OpenClawKit/Sources/OpenClawKit/GatewayTLSPinning.swift"


class CredentialFreeKeychainContractTests(unittest.TestCase):
    def test_only_simulator_test_steps_enable_the_credential_free_backend(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        steps = re.findall(
            r"      - name: (?:Run iOS tests|Run focused iOS reliability tests)\n"
            r"(?P<body>.*?)(?=\n      - name:)",
            workflow,
            re.DOTALL,
        )
        self.assertEqual(len(steps), 2)
        for step in steps:
            with self.subTest(step=step[:80]):
                self.assertRegex(step, r"\bxcodebuild\s+\\")
                self.assertIn('-destination "platform=iOS Simulator,', step)
                self.assertIn("-parallel-testing-enabled NO", step)
                self.assertIn("AIES_CREDENTIAL_FREE_TEST_KEYCHAIN", step)
                test_action = step.index("\n            test \\")
                test_backend = step.index("AIES_CREDENTIAL_FREE_TEST_KEYCHAIN")
                self.assertLess(test_action, test_backend)
                self.assertIn("CODE_SIGNING_ALLOWED=NO", step)
                self.assertIn("CODE_SIGNING_REQUIRED=NO", step)
                self.assertIn('CODE_SIGN_IDENTITY=""', step)
                self.assertIn('DEVELOPMENT_TEAM=""', step)
        self.assertEqual(workflow.count("AIES_CREDENTIAL_FREE_TEST_KEYCHAIN"), 2)

        workflow_steps = re.findall(
            r"      - name: (?P<name>[^\n]+)\n(?P<body>.*?)(?=\n      - name:|\n  [a-zA-Z0-9_-]+:|\Z)",
            workflow,
            re.DOTALL,
        )
        flagged_steps = [name for name, body in workflow_steps
                         if "AIES_CREDENTIAL_FREE_TEST_KEYCHAIN" in body]
        self.assertEqual(
            flagged_steps,
            ["Run iOS tests", "Run focused iOS reliability tests"],
        )

    def test_backend_is_compile_time_only_and_archive_uses_real_keychain(self) -> None:
        keychain = KEYCHAIN.read_text(encoding="utf-8")
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("#if AIES_CREDENTIAL_FREE_TEST_KEYCHAIN", keychain)
        self.assertIn("private static let credentialFreeTestItems", keychain)
        self.assertIn("SecItemCopyMatching", keychain)
        self.assertIn("SecItemAdd", keychain)
        self.assertIn("SecItemDelete", keychain)

        unsigned_archive = workflow.split("      - name: Archive iOS app\n", maxsplit=1)[1]
        unsigned_archive = unsigned_archive.split("      - name: Package archive", maxsplit=1)[0]
        self.assertNotIn("AIES_CREDENTIAL_FREE_TEST_KEYCHAIN", unsigned_archive)

    def test_service_wide_tls_deletion_uses_the_shared_backend_boundary(self) -> None:
        keychain = KEYCHAIN.read_text(encoding="utf-8")
        tls_store = TLS_STORE.read_text(encoding="utf-8")
        self.assertIn("public static func deleteAll(service: String) -> Bool", keychain)
        self.assertIn(
            "GenericPasswordKeychainStore.deleteAll(service: self.keychainService)",
            tls_store,
        )
        self.assertNotIn("SecItemDelete([", tls_store)


if __name__ == "__main__":
    unittest.main()
