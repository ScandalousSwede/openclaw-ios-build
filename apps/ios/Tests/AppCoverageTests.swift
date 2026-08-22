import SwiftUI
import Testing
@testable import OpenClaw

@Suite struct AppCoverageTests {
    @Test @MainActor func nodeAppModelUpdatesBackgroundedState() {
        let appModel = NodeAppModel()

        appModel.setScenePhase(.background)
        #expect(appModel.isBackgrounded == true)

        appModel.setScenePhase(.inactive)
        #expect(appModel.isBackgrounded == false)

        appModel.setScenePhase(.active)
        #expect(appModel.isBackgrounded == false)
    }

    @Test @MainActor func nodeAppModelReconcilesColdLaunchApplicationStateIdempotently() {
        let appModel = NodeAppModel()

        appModel.reconcileApplicationState(.background)
        #expect(appModel.isBackgrounded == true)
        appModel.reconcileApplicationState(.background)
        #expect(appModel.isBackgrounded == true)

        appModel.reconcileApplicationState(.inactive)
        #expect(appModel.isBackgrounded == true)

        appModel.reconcileApplicationState(.active)
        #expect(appModel.isBackgrounded == false)
        appModel.reconcileApplicationState(.active)
        #expect(appModel.isBackgrounded == false)

        appModel.reconcileApplicationState(.inactive)
        #expect(appModel.isBackgrounded == false)
    }

    @Test @MainActor func lifecycleTransitionPreventsRepeatedAudioSuspension() {
        #expect(NodeAppModel.lifecycleTransition(
            isBackgrounded: false,
            applicationState: .background) == .enterBackground)
        #expect(NodeAppModel.lifecycleTransition(
            isBackgrounded: true,
            applicationState: .background) == .none)
        #expect(NodeAppModel.lifecycleTransition(
            isBackgrounded: true,
            applicationState: .inactive) == .none)
        #expect(NodeAppModel.lifecycleTransition(
            isBackgrounded: true,
            applicationState: .active) == .enterForeground)
        #expect(NodeAppModel.lifecycleTransition(
            isBackgrounded: false,
            applicationState: .active) == .none)
        #expect(NodeAppModel.lifecycleTransition(
            isBackgrounded: false,
            applicationState: .inactive) == .none)
    }

    @Test @MainActor func voiceWakeStartReportsUnsupportedOnSimulator() async {
        let voiceWake = VoiceWakeManager()
        voiceWake.isEnabled = true

        await voiceWake.start()

        #expect(voiceWake.isListening == false)
        #expect(voiceWake.statusText.contains("Simulator"))

        voiceWake.stop()
        #expect(voiceWake.statusText == "Off")
    }
}
