import Foundation
import Testing

@Suite struct GatewaySetupDeliveryOwnershipTests {
    @Test func rootOwnsSettingsDeliveryWhileVisibleOnboardingKeepsPriority() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/RootTabs.swift"),
            encoding: .utf8)
        let settings = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Design/SettingsProTab.swift"),
            encoding: .utf8)
        let settingsActions = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Design/SettingsProTabActions.swift"),
            encoding: .utf8)
        let onboarding = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Onboarding/OnboardingWizardView.swift"),
            encoding: .utf8)

        #expect(root.contains("guard !self.showOnboarding else { return }"))
        #expect(root.contains("self.appModel.consumePendingGatewaySetupLink()"))
        #expect(root.contains("GatewaySetupRequest(id: requestID, link: link)"))
        #expect(settings.contains("applyGatewaySetupRequestIfNeeded"))
        #expect(settings.contains("onGatewaySetupRequestHandled?(gatewaySetupRequest.id)"))
        #expect(!settings.contains("consumePendingGatewaySetupLink"))
        #expect(!settingsActions.contains("consumePendingGatewaySetupLink"))
        #expect(onboarding.contains("self.appModel.consumePendingGatewaySetupLink()"))
    }
}
