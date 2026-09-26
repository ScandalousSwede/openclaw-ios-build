import Foundation
import OpenClawProtocol
import SwiftUI
import Testing
@testable import OpenClaw

@Suite struct AppCoverageTests {
    static func cronConfirmationFixture(
        id: String = "synthetic-job",
        name: String = "Synthetic administrative result review and follow-through",
        enabled: Bool = false,
        revision: Int = 100,
        runningAtMs: Int? = nil) throws -> CronJob
    {
        var fields: [String: Any] = [
            "id": id, "name": name, "enabled": enabled,
            "createdAtMs": 1, "updatedAtMs": revision,
            "schedule": ["kind": "every", "everyMs": 60000],
            "sessionTarget": "isolated", "wakeMode": "now",
            "payload": ["kind": "agentTurn", "message": "Synthetic isolated fixture"],
            "state": [String: Any](),
        ]
        if let runningAtMs { fields["state"] = ["runningAtMs": runningAtMs] }
        return try JSONDecoder().decode(CronJob.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test @MainActor func cronConfirmationRejectsChangedOrDifferentDisplayedJob() throws {
        let displayed = try Self.cronConfirmationFixture()
        let confirmation = AgentProTab.CronActionConfirmation(job: displayed, kind: .run)
        #expect(confirmation.matches(try Self.cronConfirmationFixture()))
        #expect(!confirmation.matches(try Self.cronConfirmationFixture(id: "synthetic-other")))
        #expect(!confirmation.matches(try Self.cronConfirmationFixture(revision: 101)))
        #expect(!confirmation.matches(try Self.cronConfirmationFixture(name: "Renamed synthetic schedule")))
        #expect(!confirmation.matches(try Self.cronConfirmationFixture(enabled: true)))
        #expect(confirmation.message.contains("Schedule: Paused"))
        #expect(confirmation.message.contains("Running state not reported"))
        #expect(confirmation.message.contains("Job ID: synthetic-job"))
        let running = AgentProTab.CronActionConfirmation(
            job: try Self.cronConfirmationFixture(enabled: true, runningAtMs: 1000), kind: .pause)
        #expect(running.message.contains("Schedule: Enabled"))
        #expect(running.message.contains("Gateway reported an active run"))
    }

    @Test @MainActor func cronRunMessageRequiresActualDisposition() {
        let cases: [(String, String)] = [
            (#"{"ok":true,"enqueued":true,"runId":"synthetic-run"}"#, "Queued Synthetic job."),
            (#"{"ok":true,"ran":false,"reason":"already-running"}"#, "already running"),
            (#"{"ok":true,"ran":false,"reason":"not-due"}"#, "was not due"),
            (#"{"ok":true,"ran":false,"reason":"invalid-spec"}"#, "invalid job configuration"),
            (#"{"ok":true,"ran":true}"#, "reports that Synthetic job ran"),
            (#"{"ok":false}"#, "without confirming a run"),
            (#"{"ok":true,"enqueued":true}"#, "without confirming a run"),
            (#"{"ok":true,"enqueued":true,"runId":" "}"#, "without confirming a run"),
            (#"{"ok":true,"enqueued":true,"runId":"synthetic-run","ran":false,"reason":"already-running"}"#, "already running"),
            (#"{"ok":1,"enqueued":true,"runId":"synthetic-run"}"#, "without confirming a run"),
            ("not-json", "without confirming a run"),
        ]
        for (json, expected) in cases {
            let message = AgentProTab.cronRunResponseMessage(Data(json.utf8), name: "Synthetic job")
            #expect(message.contains(expected))
            if !expected.hasPrefix("Queued") { #expect(!message.hasPrefix("Queued")) }
        }
    }

    @Test @MainActor func dreamingDayGroupingRetainsEachRecordedTimeAndDistinctFallback() {
        let fallback = "A memory trace surfaced, but details were unavailable in this run."
        let content = """
        <!-- openclaw:dreaming:diary:start -->
        *September 25, 2026 at 08:30*
        \(fallback)
        ---
        *September 25, 2026 at 09:45*
        \(fallback)
        <!-- openclaw:dreaming:diary:end -->
        """
        let days = AgentProDreamingDestination.dreamDiaryDays(from: content)
        #expect(days.count == 1)
        #expect(days.first?.entryCount == 2)
        #expect(days.first?.body.contains("Recorded: September 25, 2026 at 08:30") == true)
        #expect(days.first?.body.contains("Recorded: September 25, 2026 at 09:45") == true)
        #expect(days.first?.body.components(separatedBy: fallback).count == 3)
    }

    static func agentIdentityFixture() -> AgentSummary {
        AgentSummary(
            id: "synthetic-agent-opaque-id",
            name: "Synthetic administrative research and engineering agent",
            identity: nil, workspace: "/synthetic/workspace/full-agent-context",
            model: ["primary": AnyCodable("synthetic-provider/synthetic-full-model-revision-2026-09-26")],
            agentruntime: ["id": AnyCodable("synthetic-runtime-full-identity")])
    }

    @Test func agentIdentityPreservesFullModelAndTechnicalIdentity() {
        let snapshot = AgentIdentitySnapshot(agent: Self.agentIdentityFixture())
        #expect(snapshot.name == "Synthetic administrative research and engineering agent")
        #expect(snapshot.model == "synthetic-provider/synthetic-full-model-revision-2026-09-26")
        #expect(snapshot.id == "synthetic-agent-opaque-id")
        #expect(snapshot.workspace == "/synthetic/workspace/full-agent-context")
        #expect(snapshot.runtime == "synthetic-runtime-full-identity")
    }

    @Test func missingAgentIdentityDoesNotInventAConfiguredModel() {
        let agent = AgentSummary(id: "synthetic-missing", name: " ", identity: nil,
                                 workspace: nil, model: nil, agentruntime: nil)
        let snapshot = AgentIdentitySnapshot(agent: agent)
        #expect(snapshot.name == "Unnamed agent")
        #expect(snapshot.model == nil)
        #expect(snapshot.runtime == nil)
    }

    static func usageCostCoverageFixture(missingEntries: Int?) throws -> AgentOverviewSnapshot {
        var totals: [String: Any] = ["totalCost": 42, "totalTokens": 1200]
        var day: [String: Any] = ["date": "2026-09-01", "totalCost": 42, "totalTokens": 1200]
        if let missingEntries {
            totals["missingCostEntries"] = missingEntries
            day["missingCostEntries"] = missingEntries
        }
        let data = try JSONSerialization.data(withJSONObject: ["days": 1, "totals": totals, "daily": [day]])
        let usage = try JSONDecoder().decode(CostUsageSummaryLite.self, from: data)
        return AgentOverviewSnapshot(
            skills: nil, presence: nil, cronStatus: nil, cronJobs: nil, dreaming: nil, dreamDiary: nil,
            usage: usage, activeAgentId: "synthetic-cost-agent", agentSkillFilter: nil,
            loadedAt: Date(timeIntervalSince1970: 0))
    }

    @Test @MainActor func reportedCostKeepsPartialZeroAndUnknownCoverageSeparate() throws {
        for (missing, expected) in [
            (nil, "Cost coverage not reported."),
            (0, "No entries reported without cost data."),
            (1, "Partial cost: 1 entry has no cost data."),
            (3, "Partial cost: 3 entries have no cost data."),
        ] as [(Int?, String)] {
            let usage = try #require(Self.usageCostCoverageFixture(missingEntries: missing).usage)
            let day = try #require(usage.daily?.first)
            #expect(usage.totalCost == 42)
            #expect(usage.costCoverageText == expected)
            #expect(day.costCoverageText == expected)
            #expect(AgentProTab().usageDayCostLabel(day) == "Reported cost \(AgentProTab.currency(42))")
        }
    }

    static func metricAvailabilityFixture(reported: Bool) throws -> AgentOverviewSnapshot {
        let dreaming = reported ? try JSONDecoder().decode(DreamingStatusLite.self, from:
            Data(#"{"enabled":false,"shortTermCount":0,"totalSignalCount":0,"promotedToday":0}"#.utf8)) : nil
        let usage = reported ? try JSONDecoder().decode(CostUsageSummaryLite.self, from:
            Data(#"{"days":31,"daily":[],"totals":{"totalCost":0,"totalTokens":0},"cacheStatus":{"status":"recorded"}}"#.utf8)) : nil
        return AgentOverviewSnapshot(
            skills: nil, presence: reported ? [] : nil,
            cronStatus: reported ? CronStatusLite(enabled: false, jobs: 0, nextwakeatms: nil) : nil,
            cronJobs: reported ? [] : nil, dreaming: dreaming, dreamDiary: nil, usage: usage,
            activeAgentId: "synthetic-metric-agent", agentSkillFilter: nil,
            loadedAt: Date(timeIntervalSince1970: 0))
    }

    @Test @MainActor func unavailableReportsAndDailyFieldsNeverClaimEmptyOrZero() throws {
        let missing = AgentProTab(initialOverview: try Self.metricAvailabilityFixture(reported: false))
        let zero = AgentProTab(initialOverview: try Self.metricAvailabilityFixture(reported: true))
        #expect(missing.emptyCronTitle == "Cron unavailable")
        #expect(zero.emptyCronTitle == "No scheduled jobs reported")
        #expect(missing.usageDailyEmptyTitle == "Daily usage unavailable")
        #expect(zero.usageDailyEmptyTitle == "No daily usage reported")
        let partial = try JSONDecoder().decode(CostUsageDailyEntryLite.self, from:
            Data(#"{"date":"synthetic-day"}"#.utf8))
        let reported = try JSONDecoder().decode(CostUsageDailyEntryLite.self, from:
            Data(#"{"date":"synthetic-day","totalTokens":0,"totalCost":0}"#.utf8))
        #expect(missing.usageDayTokenLabel(partial) == "Tokens not reported")
        #expect(missing.usageDayCostLabel(partial) == "Cost not reported")
        #expect(zero.usageDayTokenLabel(reported) == "0 tokens")
        #expect(zero.usageDayCostLabel(reported) == "Reported cost \(AgentProTab.currency(0))")
    }

    @Test func unavailableMetricsDoNotBecomeReportedZeros() throws {
        let missing = try Self.metricAvailabilityFixture(reported: false)
        let zero = try Self.metricAvailabilityFixture(reported: true)
        #expect(missing.presence?.count == nil)
        #expect(zero.presence?.count == 0)
        #expect(missing.dreaming?.shortTermCount == nil)
        #expect(zero.dreaming?.shortTermCount == 0)
        #expect(missing.usage?.totalTokens == nil)
        #expect(zero.usage?.totalTokens == 0)
    }

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
