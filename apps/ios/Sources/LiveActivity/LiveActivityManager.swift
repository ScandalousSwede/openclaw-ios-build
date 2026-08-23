@preconcurrency import ActivityKit
import Foundation
import OpenClawKit
import os

enum LiveActivityFeatureFlag {
    static let disabledDefaultsKey = "liveActivity.disabled"
    static let disabledEnvironmentKey = "OPENCLAW_DISABLE_LIVE_ACTIVITY"

    static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        !self.isHardDisabled(environment: environment) && !defaults.bool(forKey: self.disabledDefaultsKey)
    }

    static func isHardDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        #if OPENCLAW_DISABLE_LIVE_ACTIVITY
        return true
        #else
        let environmentValue = environment[self.disabledEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return environmentValue.map { ["1", "true", "yes", "on"].contains($0) } ?? false
        #endif
    }

    static func setRuntimeEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(!enabled, forKey: self.disabledDefaultsKey)
    }
}

@MainActor
protocol LiveActivityHandle: AnyObject {
    var id: String { get }
    var agentName: String { get }
    var sessionKey: String { get }
    var state: OpenClawActivityAttributes.ContentState { get }
    var staleDate: Date? { get }
    var isActive: Bool { get }

    func update(state: OpenClawActivityAttributes.ContentState, staleDate: Date?) async
    func end(state: OpenClawActivityAttributes.ContentState) async
}

@MainActor
protocol LiveActivityDriving: AnyObject {
    var areActivitiesEnabled: Bool { get }
    func activities() -> [any LiveActivityHandle]
    func request(
        attributes: OpenClawActivityAttributes,
        state: OpenClawActivityAttributes.ContentState,
        staleDate: Date?) throws -> any LiveActivityHandle
}

@MainActor
private final class ActivityKitLiveActivityHandle: LiveActivityHandle {
    private let activity: Activity<OpenClawActivityAttributes>

    init(_ activity: Activity<OpenClawActivityAttributes>) {
        self.activity = activity
    }

    var id: String { self.activity.id }
    var agentName: String { self.activity.attributes.agentName }
    var sessionKey: String { self.activity.attributes.sessionKey }
    var state: OpenClawActivityAttributes.ContentState { self.activity.content.state }
    var staleDate: Date? { self.activity.content.staleDate }
    var isActive: Bool { self.activity.activityState == .active }

    func update(state: OpenClawActivityAttributes.ContentState, staleDate: Date?) async {
        await self.activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(state: OpenClawActivityAttributes.ContentState) async {
        await self.activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .immediate)
    }
}

@MainActor
private final class ActivityKitLiveActivityDriver: LiveActivityDriving {
    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func activities() -> [any LiveActivityHandle] {
        Activity<OpenClawActivityAttributes>.activities.map(ActivityKitLiveActivityHandle.init)
    }

    func request(
        attributes: OpenClawActivityAttributes,
        state: OpenClawActivityAttributes.ContentState,
        staleDate: Date?) throws -> any LiveActivityHandle
    {
        let activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: nil)
        return ActivityKitLiveActivityHandle(activity)
    }
}

