import Foundation
import SwiftUI
import Testing
@testable import OpenClaw

@Suite struct AppCoverageTests {
    @Test func skillCountsKeepOverlappingAndUnspecifiedStatusSeparate() throws {
        let report = try Self.skillStatusOverlapFixture()
        #expect(report.totalCount == 4)
        #expect(report.enabledCount == 2)
        #expect(report.missingRequirementCount == 2)
        #expect(report.blockedCount == 1)
        #expect(report.statusSummary(agentSkillFilter: nil) == "4 registered · 2 enabled for this agent · 2 need setup · 1 blocked")
        #expect(!report.statusSummary(agentSkillFilter: nil).contains("ready"))
    }

    @Test @MainActor func skillFiltersMatchIndependentReportCounts() throws {
        let report = try Self.skillStatusOverlapFixture()
        let enabled = report.skills.filter { AgentProTab.matchesSkillStatusFilter($0, filter: .enabled) }
        let setup = report.skills.filter { AgentProTab.matchesSkillStatusFilter($0, filter: .setup) }
        let blocked = report.skills.filter { AgentProTab.matchesSkillStatusFilter($0, filter: .blocked) }
        let off = report.skills.filter { AgentProTab.matchesSkillStatusFilter($0, filter: .off) }
        #expect(enabled.count == report.enabledCount)
        #expect(setup.count == report.missingRequirementCount)
        #expect(blocked.count == report.blockedCount)
        #expect(enabled.map(\.name) == ["synthetic-enabled-setup", "synthetic-unspecified"])
        #expect(off.map(\.name) == ["synthetic-blocked-setup", "synthetic-disabled"])
        let agentBlocked = try JSONDecoder().decode(SkillStatusEntryLite.self, from:
            Data(#"{"name":"synthetic-agent-blocked","blockedByAgentFilter":true}"#.utf8))
        #expect(AgentProTab.matchesSkillStatusFilter(agentBlocked, filter: .blocked))
        #expect(!AgentProTab.matchesSkillStatusFilter(agentBlocked, filter: .enabled))
    }

    @Test @MainActor func skillCountsAndFiltersUseConfigFallbackWithoutRemoteAgentFlags() throws {
        let report = try Self.skillStatusOverlapFixture()
        let fallback: Set<String> = ["synthetic-enabled-setup"]
        let enabled = report.skills.filter {
            AgentProTab.matchesSkillStatusFilter($0, filter: .enabled, agentSkillFilter: fallback)
        }
        let blocked = report.skills.filter {
            AgentProTab.matchesSkillStatusFilter($0, filter: .blocked, agentSkillFilter: fallback)
        }
        #expect(enabled.map(\.name) == ["synthetic-enabled-setup"])
        #expect(blocked.count == 3)
        #expect(report.statusSummary(agentSkillFilter: fallback) ==
            "4 registered · 1 enabled for this agent · 2 need setup · 3 blocked")
        #expect(AgentProTab.matchesSkillStatusFilter(report.skills[0], filter: .setup, agentSkillFilter: fallback))
        #expect(AgentProTab.matchesSkillStatusFilter(report.skills[3], filter: .off, agentSkillFilter: fallback))
    }

    static func skillStatusOverlapFixture() throws -> SkillStatusReportLite {
        try JSONDecoder().decode(SkillStatusReportLite.self, from: Data(#"""
        {"skills":[
          {"name":"synthetic-enabled-setup","missing":{"bins":["fixture-tool"],"env":[],"config":[],"os":[]}},
          {"name":"synthetic-blocked-setup","blockedByAllowlist":true,
           "missing":{"bins":[],"env":["FIXTURE_ONLY"],"config":[],"os":[]}},
          {"name":"synthetic-disabled","disabled":true},
          {"name":"synthetic-unspecified"}
        ]}
        """#.utf8))
    }

    @Test func diagnosticDiscoveryIssueIsNotAnAgentRosterFailure() {
        let issues = SettingsDiagnostics.issues(
            gatewayConnected: true, discoveredGatewayCount: 0,
            talkConfigLoaded: true, notificationStatusText: "Allowed")
        #expect(issues == [.discoveryUnavailable])
        #expect(issues.first?.summary ==
            "Network discovery had no results yet at this check. It may still be searching; manually configured gateways can remain connected.")
    }

    @Test func alternativeBinaryRequirementIsOneSetupRequirement() throws {
        let report = try JSONDecoder().decode(SkillStatusReportLite.self, from: Data(#"""
        {"skills":[{"name":"synthetic-any-bin","missing":{
          "bins":[],"anyBins":["fixture-a","fixture-b"],"env":[],"config":[],"os":[]
        }}]}
        """#.utf8))
        #expect(report.enabledCount == 1)
        #expect(report.missingRequirementCount == 1)
        #expect(report.skills[0].missingSummary == "one of: fixture-a or fixture-b")
        #expect(report.statusSummary(agentSkillFilter: nil) == "1 registered · 1 enabled for this agent · 1 need setup · 0 blocked")
    }

    @Test func diagnosticNotificationResultPreservesAuthorizationMeaning() {
        for (status, expected) in [
            ("Not Set", SettingsDiagnosticIssue.notificationsNotRequested),
            ("Not Allowed", .notificationsUnavailable),
            ("Unknown", .notificationsUnknown),
        ] {
            #expect(SettingsDiagnostics.issues(
                gatewayConnected: true, discoveredGatewayCount: 1,
                talkConfigLoaded: true, notificationStatusText: status) == [expected])
        }
    }

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

    @Test @MainActor func apnsTokenUsesCurrentLaunchCallbackInsteadOfDurableCache() {
        let key = "push.apns.deviceTokenHex"
        UserDefaults.standard.set("stale-token", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let appModel = NodeAppModel()
        #expect(UserDefaults.standard.string(forKey: key) == nil)
        appModel.updateAPNsDeviceToken(Data([0x01, 0x02, 0x03]))
        #expect(UserDefaults.standard.string(forKey: key) == nil)
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
