from __future__ import annotations

import json
import pathlib
import plistlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
TEAM_ID = "J76B47MZ6V"
MAIN_ID = "ai.openclaw.client"
BUNDLE_IDS = (
    MAIN_ID,
    f"{MAIN_ID}.share",
    f"{MAIN_ID}.activitywidget",
    f"{MAIN_ID}.watchkitapp",
    f"{MAIN_ID}.watchkitapp.extension",
)


class AIESOldIdentityContinuityTests(unittest.TestCase):
    def test_release_preparation_pins_exact_old_topology_and_team(self) -> None:
        script = (REPO_ROOT / "scripts/ios-beta-prepare.sh").read_text(
            encoding="utf-8"
        )
        expected = {
            "OPENCLAW_APP_BUNDLE_ID": BUNDLE_IDS[0],
            "OPENCLAW_SHARE_BUNDLE_ID": BUNDLE_IDS[1],
            "OPENCLAW_ACTIVITY_WIDGET_BUNDLE_ID": BUNDLE_IDS[2],
            "OPENCLAW_WATCH_APP_BUNDLE_ID": BUNDLE_IDS[3],
            "OPENCLAW_WATCH_EXTENSION_BUNDLE_ID": BUNDLE_IDS[4],
        }
        for variable, value in expected.items():
            with self.subTest(variable=variable):
                self.assertEqual(script.count(f"{variable} = {value}"), 1)
        self.assertIn(f'AIES_CONTINUITY_TEAM_ID="{TEAM_ID}"', script)
        self.assertIn(
            '[[ "${TEAM_ID}" != "${AIES_CONTINUITY_TEAM_ID}" ]]', script
        )
        self.assertNotIn("ai.openclaw.client.J76B47MZ6V", script)

    def test_live_release_contract_uses_old_identity_without_weakening_policy(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/ios-build-ipa.yml").read_text(
            encoding="utf-8"
        )
        fastfile = (REPO_ROOT / "apps/ios/fastlane/Fastfile").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("ai.openclaw.client.J76B47MZ6V", workflow)
        self.assertIn('[[ "${APP_BUNDLE_ID_VALUE}" == "ai.openclaw.client" ]]', workflow)
        self.assertIn('[[ "${APPLE_TEAM_ID_VALUE}" == "J76B47MZ6V" ]]', workflow)
        self.assertIn("confirm_internal_only", workflow)
        self.assertIn("-parallel-testing-enabled NO", workflow)
        self.assertIn("-only-testing:OpenClawTests/GatewaySettingsStoreTests", workflow)
        self.assertIn("testFlightInternalTestingOnly", fastfile)
        self.assertIn('BETA_APP_IDENTIFIER = "ai.openclaw.client"', fastfile)
        self.assertIn(f'AIES_CONTINUITY_TEAM_ID = "{TEAM_ID}"', fastfile)
        self.assertIn("unless team_id == AIES_CONTINUITY_TEAM_ID", fastfile)
        self.assertNotIn("ai.openclaw.client.J76B47MZ6V", fastfile)

    def test_generated_project_keeps_five_target_containment_parameterized(self) -> None:
        project = (REPO_ROOT / "apps/ios/project.yml").read_text(encoding="utf-8")
        expected_variables = (
            "$(OPENCLAW_APP_BUNDLE_ID)",
            "$(OPENCLAW_SHARE_BUNDLE_ID)",
            "$(OPENCLAW_ACTIVITY_WIDGET_BUNDLE_ID)",
            "$(OPENCLAW_WATCH_APP_BUNDLE_ID)",
            "$(OPENCLAW_WATCH_EXTENSION_BUNDLE_ID)",
        )
        for variable in expected_variables:
            with self.subTest(variable=variable):
                self.assertIn(variable, project)
        self.assertIn(
            'WKCompanionAppBundleIdentifier: "$(OPENCLAW_APP_BUNDLE_ID)"', project
        )
        self.assertIn(
            'WKAppBundleIdentifier: "$(OPENCLAW_WATCH_APP_BUNDLE_ID)"', project
        )

    def test_default_keychain_domain_and_container_paths_are_continuity_safe(self) -> None:
        keychain = (
            REPO_ROOT
            / "apps/shared/OpenClawKit/Sources/OpenClawKit/GenericPasswordKeychainStore.swift"
        ).read_text(encoding="utf-8")
        settings = (
            REPO_ROOT / "apps/ios/Sources/Gateway/GatewaySettingsStore.swift"
        ).read_text(encoding="utf-8")
        tls = (
            REPO_ROOT
            / "apps/shared/OpenClawKit/Sources/OpenClawKit/GatewayTLSPinning.swift"
        ).read_text(encoding="utf-8")
        identity = (
            REPO_ROOT
            / "apps/shared/OpenClawKit/Sources/OpenClawKit/DeviceIdentity.swift"
        ).read_text(encoding="utf-8")
        device_auth = (
            REPO_ROOT
            / "apps/shared/OpenClawKit/Sources/OpenClawKit/DeviceAuthStore.swift"
        ).read_text(encoding="utf-8")
        outbox = (
            REPO_ROOT
            / "apps/shared/OpenClawKit/Sources/OpenClawChatUI/OpenClawChatOutboxStorage.swift"
        ).read_text(encoding="utf-8")

        self.assertNotIn("kSecAttrAccessGroup", keychain)
        self.assertIn('"ai.openclaw.gateway"', settings)
        self.assertIn('"ai.openclaw.node"', settings)
        self.assertIn('"ai.openclaw.tls-pinning"', tls)
        self.assertIn(".applicationSupportDirectory", identity)
        self.assertIn('appendingPathComponent("OpenClaw"', identity)
        self.assertIn('private static let fileName = "device.json"', identity)
        self.assertIn('private static let fileName = "device-auth.json"', device_auth)
        self.assertIn('databaseFilename = "openclaw-chat-outbox.sqlite"', outbox)

    def test_entitlements_do_not_invent_keychain_or_app_groups(self) -> None:
        entitlements_path = REPO_ROOT / "apps/ios/Sources/OpenClaw.entitlements"
        entitlements = plistlib.loads(entitlements_path.read_bytes())
        self.assertEqual(set(entitlements), {"aps-environment"})
        self.assertNotIn("keychain-access-groups", entitlements)
        self.assertNotIn("com.apple.security.application-groups", entitlements)

    def test_apns_launch_and_failure_paths_preserve_pairing_contract(self) -> None:
        app_delegate = (REPO_ROOT / "apps/ios/Sources/OpenClawApp.swift").read_text(
            encoding="utf-8"
        )
        model = (REPO_ROOT / "apps/ios/Sources/Model/NodeAppModel.swift").read_text(
            encoding="utf-8"
        )
        launch = app_delegate.split("didFinishLaunchingWithOptions", maxsplit=1)[1].split(
            "didRegisterForRemoteNotificationsWithDeviceToken", maxsplit=1
        )[0]
        registration = model.split(
            "private func registerAPNsTokenIfNeeded() async", maxsplit=1
        )[1].split("private func fetchPushRelayGatewayIdentity", maxsplit=1)[0]
        ios_continuity_tests = (
            REPO_ROOT / "apps/ios/Tests/GatewaySettingsStoreTests.swift"
        ).read_text(encoding="utf-8")
        gateway_event_tests = (
            REPO_ROOT / "src/gateway/server-node-events.test.ts"
        ).read_text(encoding="utf-8")
        self.assertEqual(launch.count("application.registerForRemoteNotifications()"), 1)
        self.assertIn('sendEvent(event: "push.apns.register"', registration)
        self.assertNotIn("DeviceAuthStore.clear", registration)
        self.assertNotIn("deleteGatewayCredentials", registration)
        self.assertNotIn("securePurge", registration)
        self.assertIn(
            "productionDirectRegistrationUsesOldTopicAndKeepsPairing",
            ios_continuity_tests,
        )
        self.assertIn(
            "@Test @MainActor func "
            "sameIdentityUpdateReadsHistoricalGatewayStateWithoutRewrite",
            ios_continuity_tests,
        )
        self.assertIn('"OpenClawPushTransport": "direct"', ios_continuity_tests)
        self.assertIn('"OpenClawPushDistribution": "local"', ios_continuity_tests)
        self.assertIn('"OpenClawPushAPNsEnvironment": "production"', ios_continuity_tests)
        self.assertIn('decoded["topic"] as? String == "ai.openclaw.client"', ios_continuity_tests)
        self.assertIn(
            "keeps the authenticated pairing intact when APNs registration fails",
            gateway_event_tests,
        )

    def test_build_72_replay_evidence_remains_bound_to_its_long_identity(self) -> None:
        fixture_path = (
            REPO_ROOT
            / "apps/ios/Tools/fixtures/aies_export_boundary_run_33188911517.json"
        )
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        historical = "ai.openclaw.client.J76B47MZ6V"
        self.assertEqual(fixture["expected_main_bundle_id"], historical)
        replay = (
            REPO_ROOT
            / ".github/workflows/ios-post-export-verifier-qualification.yml"
        ).read_text(encoding="utf-8")
        self.assertIn(historical, replay)


if __name__ == "__main__":
    unittest.main()