/// Owns one serialized ActivityKit worker. Updates coalesce to the latest
/// presentation, while an end remains a barrier before any replacement starts.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private struct Presentation {
        let agentName: String
        let sessionKey: String
        let state: OpenClawActivityAttributes.ContentState
        let staleDate: Date?
    }

    private struct CurrentActivity {
        let handle: any LiveActivityHandle
        let generation: UInt64
    }

    private let logger = Logger(subsystem: "ai.openclaw.ios", category: "LiveActivity")
    private let connectingStaleSeconds: TimeInterval = 120
    private let hydrationStaleSeconds: TimeInterval = 300
    private let driver: any LiveActivityDriving
    private let featureEnabled: @MainActor () -> Bool

    private var current: CurrentActivity?
    private var pendingPresentation: Presentation?
    private var pendingEndReason: String?
    private var orphanedActivities: [any LiveActivityHandle] = []
    private var worker: Task<Void, Never>?
    private(set) var activityGeneration: UInt64 = 0

    private convenience init() {
        self.init(
            driver: ActivityKitLiveActivityDriver(),
            featureEnabled: { LiveActivityFeatureFlag.isEnabled() })
    }

    init(driver: any LiveActivityDriving, featureEnabled: @escaping @MainActor () -> Bool) {
        self.driver = driver
        self.featureEnabled = featureEnabled
        self.hydrateCurrentAndQueueDuplicateCleanup()
    }

    var isActive: Bool {
        self.featureEnabled() && self.current?.handle.isActive == true
    }

    func refreshFeatureFlag() {
        guard !self.featureEnabled() else { return }
        self.enqueueEnd(reason: "feature_disabled")
    }

    func showConnecting(statusText: String = "Connecting...", agentName: String, sessionKey: String) {
        guard self.featureEnabled() else {
            self.enqueueEnd(reason: "feature_disabled")
            return
        }
        let startedAt = self.startedAt(agentName: agentName, sessionKey: sessionKey)
        self.enqueuePresentation(Presentation(
            agentName: agentName,
            sessionKey: sessionKey,
            state: self.connectingState(statusText: statusText, startedAt: startedAt),
            staleDate: Date().addingTimeInterval(self.connectingStaleSeconds)))
    }

    func showAttention(statusText: String, agentName: String, sessionKey: String) {
        guard self.featureEnabled() else {
            self.enqueueEnd(reason: "feature_disabled")
            return
        }
        let startedAt = self.startedAt(agentName: agentName, sessionKey: sessionKey)
        self.enqueuePresentation(Presentation(
            agentName: agentName,
            sessionKey: sessionKey,
            state: self.attentionState(statusText: statusText, startedAt: startedAt),
            staleDate: nil))
    }

    func handleConnecting(statusText: String = "Connecting...") {
        guard self.featureEnabled(), let owner = self.presentationOwner else {
            if !self.featureEnabled() { self.enqueueEnd(reason: "feature_disabled") }
            return
        }
        self.enqueuePresentation(Presentation(
            agentName: owner.agentName,
            sessionKey: owner.sessionKey,
            state: self.connectingState(statusText: statusText, startedAt: owner.startedAt),
            staleDate: Date().addingTimeInterval(self.connectingStaleSeconds)))
    }

    func handleReconnect() {
        self.enqueueEnd(reason: "connected")
    }

    func handleDisconnect() {
        self.enqueueEnd(reason: "disconnected")
    }

    func endActivity(reason: String) {
        self.enqueueEnd(reason: reason)
    }

    func waitUntilIdleForTesting() async {
        while self.worker != nil || self.pendingEndReason != nil || self.pendingPresentation != nil ||
            !self.orphanedActivities.isEmpty
        {
            await Task.yield()
        }
    }

    func cancelWorkerForTesting() {
        self.worker?.cancel()
    }

    private var presentationOwner: (agentName: String, sessionKey: String, startedAt: Date)? {
        if let pending = self.pendingPresentation {
            return (pending.agentName, pending.sessionKey, pending.state.startedAt)
        }
        if let handle = self.current?.handle {
            return (handle.agentName, handle.sessionKey, handle.state.startedAt)
        }
        return nil
    }

    private func startedAt(agentName: String, sessionKey: String) -> Date {
        if let pending = self.pendingPresentation,
           pending.agentName == agentName,
           pending.sessionKey == sessionKey
        {
            return pending.state.startedAt
        }
        if let handle = self.current?.handle,
           handle.agentName == agentName,
           handle.sessionKey == sessionKey
        {
            return handle.state.startedAt
        }
        return .now
    }

    private func enqueuePresentation(_ presentation: Presentation) {
        self.pendingPresentation = presentation
        self.recordDiagnostic(
            state: "presentation_queued",
            sessionIdentifier: presentation.sessionKey)
        self.startWorkerIfNeeded()
    }

    private func enqueueEnd(reason: String) {
        if self.pendingEndReason == nil {
            // Invalidate an in-flight update immediately. The single worker will
            // still await it before ending, but its completion cannot become current.
            self.activityGeneration &+= 1
        }
        self.pendingEndReason = reason
        self.pendingPresentation = nil
        self.recordDiagnostic(state: "end_queued")
        self.startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard self.worker == nil,
              self.pendingEndReason != nil || self.pendingPresentation != nil || !self.orphanedActivities.isEmpty
        else { return }
        self.worker = Task { @MainActor [weak self] in
            await self?.drainOperations()
        }
    }

    private func drainOperations() async {
        while !Task.isCancelled {
            if !self.orphanedActivities.isEmpty {
                let orphan = self.orphanedActivities.removeFirst()
                await orphan.end(state: self.disconnectedState(startedAt: orphan.state.startedAt))
                continue
            }
            if let reason = self.pendingEndReason {
                self.pendingEndReason = nil
                await self.endCurrent(reason: reason, generationAlreadyInvalidated: true)
                continue
            }
            guard let presentation = self.pendingPresentation else { break }
            self.pendingPresentation = nil
            await self.apply(presentation)
        }

        self.worker = nil
        self.startWorkerIfNeeded()
    }

    private func apply(_ presentation: Presentation) async {
        guard self.featureEnabled() else {
            await self.endCurrent(reason: "feature_disabled")
            return
        }

        if let current = self.current {
            let sameOwner = current.handle.agentName == presentation.agentName &&
                current.handle.sessionKey == presentation.sessionKey
            if !current.handle.isActive || !sameOwner {
                await self.endCurrent(reason: sameOwner ? "inactive" : "context_changed")
                // A newer presentation received while end awaited supersedes this one.
                guard self.pendingPresentation == nil, self.pendingEndReason == nil else { return }
            } else {
                guard current.handle.state != presentation.state ||
                    current.handle.staleDate != presentation.staleDate
                else {
                    return
                }
                let admittedGeneration = current.generation
                await current.handle.update(state: presentation.state, staleDate: presentation.staleDate)
                guard self.current?.generation == admittedGeneration,
                      self.activityGeneration == admittedGeneration
                else {
                    self.logger.info("ignored stale live activity update generation=\(admittedGeneration)")
                    self.recordDiagnostic(
                        state: "stale_update_ignored",
                        generation: admittedGeneration,
                        sessionIdentifier: presentation.sessionKey)
                    return
                }
                self.logger.info("updated live activity generation=\(admittedGeneration)")
                self.recordDiagnostic(
                    state: "updated",
                    generation: admittedGeneration,
                    sessionIdentifier: presentation.sessionKey)
                return
            }
        }

        guard self.pendingPresentation == nil, self.pendingEndReason == nil else { return }
        guard self.driver.areActivitiesEnabled else {
            self.logger.info("Live Activities disabled by system; skipping start")
            return
        }

        do {
            let handle = try self.driver.request(
                attributes: OpenClawActivityAttributes(
                    agentName: presentation.agentName,
                    sessionKey: presentation.sessionKey),
                state: presentation.state,
                staleDate: presentation.staleDate)
            self.activityGeneration &+= 1
            self.current = CurrentActivity(handle: handle, generation: self.activityGeneration)
            self.logger.info(
                "started live activity id=\(handle.id, privacy: .public) generation=\(self.activityGeneration)")
            self.recordDiagnostic(
                state: "started",
                sessionIdentifier: presentation.sessionKey)
        } catch {
            self.logger.error("failed to start live activity: \(error.localizedDescription, privacy: .public)")
            self.recordDiagnostic(
                state: "start_failed",
                sessionIdentifier: presentation.sessionKey)
        }
    }

    private func endCurrent(reason: String, generationAlreadyInvalidated: Bool = false) async {
        guard let current = self.current else { return }
        self.current = nil
        if !generationAlreadyInvalidated {
            self.activityGeneration &+= 1
        }
        self.logger.info(
            "ending live activity generation=\(self.activityGeneration) reason=\(reason, privacy: .public)")
        await current.handle.end(state: self.disconnectedState(startedAt: current.handle.state.startedAt))
        self.recordDiagnostic(
            state: "ended",
            sessionIdentifier: current.handle.sessionKey)
    }

    private func recordDiagnostic(
        state: String,
        generation: UInt64? = nil,
        sessionIdentifier: String? = nil)
    {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .liveActivity,
            state: state,
            activityGeneration: generation ?? self.activityGeneration,
            sessionIdentifier: sessionIdentifier))
    }

    private func hydrateCurrentAndQueueDuplicateCleanup() {
        let activities = self.driver.activities()
        guard self.featureEnabled() else {
            self.orphanedActivities = activities
            self.startWorkerIfNeeded()
            return
        }
        guard !activities.isEmpty else { return }

        let now = Date()
        let candidates = activities.filter { activity in
            let state = activity.state
            guard activity.isActive, !state.isIdle, !state.isDisconnected else { return false }
            return now.timeIntervalSince(state.startedAt) < self.hydrationStaleSeconds
        }
        let keeper = candidates.max { lhs, rhs in
            lhs.state.startedAt < rhs.state.startedAt
        }
        if let keeper {
            self.activityGeneration &+= 1
            self.current = CurrentActivity(handle: keeper, generation: self.activityGeneration)
            self.orphanedActivities = activities.filter { $0.id != keeper.id }
        } else {
            self.orphanedActivities = activities
        }
        self.startWorkerIfNeeded()
    }

    private func connectingState(
        statusText: String,
        startedAt: Date) -> OpenClawActivityAttributes.ContentState
    {
        OpenClawActivityAttributes.ContentState(
            statusText: statusText,
            isIdle: false,
            isDisconnected: false,
            isConnecting: true,
            startedAt: startedAt)
    }

    private func attentionState(
        statusText: String,
        startedAt: Date) -> OpenClawActivityAttributes.ContentState
    {
        OpenClawActivityAttributes.ContentState(
            statusText: statusText,
            isIdle: false,
            isDisconnected: false,
            isConnecting: false,
            startedAt: startedAt)
    }

    private func disconnectedState(startedAt: Date) -> OpenClawActivityAttributes.ContentState {
        OpenClawActivityAttributes.ContentState(
            statusText: "Disconnected",
            isIdle: false,
            isDisconnected: true,
            isConnecting: false,
            startedAt: startedAt)
    }
}
