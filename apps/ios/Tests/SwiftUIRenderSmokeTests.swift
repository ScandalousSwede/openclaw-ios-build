import OpenClawKit
import SwiftUI
import Testing
import UIKit
@testable import OpenClaw

@Suite(.serialized) struct SwiftUIRenderSmokeTests {
    @MainActor private static func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    @Test @MainActor func settingsProTabBuildsAViewHierarchy() {
        let appModel = NodeAppModel()
        let gatewayController = GatewayConnectionController(appModel: appModel, startDiscovery: false)

        let root = SettingsProTab()
            .environment(appModel)
            .environment(appModel.voiceWake)
            .environment(gatewayController)

        _ = Self.host(root)
    }

    @Test @MainActor func settingsProTabBuildsInLightAndDarkMode() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let appModel = NodeAppModel()
            let gatewayController = GatewayConnectionController(appModel: appModel, startDiscovery: false)

            let root = SettingsProTab()
                .environment(appModel)
                .environment(appModel.voiceWake)
                .environment(gatewayController)
                .preferredColorScheme(scheme)

            _ = Self.host(root)
        }
    }

    @Test @MainActor func rootTabsBuildAViewHierarchy() {
        let appModel = NodeAppModel()
        let gatewayController = GatewayConnectionController(appModel: appModel, startDiscovery: false)

        let root = RootTabs()
            .environment(appModel)
            .environment(appModel.voiceWake)
            .environment(gatewayController)

        _ = Self.host(root)
    }

    @Test @MainActor func gatewayTrustPromptPresentsWhenFingerprintArrivesAfterInitialRender() async throws {
        let appModel = NodeAppModel()
        let gatewayController = Self.gatewayControllerWithCapturedTLSFingerprint(appModel: appModel)
        let root = Color.clear
            .gatewayTrustPromptAlert()
            .environment(gatewayController)

        let window = Self.host(root)
        await Self.triggerGatewayTrustPrompt(controller: gatewayController)
        let alert = try await Self.waitForPresentedAlert(in: window)

        #expect(alert.title == "Trust this gateway?")
        #expect(alert.message?.contains("abc123") == true)
        #expect(alert.actions.count == 2)
        #expect(Set(alert.actions.compactMap(\.title)) == ["Cancel", "Trust and connect"])
    }

    @Test @MainActor func stackedRootAlertsStillPresentGatewayTrustPrompt() async throws {
        let appModel = NodeAppModel()
        let gatewayController = Self.gatewayControllerWithCapturedTLSFingerprint(appModel: appModel)
        let root = Color.clear
            .gatewayTrustPromptAlert()
            .deepLinkAgentPromptAlert()
            .environment(appModel)
            .environment(gatewayController)

        let window = Self.host(root)
        await Self.triggerGatewayTrustPrompt(controller: gatewayController)
        let alert = try await Self.waitForPresentedAlert(in: window)

        #expect(alert.title == "Trust this gateway?")
        #expect(alert.message?.contains("abc123") == true)
        #expect(alert.actions.count == 2)
        #expect(Set(alert.actions.compactMap(\.title)) == ["Cancel", "Trust and connect"])
    }

    @Test @MainActor func voiceWakeWordsViewBuildsAViewHierarchy() {
        let appModel = NodeAppModel()
        let root = NavigationStack { VoiceWakeWordsSettingsView() }
            .environment(appModel)
        _ = Self.host(root)
    }

    @Test @MainActor func voiceWakeToastBuildsAViewHierarchy() {
        let root = VoiceWakeToast(command: "openclaw: do something")
        _ = Self.host(root)
    }

    @MainActor private static func gatewayControllerWithCapturedTLSFingerprint(
        appModel: NodeAppModel) -> GatewayConnectionController
    {
        GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { _ in .fingerprint("abc123") })
    }

    @MainActor private static func triggerGatewayTrustPrompt(
        controller: GatewayConnectionController) async
    {
        let host = "gateway-\(UUID().uuidString).example.com"
        let port = 18789
        let stableID = "manual|\(host.lowercased())|\(port)"
        defer { GatewayTLSStore.clearFingerprint(stableID: stableID) }
        GatewayTLSStore.clearFingerprint(stableID: stableID)
        await controller.connectManual(host: host, port: port, useTLS: true)
    }

    @MainActor private static func waitForPresentedAlert(in window: UIWindow) async throws -> UIAlertController {
        let clock = ContinuousClock()
        let timeout = Duration.seconds(3)
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: timeout)

        while true {
            try Task.checkCancellation()
            if let alert = window.rootViewController?.presentedViewController as? UIAlertController {
                return alert
            }
            let now = clock.now
            guard now < deadline else {
                throw NSError(domain: "SwiftUIRenderSmokeTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Timed out waiting for gateway trust alert after \(startedAt.duration(to: now)) "
                            + "(limit: \(timeout)); presented="
                            + String(describing: window.rootViewController?.presentedViewController),
                ])
            }
            await Task.yield()
            let nextPoll = min(clock.now.advanced(by: .milliseconds(10)), deadline)
            try await clock.sleep(until: nextPoll, tolerance: .zero)
        }
    }
}
