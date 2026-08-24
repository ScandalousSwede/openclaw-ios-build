import Foundation
import OpenClawKit
import Testing
@testable import OpenClawChatUI

private actor S3TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if self.isOpen { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waiterCount() -> Int { self.waiters.count }
}

private actor S3TestRouteState {
    struct Route: Sendable {
        var stableGatewayID = "gateway-test"
        var routingContract = "per-sender|main|main"
        var capabilities = [OpenClawChatOutboxDatabase.routingCapability]
        var scopes = OpenClawChatOutboxDatabase.requiredOperatorScopes
    }

    enum Availability: Sendable {
        case available(Route)
        case unavailable(OpenClawChatTransportRouteLeaseUnavailableReason)
    }

    private var availability: Availability = .available(Route())
    private var dispatchOutcomes: [OpenClawChatDispatchOutcome] = []
    private var historyMessages: [AnyCodable] = []
    private var historyOffsets: [Int] = []
    private var dispatchedRawIDs: [String] = []
    private var acquireCalls = 0
    private var healthCalls = 0
    private var acquireGate: S3TestGate?
    private var dispatchGate: S3TestGate?
    private var modelPatchGate: S3TestGate?

    func setRoute(_ route: Route) { self.availability = .available(route) }
    func setUnavailable(_ reason: OpenClawChatTransportRouteLeaseUnavailableReason) {
        self.availability = .unavailable(reason)
    }
    func setDispatchOutcomes(_ outcomes: [OpenClawChatDispatchOutcome]) {
        self.dispatchOutcomes = outcomes
    }
    func setHistoryMessages(_ messages: [AnyCodable]) { self.historyMessages = messages }
    func setAcquireGate(_ gate: S3TestGate?) { self.acquireGate = gate }
    func setDispatchGate(_ gate: S3TestGate?) { self.dispatchGate = gate }
    func setModelPatchGate(_ gate: S3TestGate?) { self.modelPatchGate = gate }
    func dispatchedIDs() -> [String] { self.dispatchedRawIDs }
    func acquireCallCount() -> Int { self.acquireCalls }
    func healthCallCount() -> Int { self.healthCalls }
    func requestedHistoryOffsets() -> [Int] { self.historyOffsets }
    func recordHealthCall() { self.healthCalls += 1 }

    func patchModel() async {
        let gate = self.modelPatchGate
        if let gate { await gate.wait() }
    }

    func acquire() async -> Availability {
        self.acquireCalls += 1
        let gate = self.acquireGate
        if let gate { await gate.wait() }
        return self.availability
    }

    func dispatch(rawCommandID: String) async -> OpenClawChatDispatchOutcome {
        self.dispatchedRawIDs.append(rawCommandID)
        let outcome = self.dispatchOutcomes.isEmpty
            ? .accepted(runID: rawCommandID, status: "ok")
            : self.dispatchOutcomes.removeFirst()
        let gate = self.dispatchGate
        if let gate { await gate.wait() }
        return outcome
    }

    func historyPage(
        sessionKey: String,
        limit: Int,
        offset: Int) -> OpenClawChatHistoryPage
    {
        self.historyOffsets.append(offset)
        let end = min(self.historyMessages.count, offset + limit)
        let pageMessages = offset < end ? Array(self.historyMessages[offset..<end]) : []
        let hasMore = end < self.historyMessages.count
        return OpenClawChatHistoryPage(
            payload: OpenClawChatHistoryPayload(
                sessionKey: sessionKey,
                sessionId: "session-test",
                messages: pageMessages,
                thinkingLevel: "off"),
            offset: offset,
            nextOffset: hasMore ? end : nil,
            hasMore: hasMore,
            totalMessages: self.historyMessages.count)
    }
}

private final class S3TestTransport: @unchecked Sendable, OpenClawChatTransport {
    let state: S3TestRouteState
    private let stream: AsyncStream<OpenClawChatTransportEvent>

    init(state: S3TestRouteState = S3TestRouteState()) {
        self.state = state
        self.stream = AsyncStream { continuation in continuation.finish() }
    }

