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

private actor S3TestFlag {
    private var value = false
    func set() { self.value = true }
    func get() -> Bool { self.value }
}

private actor S3TestUpdateBox {
    private var update: OpenClawChatOutboxDeliveryUpdate?

    func set(_ update: OpenClawChatOutboxDeliveryUpdate) {
        self.update = update
    }

    func get() -> OpenClawChatOutboxDeliveryUpdate? { self.update }
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
    private var createCalls = 0
    private var resetCalls = 0
    private var compactCalls = 0
    private var acquireGate: S3TestGate?
    private var dispatchGate: S3TestGate?
    private var modelPatchGate: S3TestGate?
    private var createGate: S3TestGate?
    private var resetGate: S3TestGate?

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
    func setCreateGate(_ gate: S3TestGate?) { self.createGate = gate }
    func setResetGate(_ gate: S3TestGate?) { self.resetGate = gate }
    func dispatchedIDs() -> [String] { self.dispatchedRawIDs }
    func acquireCallCount() -> Int { self.acquireCalls }
    func healthCallCount() -> Int { self.healthCalls }
    func createCallCount() -> Int { self.createCalls }
    func resetCallCount() -> Int { self.resetCalls }
    func compactCallCount() -> Int { self.compactCalls }
    func requestedHistoryOffsets() -> [Int] { self.historyOffsets }
    func recordHealthCall() { self.healthCalls += 1 }
    func recordCreateCall() async {
        self.createCalls += 1
        if let createGate { await createGate.wait() }
    }
    func recordResetCall() async {
        self.resetCalls += 1
        if let resetGate { await resetGate.wait() }
    }
    func recordCompactCall() { self.compactCalls += 1 }

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
    func createSession(
        key: String,
        label _: String?,
        parentSessionKey _: String?) async throws -> OpenClawChatCreateSessionResponse
    {
        await self.state.recordCreateCall()
        return OpenClawChatCreateSessionResponse(ok: true, key: key, sessionId: "created-\(key)")
    }
    func setSessionModel(sessionKey _: String, model _: String?) async throws {
        await self.state.patchModel()
    }
    func resetSession(sessionKey _: String) async throws {
        await self.state.recordResetCall()
    }
    func compactSession(sessionKey _: String) async throws {
        await self.state.recordCompactCall()
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
    @Test func `concurrent Chat and Talk route refreshes persist both FIFO rows`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let firstPersistGate = S3TestGate()
        let transport = S3TestTransport()
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            afterEnqueueRouteSaveBeforePersist: { rawCommandID in
                if rawCommandID == "chat-first" {
                    await firstPersistGate.wait()
                }
            })

        let chat = Task {
            try await coordinator.enqueue(
                rawCommandID: "chat-first",
                sessionKey: "main",
                text: "chat",
                attachments: [],
                thinkingLevel: "off")
        }
        try await waitUntil("first enqueue owns route-store transaction") {
            await firstPersistGate.waiterCount() == 1
        }
        let talk = Task {
            try await coordinator.enqueue(
                rawCommandID: "talk-second",
                sessionKey: "main",
                text: "talk",
                attachments: [],
                thinkingLevel: "off")
        }
        try await waitUntil("second enqueue waits behind exact route evidence") {
            await coordinator._test_routeStoreOperationWaiterCount() == 1
        }
        #expect(await transport.state.acquireCallCount() == 1)

        await firstPersistGate.open()
        _ = try await chat.value
        _ = try await talk.value
        let rows = try await fixture.store.loadUnresolved()
        #expect(rows.map(\.rawCommandID) == ["chat-first", "talk-second"])
        #expect(await transport.state.acquireCallCount() == 2)
        try await fixture.close()
    }

    @Test func `worker route refresh cannot split enqueue route save from persistence`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let persistGate = S3TestGate()
        let transport = S3TestTransport()
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            afterEnqueueRouteSaveBeforePersist: { _ in await persistGate.wait() })

        let enqueue = Task {
            try await coordinator.enqueue(
                rawCommandID: "talk-before-worker-refresh",
                sessionKey: "main",
                text: "preserve",
                attachments: [],
                thinkingLevel: "off")
        }
        try await waitUntil("enqueue waits between route save and persistence") {
            await persistGate.waiterCount() == 1
        }
        let worker = Task { try await coordinator.processAvailableWork() }
        try await waitUntil("worker waits behind enqueue route-store transaction") {
            await coordinator._test_routeStoreOperationWaiterCount() == 1
        }
        #expect(await transport.state.acquireCallCount() == 1)

        await persistGate.open()
        _ = try await enqueue.value
        _ = try await worker.value
        let rows = try await fixture.store.loadUnresolved()
        #expect(rows.map(\.rawCommandID) == ["talk-before-worker-refresh"])
        #expect(await transport.state.acquireCallCount() == 2)
        try await fixture.close()
    }

    @Test func `cancelled route-store waiter drains without persisting or leaking the gate`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let firstPersistGate = S3TestGate()
        let transport = S3TestTransport()
        let coordinator = OpenClawChatOutboxCoordinator(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            afterEnqueueRouteSaveBeforePersist: { rawCommandID in
                if rawCommandID == "gate-owner" { await firstPersistGate.wait() }
            })
        let owner = Task {
            try await coordinator.enqueue(
                rawCommandID: "gate-owner",
                sessionKey: "main",
                text: "first",
                attachments: [],
                thinkingLevel: "off")
        }
        try await waitUntil("first caller owns route-store gate") {
            await firstPersistGate.waiterCount() == 1
        }
        let cancelled = Task {
            try await coordinator.enqueue(
                rawCommandID: "cancelled-waiter",
                sessionKey: "main",
                text: "second",
                attachments: [],
                thinkingLevel: "off")
        }
        try await waitUntil("second caller is queued on route-store gate") {
            await coordinator._test_routeStoreOperationWaiterCount() == 1
        }
        cancelled.cancel()
        await firstPersistGate.open()
        _ = try await owner.value
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(await coordinator._test_routeStoreOperationWaiterCount() == 0)
        let rows = try await fixture.store.loadUnresolved()
        #expect(rows.map(\.rawCommandID) == ["gate-owner"])
        try await fixture.close()
    }

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

    @Test func `owner retry self wakes after caller disappears`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let rawID = UUID().uuidString.lowercased()
        let transport = S3TestTransport()
        await transport.state.setDispatchOutcomes([
            .ambiguous(code: "timeout"),
            .accepted(runID: rawID, status: "ok"),
        ])
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            confirmationDelaysNanoseconds: [])
        _ = try await owner.enqueue(
            rawCommandID: rawID,
            sessionKey: "main",
            text: "retry without a view",
            attachments: [],
            thinkingLevel: "off")
        try await waitUntil("first dispatch parks ambiguous") {
            (try? await fixture.store.loadUnresolved().first?.outcome) == .ambiguous
        }

        let shortLivedCaller = Task {
            try await owner.retrySameIdentity(rawCommandID: rawID)
        }
        try await shortLivedCaller.value
        try await waitUntil("owner dispatches retry without another wake") {
            await transport.state.dispatchedIDs() == [rawID, rawID]
        }

        let retryRows = try await fixture.store.loadUnresolved()
        #expect(retryRows.first?.rawCommandID == rawID)
        await owner.retire()
        try await fixture.close()
    }

    @Test func `new subscriber receives preexisting offline FIFO snapshot without external wake`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let route = s3Route()
        let rawID = UUID().uuidString.lowercased()
        try await fixture.store.saveVerifiedRouteSnapshot(route)
        _ = try await fixture.store.persistBeforeDraftClear(
            s3Draft(rawCommandID: rawID, route: route))
        let state = S3TestRouteState()
        await state.setUnavailable(.routeUnavailable)
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: S3TestTransport(state: state),
            confirmationDelaysNanoseconds: [])
        let stream = await owner.updates()
        let updateBox = S3TestUpdateBox()
        let observer = Task {
            for await update in stream {
                await updateBox.set(update)
                return
            }
        }

        try await waitUntil("post-registration wake publishes offline snapshot") {
            await updateBox.get() != nil
        }
        let observedUpdate = await updateBox.get()
        let update = try #require(observedUpdate)
        #expect(update.status.deliveryGate == .offline)
        #expect(update.unresolvedCommands.map(\.rawCommandID) == [rawID])
        observer.cancel()
        await owner.retire()
        try await fixture.close()
    }

    @Test func `owner cancellation self wakes the newly exposed FIFO head`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        let transport = S3TestTransport()
        await transport.state.setDispatchOutcomes([
            .dispatchRejected(code: "rejected", reason: "operator rejected"),
            .accepted(runID: second, status: "ok"),
        ])
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            confirmationDelaysNanoseconds: [])
        _ = try await owner.enqueue(
            rawCommandID: first,
            sessionKey: "main",
            text: "cancel this rejected head",
            attachments: [],
            thinkingLevel: "off")
        _ = try await owner.enqueue(
            rawCommandID: second,
            sessionKey: "main",
            text: "deliver the next row",
            attachments: [],
            thinkingLevel: "off")
        try await waitUntil("first head blocks FIFO") {
            (try? await fixture.store.loadUnresolved().first?.outcome) == .dispatchRejected
        }
        #expect(await transport.state.dispatchedIDs() == [first])

        let shortLivedCaller = Task {
            try await owner.cancelProvablyUnaccepted(rawCommandID: first)
        }
        try await shortLivedCaller.value
        try await waitUntil("owner dispatches exposed head without another wake") {
            await transport.state.dispatchedIDs() == [first, second]
        }

        let unresolved = try await fixture.store.loadUnresolved()
        #expect(unresolved.map(\.rawCommandID) == [second])
        await owner.retire()
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

        await state.setUnavailable(.operatorSessionUnavailable)
        let operatorResult = try await coordinator.processAvailableWork()
        #expect(operatorResult.status.deliveryGate == .operatorSessionUnavailable)
        #expect(await state.dispatchedIDs().isEmpty)

        await state.setUnavailable(.operatorRoleMissing)
        let missingRoleResult = try await coordinator.processAvailableWork()
        #expect(missingRoleResult.status.deliveryGate == .operatorRoleMissing)
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
        let operatorGate = OpenClawChatView.outboxPresentation(for: OpenClawChatOutboxStatus(
            deliveryGate: .operatorSessionUnavailable))
        let missingRoleGate = OpenClawChatView.outboxPresentation(for: OpenClawChatOutboxStatus(
            deliveryGate: .operatorRoleMissing))
        let firstOffline = OpenClawChatView.outboxPresentation(for: OpenClawChatOutboxStatus(
            hasVerifiedRouteSnapshot: false,
            deliveryGate: .offline))

        #expect(routeChanged?.title == "Delivery route changed")
        #expect(routeChanged?.message.contains("destination route") == true)
        #expect(rejected?.title == "Gateway rejected message")
        #expect(rejected?.message.contains("rejected") == true)
        #expect(scopeGate?.title == "Durable delivery unavailable")
        #expect(scopeGate?.message.contains("operator chat scopes") == true)
        #expect(operatorGate?.message.contains("operator session") == true)
        #expect(missingRoleGate?.message.contains("missing the operator role") == true)
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

    @Test @MainActor func `view model shutdown leaves shared owner delivery running`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let dispatchGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setDispatchGate(dispatchGate)
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        let vm = OpenClawChatViewModel(
            sessionKey: "main",
            transport: transport,
            outboxDeliveryOwner: owner)
        vm.input = "shutdown during dispatch"
        vm.send()
        try await waitUntil("view model worker admitted dispatch") {
            !(await transport.state.dispatchedIDs()).isEmpty
        }

        vm.shutdown()
        await dispatchGate.open()
        try await waitUntil("shared owner records accepted delivery") {
            (try? await fixture.store.loadUnresolved().first?.outcome) == .accepted
        }
        #expect(await transport.state.dispatchedIDs().count == 1)
        await owner.retire()
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

    @Test func `shared delivery owner coalesces concurrent chat and talk wakes`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let dispatchGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setDispatchGate(dispatchGate)
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        let updates = await owner.updates()

        _ = try await owner.enqueue(
            rawCommandID: "talk-one-owner",
            sessionKey: "main",
            text: "durable talk",
            attachments: [],
            thinkingLevel: "low")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { try? await owner.wake() }
            }
        }
        try await waitUntil("one shared worker reaches dispatch") {
            await transport.state.dispatchedIDs().count == 1
        }
        await dispatchGate.open()
        try await waitUntil("shared worker records accepted") {
            (try? await fixture.store.loadUnresolved().first?.outcome) == .accepted
        }
        #expect(await transport.state.dispatchedIDs() == ["talk-one-owner"])

        var iterator = updates.makeAsyncIterator()
        var observedUpdates: [OpenClawChatOutboxDeliveryUpdate] = []
        while let update = await iterator.next() {
            observedUpdates.append(update)
            if update.transitions.contains(.dispatched(rawCommandID: "talk-one-owner")) {
                break
            }
        }
        await owner.retire()
        while let update = await iterator.next() {
            observedUpdates.append(update)
        }
        #expect(observedUpdates.contains { $0.unresolvedCommands.first?.outcome == .accepted })
        #expect(observedUpdates.flatMap(\.transitions) == [
            .dispatched(rawCommandID: "talk-one-owner"),
        ])
        try await fixture.close()
    }

    @Test func `subscribing after owner retirement finishes immediately`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: S3TestTransport())
        await owner.retire()

        let updates = await owner.updates()
        var iterator = updates.makeAsyncIterator()
        let finished = await iterator.next()
        #expect(finished == nil)
        try await fixture.close()
    }

    @Test func `shared owner confirms accepted row without a chat view wake`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let rawID = "talk-no-chat-confirmation"
        let transport = S3TestTransport()
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            confirmationDelaysNanoseconds: [100_000_000, 100_000_000])

        _ = try await owner.enqueue(
            rawCommandID: rawID,
            sessionKey: "main",
            text: "fresh Talk send",
            attachments: [],
            thinkingLevel: "low")
        try await waitUntil("fresh Talk row reaches accepted before history exists") {
            (try? await fixture.store.loadUnresolved().first?.outcome) == .accepted
        }
        await transport.state.setHistoryMessages([
            s3HistoryMessage(role: "user", idempotencyKey: "\(rawID):user"),
        ])

        try await waitUntil("owner confirms exact user history without Chat UI") {
            let unresolved = try? await fixture.store.loadUnresolved()
            let receipts = try? await fixture.store.loadRecentReceipts()
            return unresolved?.isEmpty == true &&
                receipts?.first?.outcome == .canonicalHistoryConfirmed
        }
        #expect(await transport.state.dispatchedIDs() == [rawID])
        await owner.retire()
        try await fixture.close()
    }

    @Test func `shared owner bounds negative confirmation scans`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let transport = S3TestTransport()
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            confirmationDelaysNanoseconds: [0, 0])
        _ = try await owner.enqueue(
            rawCommandID: "talk-bounded-negative-history",
            sessionKey: "main",
            text: "remain ambiguous without replay",
            attachments: [],
            thinkingLevel: "low")

        try await waitUntil("bounded owner confirmation attempts finish") {
            await transport.state.acquireCallCount() == 4
        }
        let boundedRows = try await fixture.store.loadUnresolved()
        #expect(boundedRows.first?.outcome == .accepted)
        #expect(await transport.state.dispatchedIDs() == ["talk-bounded-negative-history"])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await transport.state.acquireCallCount() == 4)
        await owner.retire()
        try await fixture.close()
    }

    @Test func `owner retirement after enqueue admission parks ambiguous`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let dispatchGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setDispatchGate(dispatchGate)
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        _ = try await owner.enqueue(
            rawCommandID: "talk-retire-admitted",
            sessionKey: "main",
            text: "persist first",
            attachments: [],
            thinkingLevel: "low")
        try await waitUntil("owner worker admits dispatch") {
            await transport.state.dispatchedIDs() == ["talk-retire-admitted"]
        }
        let retired = S3TestFlag()
        let retirement = Task {
            await owner.retire()
            await retired.set()
        }
        try await waitUntil("owner retirement fences new wakes") {
            do {
                try await owner.wake()
                return false
            } catch {
                return true
            }
        }
        #expect(!(await retired.get()))
        await dispatchGate.open()
        await retirement.value
        let retiredRows = try await fixture.store.loadUnresolved()
        #expect(retiredRows.first?.outcome == .ambiguous)
        #expect(await transport.state.dispatchedIDs().count == 1)
        try await fixture.close()
    }

    @Test func `retire during enqueue still reports the one committed gateway row`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let acquireGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setAcquireGate(acquireGate)
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport)
        let enqueueTask = Task {
            try await owner.enqueue(
                rawCommandID: "talk-retire-enqueue",
                sessionKey: "main",
                text: "one gateway only",
                attachments: [],
                thinkingLevel: "low")
        }
        try await waitUntil("enqueue waits on route evidence") {
            await transport.state.acquireCallCount() == 1
        }
        let retired = S3TestFlag()
        let retirement = Task {
            await owner.retire()
            await retired.set()
        }
        try await waitUntil("retirement fences enqueue replacement") {
            do {
                try await owner.wake()
                return false
            } catch {
                return true
            }
        }
        #expect(!(await retired.get()))
        await acquireGate.open()
        let committed = try await enqueueTask.value
        await retirement.value
        #expect(committed.rawCommandID == "talk-retire-enqueue")
        let committedRows = try await fixture.store.loadUnresolved()
        #expect(committedRows.map(\.rawCommandID) == ["talk-retire-enqueue"])

        let replacementStore = try await fixture.database.store(stableGatewayID: "gateway-replacement")
        let replacementRows = try await replacementStore.loadUnresolved()
        #expect(replacementRows.isEmpty)
        try await fixture.close()
    }

    @Test func `retire waits for admitted capture route verification`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let acquireGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setAcquireGate(acquireGate)
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            confirmationDelaysNanoseconds: [])
        let admission = Task { try await owner.admitCapture() }
        try await waitUntil("capture admission waits on live route") {
            await transport.state.acquireCallCount() == 1
        }
        let retired = S3TestFlag()
        let retirement = Task {
            await owner.retire()
            await retired.set()
        }
        try await waitUntil("capture owner is fenced while retirement waits") {
            do {
                try await owner.wake()
                return false
            } catch {
                return true
            }
        }
        #expect(!(await retired.get()))
        await acquireGate.open()
        await #expect(throws: OpenClawChatOutboxError.self) {
            _ = try await admission.value
        }
        await retirement.value
        #expect(await retired.get())
        try await fixture.close()
    }

    @Test func `destructive session action waits for admitted enqueue and then refuses reset`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let acquireGate = S3TestGate()
        let transport = S3TestTransport()
        await transport.state.setDispatchOutcomes([.notDispatched])
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            confirmationDelaysNanoseconds: [])
        let captureAdmission = try await owner.admitCapture()
        await transport.state.setAcquireGate(acquireGate)
        let enqueue = Task {
            try await owner.enqueue(
                rawCommandID: "talk-before-reset",
                sessionKey: "main",
                text: "must survive",
                attachments: [],
                thinkingLevel: "low",
                expectedDestructiveSessionAdmissionToken:
                    captureAdmission.destructiveSessionAdmissionToken,
                expectedCaptureRouteSnapshot: captureAdmission.routeSnapshot)
        }
        try await waitUntil("enqueue is admitted before reset") {
            await transport.state.acquireCallCount() == 2
        }
        let destructive = Task {
            try await owner.performDestructiveSessionAction {
                await transport.state.recordResetCall()
            }
        }
        await acquireGate.open()
        _ = try await enqueue.value
        await #expect(throws: OpenClawChatOutboxDeliveryOwnerError.self) {
            try await destructive.value
        }
        #expect(await transport.state.resetCallCount() == 0)
        let refusedRows = try await fixture.store.loadUnresolved()
        let tokenAfterRefusal = try await owner.destructiveSessionAdmissionToken()
        #expect(refusedRows.count == 1)
        #expect(tokenAfterRefusal == captureAdmission.destructiveSessionAdmissionToken)

        try await waitUntil("refused reset leaves captured row safely cancellable") {
            (try? await owner.currentOutcome(rawCommandID: "talk-before-reset")) == .notDispatched
        }
        try await owner.cancelProvablyUnaccepted(rawCommandID: "talk-before-reset")
        let committedAfterRefusal = try await owner.enqueue(
            rawCommandID: "talk-captured-before-refused-reset",
            sessionKey: "main",
            text: "capture remains admitted",
            attachments: [],
            thinkingLevel: "low",
            expectedDestructiveSessionAdmissionToken:
                captureAdmission.destructiveSessionAdmissionToken,
            expectedCaptureRouteSnapshot: captureAdmission.routeSnapshot)
        #expect(committedAfterRefusal.rawCommandID == "talk-captured-before-refused-reset")
        await owner.retire()
        try await fixture.close()
    }

    @Test
    @MainActor
    func `new session barrier refuses create when an admitted Talk enqueue commits`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let acquireGate = S3TestGate()
        let transport = S3TestTransport()
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            confirmationDelaysNanoseconds: [])
        let captureAdmission = try await owner.admitCapture()
        await transport.state.setAcquireGate(acquireGate)
        let enqueue = Task {
            try await owner.enqueue(
                rawCommandID: "talk-before-new",
                sessionKey: "main",
                text: "must not cross session creation",
                attachments: [],
                thinkingLevel: "low",
                expectedDestructiveSessionAdmissionToken:
                    captureAdmission.destructiveSessionAdmissionToken,
                expectedCaptureRouteSnapshot: captureAdmission.routeSnapshot)
        }
        try await waitUntil("Talk enqueue is admitted before new-session barrier") {
            await transport.state.acquireCallCount() == 2
        }
        let vm = OpenClawChatViewModel(
            sessionKey: "main",
            transport: transport,
            outboxDeliveryOwner: owner)
        vm.input = "/new"
        let create = Task { @MainActor in
            await vm._test_performStartNewSession(preserving: "/new")
        }
        try await waitUntil("new-session action waits for admitted Talk enqueue") {
            do {
                _ = try await owner.destructiveSessionAdmissionToken()
                return false
            } catch let error as OpenClawChatOutboxDeliveryOwnerError {
                return error == .destructiveSessionActionInProgress
            } catch {
                return false
            }
        }

        await acquireGate.open()
        _ = try await enqueue.value
        await create.value

        #expect(await transport.state.createCallCount() == 0)
        #expect(vm.sessionKey == "main")
        #expect(vm.input == "/new")
        #expect(vm.errorText?.localizedCaseInsensitiveContains("queued") == true)
        let tokenAfterRefusal = try await owner.destructiveSessionAdmissionToken()
        #expect(tokenAfterRefusal == captureAdmission.destructiveSessionAdmissionToken)
        vm.shutdown()
        await owner.retire()
        try await fixture.close()
    }

    @Test
    @MainActor
    func `successful new session rotates the owner token before create`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let transport = S3TestTransport()
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: transport,
            confirmationDelaysNanoseconds: [])
        let captureAdmission = try await owner.admitCapture()
        let vm = OpenClawChatViewModel(
            sessionKey: "main",
            transport: transport,
            outboxDeliveryOwner: owner)

        await vm._test_performStartNewSession(preserving: "/new")

        #expect(await transport.state.createCallCount() == 1)
        #expect(vm.sessionKey.hasPrefix("ios-"))
        let tokenAfterCreate = try await owner.destructiveSessionAdmissionToken()
        #expect(tokenAfterCreate != captureAdmission.destructiveSessionAdmissionToken)
        await #expect(throws: OpenClawChatOutboxDeliveryOwnerError.self) {
            _ = try await owner.enqueue(
                rawCommandID: "stale-capture-after-new",
                sessionKey: "main",
                text: "must not enqueue",
                attachments: [],
                thinkingLevel: "low",
                expectedDestructiveSessionAdmissionToken:
                    captureAdmission.destructiveSessionAdmissionToken,
                expectedCaptureRouteSnapshot: captureAdmission.routeSnapshot)
        }
        vm.shutdown()
        await owner.retire()
        try await fixture.close()
    }

    @Test func `replacement owner rejects an admission token captured by its predecessor`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let firstOwner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: S3TestTransport(),
            confirmationDelaysNanoseconds: [])
        let staleToken = try await firstOwner.destructiveSessionAdmissionToken()
        await firstOwner.retire()

        let replacementOwner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: S3TestTransport(),
            confirmationDelaysNanoseconds: [])
        let replacementToken = try await replacementOwner.destructiveSessionAdmissionToken()
        #expect(replacementToken != staleToken)
        await #expect(throws: OpenClawChatOutboxDeliveryOwnerError.self) {
            _ = try await replacementOwner.enqueue(
                rawCommandID: "talk-from-retired-owner",
                sessionKey: "main",
                text: "must be reviewed",
                attachments: [],
                thinkingLevel: "low",
                expectedDestructiveSessionAdmissionToken: staleToken)
        }
        let replacementRows = try await fixture.store.loadUnresolved()
        #expect(replacementRows.isEmpty)
        await replacementOwner.retire()
        try await fixture.close()
    }

    @Test func `destructive session lease rejects concurrent and pre-reset Talk admission`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let actionGate = S3TestGate()
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: S3TestTransport(),
            confirmationDelaysNanoseconds: [])
        let capturedAdmissionToken = try await owner.destructiveSessionAdmissionToken()
        let destructive = Task {
            try await owner.performDestructiveSessionAction {
                await actionGate.wait()
            }
        }
        try await waitUntil("destructive session action owns admission") {
            await actionGate.waiterCount() == 1
        }

        await #expect(throws: OpenClawChatOutboxDeliveryOwnerError.self) {
            _ = try await owner.enqueue(
                rawCommandID: "talk-during-reset",
                sessionKey: "main",
                text: "blocked during reset",
                attachments: [],
                thinkingLevel: "low")
        }
        await actionGate.open()
        try await destructive.value
        await #expect(throws: OpenClawChatOutboxDeliveryOwnerError.self) {
            _ = try await owner.enqueue(
                rawCommandID: "talk-captured-before-reset",
                sessionKey: "main",
                text: "old capture",
                attachments: [],
                thinkingLevel: "low",
                expectedDestructiveSessionAdmissionToken: capturedAdmissionToken)
        }
        let destructiveRows = try await fixture.store.loadUnresolved()
        #expect(destructiveRows.isEmpty)
        await owner.retire()
        try await fixture.close()
    }

    @Test
    @MainActor
    func `session switch before destructive admission preserves capture and has zero effect`() async throws {
        for action in ["reset", "compact"] {
            let fixture = try await S3TestStoreFixture.make()
            let routeGate = S3TestGate()
            let transport = S3TestTransport()
            let owner = OpenClawChatOutboxDeliveryOwner(
                store: fixture.store,
                stableGatewayID: "gateway-test",
                transport: transport,
                confirmationDelaysNanoseconds: [])
            let capturedAdmission = try await owner.admitCapture()
            await transport.state.setAcquireGate(routeGate)
            let holdingAdmission = Task { try await owner.admitCapture() }
            try await waitUntil("capture admission holds (action) before destructive preflight") {
                await transport.state.acquireCallCount() == 2
            }
            let vm = OpenClawChatViewModel(
                sessionKey: "main",
                transport: transport,
                outboxDeliveryOwner: owner)
            vm.input = "/\(action)"
            let mutation = Task { @MainActor in
                if action == "reset" {
                    await vm._test_performReset(preserving: "/reset")
                } else {
                    await vm._test_performCompact(preserving: "/compact")
                }
            }
            try await waitUntil("destructive action waits behind admitted capture") {
                do {
                    _ = try await owner.destructiveSessionAdmissionToken()
                    return false
                } catch let error as OpenClawChatOutboxDeliveryOwnerError {
                    return error == .destructiveSessionActionInProgress
                } catch {
                    return false
                }
            }

            vm.syncSession(to: "other")
            try await waitUntil("other bootstrap settles before destructive admission resumes") {
                await MainActor.run {
                    vm.sessionKey == "other" && !vm.isLoading
                }
            }
            vm.input = "other draft"
            vm.errorText = "other sentinel"
            let otherSubscription = vm._test_eventSubscriptionGeneration()
            await routeGate.open()
            await #expect(throws: OpenClawChatOutboxDeliveryOwnerError.self) {
                _ = try await holdingAdmission.value
            }
            await mutation.value

            #expect(await transport.state.resetCallCount() == 0)
            #expect(await transport.state.compactCallCount() == 0)
            let tokenAfterSessionSwitch = try await owner.destructiveSessionAdmissionToken()
            #expect(tokenAfterSessionSwitch == capturedAdmission.destructiveSessionAdmissionToken)
            #expect(vm.sessionKey == "other")
            #expect(vm.input == "other draft")
            #expect(vm.errorText == "other sentinel")
            #expect(vm._test_eventSubscriptionGeneration() == otherSubscription)

            let committed = try await owner.enqueue(
                rawCommandID: "talk-after-refused-\(action)",
                sessionKey: "main",
                text: "capture remains valid",
                attachments: [],
                thinkingLevel: "low",
                expectedDestructiveSessionAdmissionToken:
                    capturedAdmission.destructiveSessionAdmissionToken,
                expectedCaptureRouteSnapshot: capturedAdmission.routeSnapshot)
            #expect(committed.rawCommandID == "talk-after-refused-\(action)")
            vm.shutdown()
            await owner.retire()
            try await fixture.close()
        }
    }

    @Test
    @MainActor
    func `view shutdown before destructive admission preserves capture and has zero effect`() async throws {
        for action in ["reset", "compact"] {
            let fixture = try await S3TestStoreFixture.make()
            let routeGate = S3TestGate()
            let transport = S3TestTransport()
            let owner = OpenClawChatOutboxDeliveryOwner(
                store: fixture.store,
                stableGatewayID: "gateway-test",
                transport: transport,
                confirmationDelaysNanoseconds: [])
            let capturedAdmission = try await owner.admitCapture()
            await transport.state.setAcquireGate(routeGate)
            let holdingAdmission = Task { try await owner.admitCapture() }
            try await waitUntil("capture admission holds (action) before shutdown preflight") {
                await transport.state.acquireCallCount() == 2
            }
            let vm = OpenClawChatViewModel(
                sessionKey: "main",
                transport: transport,
                outboxDeliveryOwner: owner)
            let mutation = Task { @MainActor in
                if action == "reset" {
                    await vm._test_performReset(preserving: "/reset")
                } else {
                    await vm._test_performCompact(preserving: "/compact")
                }
            }
            try await waitUntil("destructive action waits behind capture before shutdown") {
                do {
                    _ = try await owner.destructiveSessionAdmissionToken()
                    return false
                } catch let error as OpenClawChatOutboxDeliveryOwnerError {
                    return error == .destructiveSessionActionInProgress
                } catch {
                    return false
                }
            }
            vm.shutdown()
            let shutdownSubscription = vm._test_eventSubscriptionGeneration()
            await routeGate.open()
            await #expect(throws: OpenClawChatOutboxDeliveryOwnerError.self) {
                _ = try await holdingAdmission.value
            }
            await mutation.value

            #expect(await transport.state.resetCallCount() == 0)
            #expect(await transport.state.compactCallCount() == 0)
            #expect(vm._test_eventSubscriptionGeneration() == shutdownSubscription)
            let tokenAfterShutdown = try await owner.destructiveSessionAdmissionToken()
            #expect(tokenAfterShutdown == capturedAdmission.destructiveSessionAdmissionToken)
            let committed = try await owner.enqueue(
                rawCommandID: "talk-after-shutdown-\(action)",
                sessionKey: "main",
                text: "capture remains valid",
                attachments: [],
                thinkingLevel: "low",
                expectedDestructiveSessionAdmissionToken:
                    capturedAdmission.destructiveSessionAdmissionToken,
                expectedCaptureRouteSnapshot: capturedAdmission.routeSnapshot)
            #expect(committed.rawCommandID == "talk-after-shutdown-\(action)")
            await owner.retire()
            try await fixture.close()
        }
    }

    @Test func `owner retirement waits for admitted destructive session action`() async throws {
        let fixture = try await S3TestStoreFixture.make()
        let actionGate = S3TestGate()
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: fixture.store,
            stableGatewayID: "gateway-test",
            transport: S3TestTransport(),
            confirmationDelaysNanoseconds: [])
        let destructive = Task {
            try await owner.performDestructiveSessionAction {
                await actionGate.wait()
            }
        }
        try await waitUntil("destructive action reaches network gate") {
            await actionGate.waiterCount() == 1
        }
        let retired = S3TestFlag()
        let retirement = Task {
            await owner.retire()
            await retired.set()
        }
        try await waitUntil("retirement rejects new work while waiting on action") {
            do {
                try await owner.wake()
                return false
            } catch {
                return true
            }
        }
        #expect(!(await retired.get()))
        await actionGate.open()
        try await destructive.value
        await retirement.value
        try await fixture.close()
    }

    @Test @MainActor func `reset and compact preserve commands for every unresolved outcome`() async throws {
        for outcome in [
            OpenClawChatOutboxOutcome.notDispatched,
            .dispatchRejected,
            .accepted,
            .ambiguous,
            .blockedRouteChanged,
        ] {
            let fixture = try await S3TestStoreFixture.make()
            let route = s3Route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            let rawID = "destructive-guard-\(outcome.rawValue)"
            _ = try await fixture.store.persistBeforeDraftClear(
                s3Draft(rawCommandID: rawID, route: route))
            if outcome != .notDispatched {
                let claimed = try await fixture.store.claimNext()
                let claim = try #require(claimed)
                _ = try await fixture.store.recordDispatchOutcome(
                    outcome,
                    for: claim,
                    ackRunID: outcome == .accepted ? rawID : nil)
            }
            let transport = S3TestTransport()
            await transport.state.setUnavailable(.routeUnavailable)
            let owner = OpenClawChatOutboxDeliveryOwner(
                store: fixture.store,
                stableGatewayID: "gateway-test",
                transport: transport,
                confirmationDelaysNanoseconds: [])
            let vm = OpenClawChatViewModel(
                sessionKey: "main",
                transport: transport,
                outboxDeliveryOwner: owner)

            vm.input = "/reset"
            vm.send()
            try await waitUntil("reset is refused for \(outcome.rawValue)") {
                await MainActor.run {
                    vm.input == "/reset" && vm.errorText?.contains("queued messages") == true
                }
            }
            #expect(await transport.state.resetCallCount() == 0)

            vm.errorText = nil
            vm.input = "/compact"
            vm.send()
            try await waitUntil("compact is refused for \(outcome.rawValue)") {
                await MainActor.run {
                    vm.input == "/compact" && vm.errorText?.contains("queued messages") == true
                }
            }
            #expect(await transport.state.compactCallCount() == 0)
            let preserved = try await fixture.store.loadUnresolved()
            #expect(preserved.map(\.rawCommandID) == [rawID])
            #expect(preserved.first?.outcome == outcome)
            vm.shutdown()
            await owner.retire()
            try await fixture.close()
        }
    }
}
