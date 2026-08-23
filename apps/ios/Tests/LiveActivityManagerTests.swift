import Foundation
import Testing
@testable import OpenClaw

@Suite(.serialized) struct LiveActivityManagerTests {
    @Test @MainActor func featureFlagSupportsRuntimeAndBuildEnvironmentDisable() {
        let suiteName = "LiveActivityManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #if OPENCLAW_DISABLE_LIVE_ACTIVITY
        #expect(!LiveActivityFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
        #else
        #expect(LiveActivityFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
        LiveActivityFeatureFlag.setRuntimeEnabled(false, defaults: defaults)
        #expect(!LiveActivityFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
        LiveActivityFeatureFlag.setRuntimeEnabled(true, defaults: defaults)
        #expect(LiveActivityFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
        #expect(!LiveActivityFeatureFlag.isEnabled(
            defaults: defaults,
            environment: [LiveActivityFeatureFlag.disabledEnvironmentKey: "true"]))
        #expect(LiveActivityFeatureFlag.isHardDisabled(
            environment: [LiveActivityFeatureFlag.disabledEnvironmentKey: "true"]))
        #expect(!LiveActivityFeatureFlag.isHardDisabled(environment: [:]))
        #endif
    }

    @Test @MainActor func burstUsesOneWorkerAndEndsBeforeLatestReplacement() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })

        manager.showConnecting(agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()
        let original = try #require(driver.created.first)

        original.suspendNextUpdate = true
        manager.showAttention(statusText: "first", agentName: "main", sessionKey: "main")
        while !original.updateIsSuspended { await Task.yield() }

        for index in 0..<300 {
            switch index % 3 {
            case 0:
                manager.endActivity(reason: "burst_\(index)")
            case 1:
                manager.showConnecting(
                    statusText: "connecting_\(index)",
                    agentName: "main",
                    sessionKey: "main")
            default:
                manager.showAttention(
                    statusText: "attention_\(index)",
                    agentName: "main",
                    sessionKey: "main")
            }
        }
        manager.showAttention(statusText: "final", agentName: "main", sessionKey: "main")
        original.resumeUpdate()
        await manager.waitUntilIdleForTesting()

        #expect(driver.maximumConcurrentOperations == 1)
        #expect(driver.created.count == 2)
        #expect(original.endCount == 1)
        #expect(original.isActive == false)
        let replacement = try #require(driver.created.last)
        #expect(replacement.state.statusText == "final")
        #expect(replacement.isActive)
        let originalEnd = try #require(driver.events.firstIndex(of: "end:\(original.id)"))
        let replacementStart = try #require(driver.events.firstIndex(of: "start:\(replacement.id)"))
        #expect(originalEnd < replacementStart)
    }

    @Test @MainActor func endInvalidatesSuspendedUpdateWithoutStartingReplacement() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })

        manager.showConnecting(agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()
        let activity = try #require(driver.created.first)
        let admittedGeneration = manager.activityGeneration

        activity.suspendNextUpdate = true
        manager.showAttention(statusText: "approval", agentName: "main", sessionKey: "main")
        while !activity.updateIsSuspended { await Task.yield() }
        manager.endActivity(reason: "disconnect")
        #expect(manager.activityGeneration > admittedGeneration)
        activity.resumeUpdate()
        await manager.waitUntilIdleForTesting()

        #expect(driver.created.count == 1)
        #expect(activity.endCount == 1)
        #expect(!activity.isActive)
        #expect(!manager.isActive)
        #expect(driver.maximumConcurrentOperations == 1)
    }

    @Test @MainActor func cancelledWorkerRestartsToHonorQueuedEndBarrier() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })

        manager.showConnecting(agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()
        let activity = try #require(driver.created.first)

        activity.suspendNextUpdate = true
        manager.showAttention(statusText: "approval", agentName: "main", sessionKey: "main")
        while !activity.updateIsSuspended { await Task.yield() }
        manager.cancelWorkerForTesting()
        manager.endActivity(reason: "cancelled_worker")
        activity.resumeUpdate()
        await manager.waitUntilIdleForTesting()

        #expect(driver.created.count == 1)
        #expect(activity.endCount == 1)
        #expect(!activity.isActive)
        #expect(!manager.isActive)
        #expect(driver.maximumConcurrentOperations == 1)
    }

    @Test @MainActor func contextReplacementEndsOldActivityBeforeStartingNewOwner() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })

        manager.showConnecting(agentName: "main", sessionKey: "session-a")
        await manager.waitUntilIdleForTesting()
        let first = try #require(driver.created.first)

        first.suspendNextEnd = true
        manager.showConnecting(agentName: "main", sessionKey: "session-b")
        while !first.endIsSuspended { await Task.yield() }
        #expect(driver.created.count == 1)
        first.resumeEnd()
        await manager.waitUntilIdleForTesting()
        let second = try #require(driver.created.last)

        #expect(driver.created.count == 2)
        #expect(first.endCount == 1)
        #expect(second.sessionKey == "session-b")
        let firstEnd = try #require(driver.events.firstIndex(of: "end:\(first.id)"))
        let secondStart = try #require(driver.events.firstIndex(of: "start:\(second.id)"))
        #expect(firstEnd < secondStart)
    }

    @Test @MainActor func disablingDuringSuspendedUpdateEndsActiveActivity() async throws {
        let driver = MockLiveActivityDriver()
        var enabled = true
        let manager = LiveActivityManager(driver: driver, featureEnabled: { enabled })

        manager.showConnecting(agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()
        let activity = try #require(driver.created.first)

        activity.suspendNextUpdate = true
        manager.showAttention(statusText: "approval", agentName: "main", sessionKey: "main")
        while !activity.updateIsSuspended { await Task.yield() }
        enabled = false
        manager.refreshFeatureFlag()
        activity.resumeUpdate()
        await manager.waitUntilIdleForTesting()

        #expect(activity.endCount == 1)
        #expect(!activity.isActive)
        #expect(driver.created.count == 1)
        #expect(!manager.isActive)
    }

    @Test @MainActor func disabledFeatureEndsHydratedActivitiesAndRefusesNewOnes() async {
        let driver = MockLiveActivityDriver()
        let hydrated = driver.makeActivity(
            agentName: "main",
            sessionKey: "main",
            state: Self.connectingState("hydrated"),
            recordAsCreated: false)
        driver.initialActivities = [hydrated]
        let manager = LiveActivityManager(driver: driver, featureEnabled: { false })

        manager.showAttention(statusText: "ignored", agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()

        #expect(hydrated.endCount == 1)
        #expect(driver.created.isEmpty)
        #expect(!manager.isActive)
    }

    private static func connectingState(_ text: String) -> OpenClawActivityAttributes.ContentState {
        OpenClawActivityAttributes.ContentState(
            statusText: text,
            isIdle: false,
            isDisconnected: false,
            isConnecting: true,
            startedAt: .now)
    }
}

@MainActor
private final class MockLiveActivityDriver: LiveActivityDriving {
    var areActivitiesEnabled = true
    var initialActivities: [MockLiveActivityHandle] = []
    private(set) var created: [MockLiveActivityHandle] = []
    private(set) var events: [String] = []
    private(set) var maximumConcurrentOperations = 0
    private var concurrentOperations = 0

    func activities() -> [any LiveActivityHandle] {
        self.initialActivities
    }

    func request(
        attributes: OpenClawActivityAttributes,
        state: OpenClawActivityAttributes.ContentState,
        staleDate: Date?) throws -> any LiveActivityHandle
    {
        let handle = self.makeActivity(
            agentName: attributes.agentName,
            sessionKey: attributes.sessionKey,
            state: state,
            staleDate: staleDate,
            recordAsCreated: true)
        self.events.append("start:\(handle.id)")
        return handle
    }

    func makeActivity(
        agentName: String,
        sessionKey: String,
        state: OpenClawActivityAttributes.ContentState,
        staleDate: Date? = nil,
        recordAsCreated: Bool) -> MockLiveActivityHandle
    {
        let handle = MockLiveActivityHandle(
            id: "activity-\(self.created.count + self.initialActivities.count + 1)",
            agentName: agentName,
            sessionKey: sessionKey,
            state: state,
            staleDate: staleDate,
            driver: self)
        if recordAsCreated { self.created.append(handle) }
        return handle
    }

    func begin(_ event: String) {
        self.concurrentOperations += 1
        self.maximumConcurrentOperations = max(self.maximumConcurrentOperations, self.concurrentOperations)
        self.events.append(event)
    }

    func finish() {
        self.concurrentOperations -= 1
    }
}

@MainActor
private final class MockLiveActivityHandle: LiveActivityHandle {
    let id: String
    let agentName: String
    let sessionKey: String
    private(set) var state: OpenClawActivityAttributes.ContentState
    private(set) var staleDate: Date?
    private(set) var isActive = true
    private(set) var endCount = 0
    var suspendNextUpdate = false
    private(set) var updateIsSuspended = false
    var suspendNextEnd = false
    private(set) var endIsSuspended = false

    private unowned let driver: MockLiveActivityDriver
    private var updateContinuation: CheckedContinuation<Void, Never>?
    private var endContinuation: CheckedContinuation<Void, Never>?

    init(
        id: String,
        agentName: String,
        sessionKey: String,
        state: OpenClawActivityAttributes.ContentState,
        staleDate: Date?,
        driver: MockLiveActivityDriver)
    {
        self.id = id
        self.agentName = agentName
        self.sessionKey = sessionKey
        self.state = state
        self.staleDate = staleDate
        self.driver = driver
    }

    func update(state: OpenClawActivityAttributes.ContentState, staleDate: Date?) async {
        self.driver.begin("update:\(self.id):\(state.statusText)")
        defer { self.driver.finish() }
        if self.suspendNextUpdate {
            self.suspendNextUpdate = false
            self.updateIsSuspended = true
            await withCheckedContinuation { continuation in
                self.updateContinuation = continuation
            }
            self.updateIsSuspended = false
        }
        self.state = state
        self.staleDate = staleDate
    }

    func end(state: OpenClawActivityAttributes.ContentState) async {
        self.driver.begin("end:\(self.id)")
        defer { self.driver.finish() }
        if self.suspendNextEnd {
            self.suspendNextEnd = false
            self.endIsSuspended = true
            await withCheckedContinuation { continuation in
                self.endContinuation = continuation
            }
            self.endIsSuspended = false
        }
        self.state = state
        self.staleDate = nil
        self.isActive = false
        self.endCount += 1
    }

    func resumeUpdate() {
        self.updateContinuation?.resume()
        self.updateContinuation = nil
    }

    func resumeEnd() {
        self.endContinuation?.resume()
        self.endContinuation = nil
    }
}