    func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult {
        switch await self.state.acquire() {
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .available(let route):
            let state = self.state
            return .available(OpenClawChatTransportRouteLease(
                stableGatewayID: route.stableGatewayID,
                sessionRoutingContract: route.routingContract,
                capabilities: route.capabilities,
                operatorScopes: route.scopes,
                dispatchMessage: { _, _, _, rawCommandID, _ in
                    await state.dispatch(rawCommandID: rawCommandID)
                },
                requestHistoryPage: { sessionKey, limit, offset, _ in
                    await state.historyPage(sessionKey: sessionKey, limit: limit, offset: offset)
                }))
        }
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        OpenClawChatHistoryPayload(
            sessionKey: sessionKey,
            sessionId: "session-test",
            messages: [],
            thinkingLevel: "off")
    }

    func sendMessage(
        sessionKey _: String,
        message _: String,
        thinking _: String,
        idempotencyKey: String,
        attachments _: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        OpenClawChatSendResponse(runId: idempotencyKey, status: "legacy")
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool {
        await self.state.recordHealthCall()
        return true
    }
    func setSessionModel(sessionKey _: String, model _: String?) async throws {
        await self.state.patchModel()
    }
    func events() -> AsyncStream<OpenClawChatTransportEvent> { self.stream }
}

private struct S3TestStoreFixture {
    let directory: URL
    let database: OpenClawChatOutboxDatabase
    let store: OpenClawChatOutboxStore

    static func make() async throws -> S3TestStoreFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-s3-integration-\(UUID().uuidString)", isDirectory: true)
        let database = try OpenClawChatOutboxDatabase(
            databaseURL: directory.appendingPathComponent(
                OpenClawChatOutboxDatabase.databaseFilename,
                isDirectory: false))
        let store = try await database.store(stableGatewayID: "gateway-test")
        return S3TestStoreFixture(directory: directory, database: database, store: store)
    }

    func close() async throws {
        try await self.database.close()
        try FileManager.default.removeItem(at: self.directory)
    }
}

private func s3Route(_ contract: String = "per-sender|main|main") -> OpenClawChatOutboxRouteSnapshot {
    OpenClawChatOutboxRouteSnapshot(
        routingContract: contract,
        capabilities: [OpenClawChatOutboxDatabase.routingCapability],
        operatorScopes: OpenClawChatOutboxDatabase.requiredOperatorScopes,
        verifiedAt: Date())
}

private func s3Draft(
    rawCommandID: String,
    route: OpenClawChatOutboxRouteSnapshot,
    text: String = "hello") -> OpenClawChatOutboxDraft
{
    OpenClawChatOutboxDraft(
        rawCommandID: rawCommandID,
        sessionKey: "main",
        text: text,
        thinkingLevel: "off",
        route: route)
}

private func s3HistoryMessage(
    role: String,
    idempotencyKey: String,
    text: String = "hello") -> AnyCodable
{
    AnyCodable([
        "role": role,
        "content": [["type": "text", "text": text]],
        "timestamp": 1,
        "idempotencyKey": idempotencyKey,
    ])
}

@Suite("S3 durable outbox integration")
struct OpenClawChatOutboxIntegrationTests {
    @Test func `ACK loss parks until exact canonical user identity appears`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let transport = S3TestTransport()
        await transport.state.setDispatchOutcomes([.ambiguous(code: "ack-lost")])
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        let rawID = UUID().uuidString.lowercased()
        _ = try await coordinator.enqueue(
            rawCommandID: rawID,
            sessionKey: "main",
            text: "hello",
            attachments: [],
            thinkingLevel: "off")

        _ = try await coordinator.processAvailableWork()
        #expect(try await fixture.store.loadUnresolved().first?.outcome == .ambiguous)
        #expect(await transport.state.dispatchedIDs() == [rawID])

        await transport.state.setHistoryMessages([
            s3HistoryMessage(role: "assistant", idempotencyKey: "\(rawID):user"),
        ])
        _ = try await coordinator.processAvailableWork()
        #expect(try await fixture.store.loadUnresolved().first?.outcome == .ambiguous)
        #expect(await transport.state.dispatchedIDs() == [rawID])

