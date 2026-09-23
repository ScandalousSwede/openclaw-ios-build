@preconcurrency import ActivityKit
import Foundation
import OpenClawKit
import Observation
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
    var taskReference: ArgusTaskActivityReference? { get }
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
    var taskReference: ArgusTaskActivityReference? { self.activity.attributes.taskReference }
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
@Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private struct Presentation {
        let agentName: String
        let sessionKey: String
        let state: OpenClawActivityAttributes.ContentState
        let staleDate: Date?
        var taskReference: ArgusTaskActivityReference? = nil
        var startsTask = false
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
    private var inFlightPresentation: Presentation?
    private var pendingEndReason: String?
    private var orphanedActivities: [any LiveActivityHandle] = []
    private var worker: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var taskObservation: (reference: ArgusTaskActivityReference, snapshot: ArgusTaskActivitySnapshot)?
    private(set) var activityGeneration: UInt64 = 0
    private(set) var failedTaskStart: ArgusTaskActivityReference?

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
        guard !self.hasTaskPresentation else { return }
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
        guard !self.hasTaskPresentation else { return }
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
        guard !self.hasTaskPresentation else { return }
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
        guard !self.hasTaskPresentation else { return }
        self.enqueueEnd(reason: "connected")
    }

    func handleDisconnect() {
        guard !self.hasTaskPresentation else { return }
        self.enqueueEnd(reason: "disconnected")
    }

    func endActivity(reason: String) {
        if self.hasTaskPresentation,
           ["background_idle", "operator_disconnected", "gateway_loop_stopped"].contains(reason) { return }
        self.enqueueEnd(reason: reason)
    }

    func isTracking(_ reference: ArgusTaskActivityReference) -> Bool {
        self.featureEnabled() && self.current?.handle.isActive == true
            && self.current?.handle.taskReference == reference
            && self.current?.handle.state.task?.trackingEnded == false
    }

    func trackTask(_ snapshot: ArgusTaskActivitySnapshot, reference: ArgusTaskActivityReference) throws {
        guard self.featureEnabled(), self.driver.areActivitiesEnabled,
              snapshot.canStartActivity(at: .now) else { throw ArgusOperationsError.unavailable }
        try self.admitTask(snapshot, reference: reference)
        self.failedTaskStart = nil
        self.enqueueTask(snapshot, reference: reference, startsTask: true)
    }

    func refreshTask(_ snapshot: ArgusTaskActivitySnapshot, reference: ArgusTaskActivityReference) throws {
        guard self.pendingEndReason == nil else { return }
        if let pending = self.pendingPresentation?.taskReference, pending != reference { return }
        if self.pendingPresentation == nil,
           let inFlight = self.inFlightPresentation?.taskReference, inFlight != reference { return }
        guard self.current?.handle.taskReference == reference || self.pendingPresentation?.taskReference == reference
            || self.inFlightPresentation?.taskReference == reference
        else { return }
        try self.admitTask(snapshot, reference: reference)
        self.enqueueTask(snapshot, reference: reference, startsTask: false)
    }

    func stopTracking(_ reference: ArgusTaskActivityReference) {
        guard self.current?.handle.taskReference == reference || self.pendingPresentation?.taskReference == reference
            || self.inFlightPresentation?.taskReference == reference
        else { return }
        self.enqueueEnd(reason: "tracking_stopped")
    }

    private var hasTaskPresentation: Bool {
        self.pendingPresentation?.taskReference != nil || self.current?.handle.taskReference != nil
            || self.inFlightPresentation?.taskReference != nil
    }

    private func admitTask(_ snapshot: ArgusTaskActivitySnapshot, reference: ArgusTaskActivityReference) throws {
        try snapshot.validate(taskID: reference.taskID, requestID: reference.requestID)
        if let handle = self.current?.handle, handle.taskReference == reference, let old = handle.state.task {
            guard snapshot.lifecycleRevision >= old.lifecycleRevision,
                  snapshot.activityExpiresAt == old.expiresAtMs,
                  snapshot.lifecycleRevision != old.lifecycleRevision || snapshot.phase == old.phase
            else { throw ArgusOperationsError.invalidResponse }
        }
        if let previous = self.taskObservation, previous.reference == reference {
            try snapshot.validateSuccessor(of: previous.snapshot)
        }
        self.taskObservation = (reference, snapshot)
    }

    private func enqueueTask(
        _ snapshot: ArgusTaskActivitySnapshot, reference: ArgusTaskActivityReference, startsTask: Bool)
    {
        let startedAt: Date
        if let handle = self.current?.handle, handle.taskReference == reference { startedAt = handle.state.startedAt }
        else { startedAt = .now }
        // Refreshes may arrive before the worker consumes an explicit start or
        // while replacement awaits the previous activity's end barrier.
        // Coalescing state must not discard the user's start intent.
        let startsTask = startsTask || (self.pendingPresentation?.taskReference == reference &&
            self.pendingPresentation?.startsTask == true) ||
            (self.inFlightPresentation?.taskReference == reference && self.inFlightPresentation?.startsTask == true)
        self.enqueuePresentation(Presentation(
            agentName: "Argus", sessionKey: "task",
            state: .init(statusText: snapshot.phase.headline, isIdle: false, isDisconnected: false,
                         isConnecting: false, startedAt: startedAt, task: snapshot.activityState),
            staleDate: snapshot.expiresAt, taskReference: reference, startsTask: startsTask))
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
        // Retire explicit start intent immediately; a later read cannot revive it.
        self.inFlightPresentation = nil
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
                await orphan.end(state: self.endedState(orphan.state))
                continue
            }
            if let reason = self.pendingEndReason {
                self.pendingEndReason = nil
                await self.endCurrent(reason: reason, generationAlreadyInvalidated: true)
                continue
            }
            guard let presentation = self.pendingPresentation else { break }
            self.pendingPresentation = nil
            self.inFlightPresentation = presentation
            await self.apply(presentation)
            self.inFlightPresentation = nil
        }

        self.worker = nil
        self.startWorkerIfNeeded()
    }

    private func apply(_ presentation: Presentation) async {
        guard self.featureEnabled() else {
            await self.endCurrent(reason: "feature_disabled")
            return
        }

        if let task = presentation.state.task,
           task.phase.isTerminal || task.expiresAt <= .now {
            if self.current?.handle.taskReference == presentation.taskReference {
                await self.endCurrent(reason: "task_tracking_ended", finalState: presentation.state)
            }
            return
        }

        if let current = self.current {
            let sameOwner = current.handle.agentName == presentation.agentName &&
                current.handle.sessionKey == presentation.sessionKey &&
                current.handle.taskReference == presentation.taskReference
            if !current.handle.isActive || !sameOwner {
                await self.endCurrent(reason: sameOwner ? "inactive" : "context_changed")
                // A newer presentation received while end awaited supersedes this one.
                guard self.pendingPresentation == nil, self.pendingEndReason == nil else { return }
                if presentation.taskReference != nil && !presentation.startsTask { return }
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
        if presentation.taskReference != nil && !presentation.startsTask { return }
        guard self.driver.areActivitiesEnabled else {
            self.logger.info("Live Activities disabled by system; skipping start")
            return
        }

        do {
            let handle = try self.driver.request(
                attributes: OpenClawActivityAttributes(
                    agentName: presentation.agentName,
                    sessionKey: presentation.sessionKey, taskReference: presentation.taskReference),
                state: presentation.state,
                staleDate: presentation.staleDate)
            self.activityGeneration &+= 1
            self.current = CurrentActivity(handle: handle, generation: self.activityGeneration)
            self.scheduleTaskExpiry(for: handle)
            self.logger.info(
                "started live activity id=\(handle.id, privacy: .public) generation=\(self.activityGeneration)")
            self.recordDiagnostic(
                state: "started",
                sessionIdentifier: presentation.sessionKey)
        } catch {
            self.failedTaskStart = presentation.taskReference
            self.logger.error("failed to start live activity: \(error.localizedDescription, privacy: .public)")
            self.recordDiagnostic(
                state: "start_failed",
                sessionIdentifier: presentation.sessionKey)
        }
    }

    private func endCurrent(
        reason: String, generationAlreadyInvalidated: Bool = false,
        finalState: OpenClawActivityAttributes.ContentState? = nil) async
    {
        guard let current = self.current else { return }
        self.current = nil
        self.expiryTask?.cancel()
        self.expiryTask = nil
        if !generationAlreadyInvalidated {
            self.activityGeneration &+= 1
        }
        self.logger.info(
            "ending live activity generation=\(self.activityGeneration) reason=\(reason, privacy: .public)")
        let state = self.endedState(finalState ?? current.handle.state)
        await current.handle.end(state: state)
        self.recordDiagnostic(
            state: "ended",
            sessionIdentifier: current.handle.sessionKey)
    }

    private func endedState(
        _ original: OpenClawActivityAttributes.ContentState) -> OpenClawActivityAttributes.ContentState
    {
        var state = original
        if state.task != nil {
            state.task?.trackingEnded = true
            if state.task?.phase.isTerminal != true { state.statusText = "Tracking ended" }
        } else {
            state = self.disconnectedState(startedAt: state.startedAt)
        }
        return state
    }

    private func scheduleTaskExpiry(for handle: any LiveActivityHandle) {
        self.expiryTask?.cancel()
        guard let task = handle.state.task else { return }
        let id = handle.id
        self.expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, task.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            guard let self, self.current?.handle.id == id else { return }
            self.enqueueEnd(reason: "activity_lease_expired")
        }
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
            if activity.taskReference != nil {
                guard let task = state.task else { return false }
                return activity.isActive && !task.trackingEnded && !task.phase.isTerminal && task.expiresAt > now
            }
            guard activity.isActive, !state.isIdle, !state.isDisconnected else { return false }
            return now.timeIntervalSince(state.startedAt) < self.hydrationStaleSeconds
        }
        let keeper = candidates.max { lhs, rhs in
            lhs.state.startedAt < rhs.state.startedAt
        }
        if let keeper {
            self.activityGeneration &+= 1
            self.current = CurrentActivity(handle: keeper, generation: self.activityGeneration)
            self.scheduleTaskExpiry(for: keeper)
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