        await transport.state.setHistoryMessages([
            s3HistoryMessage(role: "user", idempotencyKey: "\(rawID):user"),
        ])
        _ = try await coordinator.processAvailableWork()
        #expect(try await fixture.store.loadUnresolved().isEmpty)
        #expect(try await fixture.store.loadRecentReceipts().first?.outcome == .canonicalHistoryConfirmed)
        try await fixture.close()
    }

    @Test func `canonical confirmation scans bounded history pages`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let transport = S3TestTransport()
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        let rawID = UUID().uuidString.lowercased()
        var history = (0..<204).map {
            s3HistoryMessage(role: "assistant", idempotencyKey: "other-\($0):user")
        }
        history.append(s3HistoryMessage(role: "user", idempotencyKey: "\(rawID):user"))
        await transport.state.setHistoryMessages(history)
        _ = try await coordinator.enqueue(
            rawCommandID: rawID,
            sessionKey: "main",
            text: "hello",
            attachments: [],
            thinkingLevel: "off")

        _ = try await coordinator.processAvailableWork()

        #expect(try await fixture.store.loadUnresolved().isEmpty)
        #expect(await transport.state.requestedHistoryOffsets() == [0, 200])
        try await fixture.close()
    }

    @Test func `ACK identity mismatch remains ambiguous without minting a new identity`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let transport = S3TestTransport()
        await transport.state.setDispatchOutcomes([
            .accepted(runID: "foreign-run", status: "ok"),
        ])
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        let rawID = UUID().uuidString.lowercased()
        _ = try await coordinator.enqueue(
            rawCommandID: rawID,
            sessionKey: "main",
            text: "hello",
            attachments: [],
            thinkingLevel: "off")

        _ = try await coordinator.processAvailableWork()

        let unresolved = try await fixture.store.loadUnresolved()
        #expect(unresolved.first?.rawCommandID == rawID)
        #expect(unresolved.first?.outcome == .ambiguous)
        #expect(await transport.state.dispatchedIDs() == [rawID])
        try await fixture.close()
    }

    @Test func `route change blocks before dispatch`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let oldRoute = s3Route("per-sender|main|old")
        try await fixture.store.saveVerifiedRouteSnapshot(oldRoute)
        let rawID = UUID().uuidString.lowercased()
        _ = try await fixture.store.persistBeforeDraftClear(s3Draft(rawCommandID: rawID, route: oldRoute))

        let state = S3TestRouteState()
        await state.setRoute(.init(routingContract: "per-sender|main|main"))
        let transport = S3TestTransport(state: state)
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        _ = try await coordinator.processAvailableWork()

        #expect(try await fixture.store.loadUnresolved().first?.outcome == .blockedRouteChanged)
        #expect(await state.dispatchedIDs().isEmpty)
        try await coordinator.cancelProvablyUnaccepted(rawCommandID: rawID)
        #expect(try await fixture.store.loadUnresolved().isEmpty)
        #expect(try await fixture.store.loadRecentReceipts().first?.outcome == .cancelled)
        try await fixture.close()
    }

    @Test func `authenticated route change rejection is typed and never auto retried`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let transport = S3TestTransport()
        await transport.state.setDispatchOutcomes([
            .dispatchRejected(
                code: "INVALID_REQUEST",
                reason: OpenClawChatSessionRoutingContract.changedErrorReason),
        ])
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        let rawID = UUID().uuidString.lowercased()
        _ = try await coordinator.enqueue(
            rawCommandID: rawID,
            sessionKey: "main",
            text: "hello",
            attachments: [],
            thinkingLevel: "off")

        _ = try await coordinator.processAvailableWork()
        _ = try await coordinator.processAvailableWork()

        #expect(try await fixture.store.loadUnresolved().first?.outcome == .blockedRouteChanged)
        #expect(await transport.state.dispatchedIDs() == [rawID])
        try await fixture.close()
    }

    @Test func `unrelated capability and optional scope drift does not block chat`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let observedRoute = OpenClawChatOutboxRouteSnapshot(
            routingContract: "per-sender|main|main",
            capabilities: [OpenClawChatOutboxDatabase.routingCapability, "talk-diagnostics"],
            operatorScopes: OpenClawChatOutboxDatabase.requiredOperatorScopes + ["operator.talk.secrets"],
            verifiedAt: Date())
        try await fixture.store.saveVerifiedRouteSnapshot(observedRoute)
        let rawID = UUID().uuidString.lowercased()
        _ = try await fixture.store.persistBeforeDraftClear(
            s3Draft(rawCommandID: rawID, route: observedRoute))

        // The live route still has the exact routing contract and S3 minimums,
        // but no unrelated Talk evidence from the earlier Hello.
        let transport = S3TestTransport()
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        _ = try await coordinator.processAvailableWork()

        #expect(await transport.state.dispatchedIDs() == [rawID])
        #expect(try await fixture.store.loadUnresolved().first?.outcome == .accepted)
        try await fixture.close()
    }

    @Test func `FIFO and explicit retry preserve the raw identity`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let route = s3Route()
        try await fixture.store.saveVerifiedRouteSnapshot(route)
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        _ = try await fixture.store.persistBeforeDraftClear(s3Draft(rawCommandID: first, route: route))
        _ = try await fixture.store.persistBeforeDraftClear(s3Draft(rawCommandID: second, route: route))

        let transport = S3TestTransport()
        await transport.state.setDispatchOutcomes([
            .ambiguous(code: "timeout"),
            .accepted(runID: first, status: "ok"),
            .accepted(runID: second, status: "ok"),
        ])
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        _ = try await coordinator.processAvailableWork()
        #expect(await transport.state.dispatchedIDs() == [first])

        try await coordinator.retrySameIdentity(rawCommandID: first)
        _ = try await coordinator.processAvailableWork()
        #expect(await transport.state.dispatchedIDs() == [first, first])

        await transport.state.setHistoryMessages([
            s3HistoryMessage(role: "user", idempotencyKey: "\(first):user"),
            s3HistoryMessage(role: "user", idempotencyKey: "\(second):user"),
        ])
        _ = try await coordinator.processAvailableWork()
        #expect(await transport.state.dispatchedIDs() == [first, first, second])
        try await fixture.close()
    }

    @Test func `capability failure is explicit and fail closed`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let state = S3TestRouteState()
        await state.setUnavailable(.capabilityUnavailable)
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: S3TestTransport(state: state))

        var enqueueRejected = false
        do {
            _ = try await coordinator.enqueue(
                rawCommandID: UUID().uuidString.lowercased(),
                sessionKey: "main",
                text: "must not persist",
                attachments: [],
                thinkingLevel: "off")
        } catch {
            enqueueRejected = true
        }
        #expect(enqueueRejected)
        #expect(try await fixture.store.loadUnresolved().isEmpty)

        let result = try await coordinator.processAvailableWork()
        #expect(result.status.deliveryGate == .capabilityUnavailable)
        #expect(await state.dispatchedIDs().isEmpty)

        await state.setRoute(.init(capabilities: []))
        let malformedLeaseResult = try await coordinator.processAvailableWork()
        #expect(malformedLeaseResult.status.deliveryGate == .capabilityUnavailable)
        var malformedLeaseEnqueueRejected = false
        do {
            _ = try await coordinator.enqueue(
                rawCommandID: UUID().uuidString.lowercased(),
                sessionKey: "main",
                text: "must still not persist",
                attachments: [],
                thinkingLevel: "off")
        } catch {
            malformedLeaseEnqueueRejected = true
        }
        #expect(malformedLeaseEnqueueRejected)
        #expect(try await fixture.store.loadUnresolved().isEmpty)

        await state.setUnavailable(.operatorScopesUnavailable)
        let scopeResult = try await coordinator.processAvailableWork()
        #expect(scopeResult.status.deliveryGate == .operatorScopesUnavailable)
        #expect(await state.dispatchedIDs().isEmpty)
        try await fixture.close()
    }

    @Test @MainActor func `status presentation distinguishes route change from gateway rejection`() {
        let routeChanged = OpenClawChatView.outboxPresentation(for: OpenClawChatOutboxStatus(
            blockedCount: 1,
            headOutcome: .blockedRouteChanged,
            retryableRawCommandID: "route-command",
            cancellableRawCommandID: "route-command"))
        let rejected = OpenClawChatView.outboxPresentation(for: OpenClawChatOutboxStatus(
            blockedCount: 1,
            headOutcome: .dispatchRejected,
            retryableRawCommandID: "rejected-command",
            cancellableRawCommandID: "rejected-command"))
        let scopeGate = OpenClawChatView.outboxPresentation(for: OpenClawChatOutboxStatus(
            deliveryGate: .operatorScopesUnavailable))
        let firstOffline = OpenClawChatView.outboxPresentation(for: OpenClawChatOutboxStatus(
            hasVerifiedRouteSnapshot: false,
            deliveryGate: .offline))

        #expect(routeChanged?.title == "Delivery route changed")
        #expect(routeChanged?.message.contains("destination route") == true)
        #expect(rejected?.title == "Gateway rejected message")
        #expect(rejected?.message.contains("rejected") == true)
        #expect(scopeGate?.title == "Durable delivery unavailable")
        #expect(scopeGate?.message.contains("operator chat scopes") == true)
        #expect(firstOffline?.title == "Offline queue not yet available")
        #expect(firstOffline?.message.contains("Connect once") == true)
    }

    @Test func `cancellation before wire dispatch restores not dispatched`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let route = s3Route()
        try await fixture.store.saveVerifiedRouteSnapshot(route)
        let rawID = UUID().uuidString.lowercased()
        _ = try await fixture.store.persistBeforeDraftClear(s3Draft(rawCommandID: rawID, route: route))
        let claimGate = S3TestGate()
        let transport = S3TestTransport()
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            afterClaimBeforeDispatch: { await claimGate.wait() })

        let task = Task { try await coordinator.processAvailableWork() }
        try await waitUntil("claim reached pre-dispatch gate") {
            await claimGate.waiterCount() == 1
        }
        task.cancel()
        await claimGate.open()
        _ = try await task.value
        #expect(try await fixture.store.loadUnresolved().first?.outcome == .notDispatched)
        #expect(await transport.state.dispatchedIDs().isEmpty)
        try await fixture.close()
    }

    @Test func `cancellation after admission remains ambiguous`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let route = s3Route()
        try await fixture.store.saveVerifiedRouteSnapshot(route)
        let rawID = UUID().uuidString.lowercased()
        _ = try await fixture.store.persistBeforeDraftClear(s3Draft(rawCommandID: rawID, route: route))
        let dispatchGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setDispatchGate(dispatchGate)
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)

        let task = Task { try await coordinator.processAvailableWork() }
        try await waitUntil("wire dispatch admitted") {
            await transport.state.dispatchedIDs() == [rawID]
        }
        task.cancel()
        await dispatchGate.open()
        _ = try await task.value
        #expect(try await fixture.store.loadUnresolved().first?.outcome == .ambiguous)
        var unsafeCancelRejected = false
        do {
            try await coordinator.cancelProvablyUnaccepted(rawCommandID: rawID)
        } catch {
            unsafeCancelRejected = true
        }
        #expect(unsafeCancelRejected)
        try await coordinator.retrySameIdentity(rawCommandID: rawID)
        #expect(try await fixture.store.loadUnresolved().first?.outcome == .notDispatched)
        try await fixture.close()
    }

    @Test @MainActor func `view model shutdown fences admitted worker as ambiguous`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let dispatchGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setDispatchGate(dispatchGate)
        let vm = OpenClawChatViewModel(
            sessionKey: "main",
            transport: transport,
            outboxStore: fixture.store,
            outboxStableGatewayID: "gateway-test")
        vm.input = "shutdown during dispatch"
        vm.send()
        try await waitUntil("view model worker admitted dispatch") {
            !(await transport.state.dispatchedIDs()).isEmpty
        }

        vm.shutdown()
        await dispatchGate.open()
        try await waitUntil("cancelled admitted worker parked") {
            (try? await fixture.store.loadUnresolved().first?.outcome) == .ambiguous
        }
        #expect(await transport.state.dispatchedIDs().count == 1)
        try await fixture.close()
    }

    @Test @MainActor func `persist failure preserves exact draft`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        try await fixture.store.securePurge()
        let vm = OpenClawChatViewModel(
            sessionKey: "main",
            transport: S3TestTransport(),
            outboxStore: fixture.store,
            outboxStableGatewayID: "gateway-test")
        vm.input = "keep this draft"
        vm.send()
        try await waitUntil("persist failure surfaced") {
            await MainActor.run { vm.errorText != nil && !vm.isSending }
        }
        #expect(vm.input == "keep this draft")
        vm.shutdown()
        try await fixture.close()
    }

    @Test @MainActor func `draft edit during persistence survives compare and swap`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        try await fixture.store.saveVerifiedRouteSnapshot(s3Route())
        let acquireGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setUnavailable(.routeUnavailable)
        await transport.state.setAcquireGate(acquireGate)
        let vm = OpenClawChatViewModel(
            sessionKey: "main",
            transport: transport,
            outboxStore: fixture.store,
            outboxStableGatewayID: "gateway-test")
        vm.input = "first draft"
        vm.send()
        try await waitUntil("route acquisition waiting") {
            await transport.state.acquireCallCount() == 1
        }
        vm.input = "new draft"
        await acquireGate.open()
        try await waitUntil("first draft persisted") {
            guard let commands = try? await fixture.store.loadUnresolved() else { return false }
            return commands.contains { $0.text == "first draft" }
        }
        #expect(vm.input == "new draft")
        vm.shutdown()
        try await fixture.close()
    }

    @Test @MainActor func `session switch during persistence cannot clear or project old draft`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        try await fixture.store.saveVerifiedRouteSnapshot(s3Route())
        let acquireGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setUnavailable(.routeUnavailable)
        await transport.state.setAcquireGate(acquireGate)
        let vm = OpenClawChatViewModel(
            sessionKey: "main",
            transport: transport,
            outboxStore: fixture.store,
            outboxStableGatewayID: "gateway-test")
        vm.input = "same visible draft"
        vm.send()
        try await waitUntil("old session route acquisition waiting") {
            await transport.state.acquireCallCount() == 1
        }
        vm.switchSession(to: "other")
        #expect(vm.input == "same visible draft")
        await acquireGate.open()
        try await waitUntil("old session command committed") {
            guard let commands = try? await fixture.store.loadUnresolved() else { return false }
            return commands.first?.sessionKey == "main"
        }

        #expect(vm.sessionKey == "other")
        #expect(vm.input == "same visible draft")
        #expect(!vm.messages.contains { $0.idempotencyKey?.hasSuffix(":user") == true })
        vm.shutdown()
        try await fixture.close()
    }

    @Test @MainActor func `offline queue restores after view model relaunch`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        try await fixture.store.saveVerifiedRouteSnapshot(s3Route())
        let state = S3TestRouteState()
        await state.setUnavailable(.routeUnavailable)
        let transport = S3TestTransport(state: state)

        let first = OpenClawChatViewModel(
            sessionKey: "main",
            transport: transport,
            outboxStore: fixture.store,
            outboxStableGatewayID: "gateway-test")
        first.input = "offline agenda question"
        first.send()
        try await waitUntil("offline draft queued") {
            (try? await fixture.store.loadUnresolved().count) == 1
        }
        #expect(await state.healthCallCount() == 0)
        #expect(await state.dispatchedIDs().isEmpty)
        first.shutdown()

        let relaunched = OpenClawChatViewModel(
            sessionKey: "main",
            transport: transport,
            outboxStore: fixture.store,
            outboxStableGatewayID: "gateway-test")
        relaunched.load()
        try await waitUntil("offline draft restored") {
            await MainActor.run {
                relaunched.outboxStatus.queuedCount == 1 &&
                    relaunched.messages.contains { $0.idempotencyKey?.hasSuffix(":user") == true }
            }
        }
        #expect(relaunched.outboxStatus.deliveryGate == .offline)
        relaunched.shutdown()
        try await fixture.close()
    }

    @Test @MainActor func `offline persistence does not wait for an in flight model patch`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        try await fixture.store.saveVerifiedRouteSnapshot(s3Route())
        let state = S3TestRouteState()
        await state.setUnavailable(.routeUnavailable)
        let modelGate = S3TestGate()
        await state.setModelPatchGate(modelGate)
        let transport = S3TestTransport(state: state)
        let vm = OpenClawChatViewModel(
            sessionKey: "main",
            transport: transport,
            outboxStore: fixture.store,
            outboxStableGatewayID: "gateway-test")

        vm.selectModel("openai/gpt-5.4")
        try await waitUntil("model patch remains in flight") {
            await modelGate.waiterCount() == 1
        }
        vm.input = "persist without the network patch"
        vm.send()
        try await waitUntil("offline command persisted independently") {
            (try? await fixture.store.loadUnresolved().first?.text) ==
                "persist without the network patch"
        }

        #expect(vm.input.isEmpty)
        #expect(await state.healthCallCount() == 0)
        await modelGate.open()
        vm.shutdown()
        try await fixture.close()
    }
}
