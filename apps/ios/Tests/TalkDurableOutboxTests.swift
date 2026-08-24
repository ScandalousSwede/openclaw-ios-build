import AVFAudio
import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import OpenClaw

private enum DurableTalkTestError: Error {
    case rejected
}

private struct DurableTalkSendResponsePayload: Encodable {
    let runId: String
    let status: String
}

private func durableTalkSendResponse(
    runID: String,
    status: String) throws -> OpenClawChatSendResponse
{
    let payload = DurableTalkSendResponsePayload(runId: runID, status: status)
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(OpenClawChatSendResponse.self, from: data)
}

private actor DurableTalkGate {
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

private actor DurableTalkRequestRecorder {
    private var requests: [TalkDurableChatRequest] = []

    func append(_ request: TalkDurableChatRequest) {
        self.requests.append(request)
    }

    func snapshot() -> [TalkDurableChatRequest] { self.requests }
}

private actor DurableTalkAdmissionProvider {
    private let token: UUID
    private let gate: DurableTalkGate?
    private let gatedCall: Int
    private var calls = 0

    init(token: UUID = UUID(), gate: DurableTalkGate? = nil, gatedCall: Int = .max) {
        self.token = token
        self.gate = gate
        self.gatedCall = gatedCall
    }

    func admissionToken() async -> UUID {
        self.calls += 1
        if self.calls == self.gatedCall {
            await self.gate?.wait()
        }
        return self.token
    }

    func callCount() -> Int { self.calls }
}

private actor DurableTalkNodeStoreProvider {
    private var stores: [String: OpenClawChatOutboxStore]
    private var gates: [String: DurableTalkGate]
    private var calls: [String: Int] = [:]

    init(
        stores: [String: OpenClawChatOutboxStore],
        gates: [String: DurableTalkGate] = [:])
    {
        self.stores = stores
        self.gates = gates
    }

    func store(for stableGatewayID: String) async throws -> OpenClawChatOutboxStore {
        self.calls[stableGatewayID, default: 0] += 1
        if let gate = self.gates[stableGatewayID] {
            await gate.wait()
        }
        guard let store = self.stores[stableGatewayID] else {
            throw OpenClawChatOutboxError.storageUnavailable
        }
        return store
    }

    func callCount(for stableGatewayID: String) -> Int {
        self.calls[stableGatewayID, default: 0]
    }
}

private final class DurableTalkOfflineTransport: @unchecked Sendable, OpenClawChatTransport {
    private let eventStream = AsyncStream<OpenClawChatTransportEvent> { $0.finish() }

    func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult {
        .unavailable(reason: .routeUnavailable)
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        OpenClawChatHistoryPayload(
            sessionKey: sessionKey,
            sessionId: "talk-test",
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
        try durableTalkSendResponse(runID: idempotencyKey, status: "legacy")
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool { true }
    func setSessionModel(sessionKey _: String, model _: String?) async throws {}
    func events() -> AsyncStream<OpenClawChatTransportEvent> { self.eventStream }
}

private actor DurableTalkConnectionState {
    private var connected = true
    private var routingContract = "per-sender|main|main"
    private var capabilities = [OpenClawChatOutboxDatabase.routingCapability]
    private var operatorScopes = OpenClawChatOutboxDatabase.requiredOperatorScopes
    private var acquireCalls = 0
    private var dispatchedRawIDs: [String] = []

    func setConnected(_ connected: Bool) {
        self.connected = connected
    }

    func isConnected() -> Bool { self.connected }

    func setRoutingContract(_ routingContract: String) {
        self.routingContract = routingContract
    }

    func setCapabilities(_ capabilities: [String]) {
        self.capabilities = capabilities
    }

    func setOperatorScopes(_ operatorScopes: [String]) {
        self.operatorScopes = operatorScopes
    }

    func route() -> (
        connected: Bool,
        routingContract: String,
        capabilities: [String],
        operatorScopes: [String])
    {
        self.acquireCalls += 1
        return (self.connected, self.routingContract, self.capabilities, self.operatorScopes)
    }

    func recordDispatch(_ rawCommandID: String) {
        self.dispatchedRawIDs.append(rawCommandID)
    }

    func acquisitionCallCount() -> Int { self.acquireCalls }
    func dispatchedIDs() -> [String] { self.dispatchedRawIDs }
}

private final class DurableTalkSwitchableTransport: @unchecked Sendable, OpenClawChatTransport {
    let connection = DurableTalkConnectionState()
    private let stableGatewayID: String
    private let eventStream = AsyncStream<OpenClawChatTransportEvent> { $0.finish() }

    init(stableGatewayID: String) {
        self.stableGatewayID = stableGatewayID
    }

    func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult {
        let route = await self.connection.route()
        guard route.connected else {
            return .unavailable(reason: .routeUnavailable)
        }
        return .available(OpenClawChatTransportRouteLease(
            stableGatewayID: self.stableGatewayID,
            sessionRoutingContract: route.routingContract,
            capabilities: route.capabilities,
            operatorScopes: route.operatorScopes,
            dispatchMessage: { [connection] _, _, _, rawCommandID, _ in
                await connection.recordDispatch(rawCommandID)
                return .accepted(runID: rawCommandID, status: "started")
            },
            requestHistoryPage: { sessionKey, _, offset, _ in
                OpenClawChatHistoryPage(
                    payload: OpenClawChatHistoryPayload(
                        sessionKey: sessionKey,
                        sessionId: "talk-test",
                        messages: [],
                        thinkingLevel: "off"),
                    offset: offset,
                    nextOffset: nil,
                    hasMore: false,
                    totalMessages: 0)
            }))
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        OpenClawChatHistoryPayload(
            sessionKey: sessionKey,
            sessionId: "talk-test",
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
        try durableTalkSendResponse(runID: idempotencyKey, status: "started")
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool { await self.connection.isConnected() }
    func setSessionModel(sessionKey _: String, model _: String?) async throws {}
    func events() -> AsyncStream<OpenClawChatTransportEvent> { self.eventStream }
}

private actor DurableTalkAcceptedTransportState {
    let autoConfirmHistory: Bool
    private var rawCommandID: String?

    init(autoConfirmHistory: Bool) {
        self.autoConfirmHistory = autoConfirmHistory
    }

    func dispatch(rawCommandID: String) -> OpenClawChatDispatchOutcome {
        self.rawCommandID = rawCommandID
        return .accepted(runID: rawCommandID, status: "started")
    }

    func historyMessages() -> [AnyCodable] {
        guard self.autoConfirmHistory, let rawCommandID else { return [] }
        let message: [String: Any] = [
            "role": "user",
            "content": [["type": "text", "text": "confirmed"]],
            "timestamp": Date().timeIntervalSince1970,
            "idempotencyKey": "\(rawCommandID):user",
        ]
        return [AnyCodable(message)]
    }

    func dispatchedRawCommandID() -> String? { self.rawCommandID }
}

private final class DurableTalkAcceptedTransport: @unchecked Sendable, OpenClawChatTransport {
    private let stableGatewayID: String
    private let state: DurableTalkAcceptedTransportState
    private let eventStream = AsyncStream<OpenClawChatTransportEvent> { $0.finish() }

    init(stableGatewayID: String, autoConfirmHistory: Bool = false) {
        self.stableGatewayID = stableGatewayID
        self.state = DurableTalkAcceptedTransportState(autoConfirmHistory: autoConfirmHistory)
    }

    func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult {
        .available(OpenClawChatTransportRouteLease(
            stableGatewayID: self.stableGatewayID,
            sessionRoutingContract: "per-sender|main|main",
            capabilities: [OpenClawChatOutboxDatabase.routingCapability],
            operatorScopes: OpenClawChatOutboxDatabase.requiredOperatorScopes,
            dispatchMessage: { [state] _, _, _, rawCommandID, _ in
                await state.dispatch(rawCommandID: rawCommandID)
            },
            requestHistoryPage: { [state] sessionKey, _, offset, _ in
                let messages = await state.historyMessages()
                return OpenClawChatHistoryPage(
                    payload: OpenClawChatHistoryPayload(
                        sessionKey: sessionKey,
                        sessionId: "talk-test",
                        messages: messages,
                        thinkingLevel: "off"),
                    offset: offset,
                    nextOffset: nil,
                    hasMore: false,
                    totalMessages: messages.count)
            }))
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        OpenClawChatHistoryPayload(
            sessionKey: sessionKey,
            sessionId: "talk-test",
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
        try durableTalkSendResponse(runID: idempotencyKey, status: "started")
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool { true }
    func setSessionModel(sessionKey _: String, model _: String?) async throws {}
    func events() -> AsyncStream<OpenClawChatTransportEvent> { self.eventStream }

    func dispatchedRawCommandID() async -> String? {
        await self.state.dispatchedRawCommandID()
    }
}

private final class DurableTalkEventSource: @unchecked Sendable {
    let stream: AsyncStream<EventFrame>
    private let continuation: AsyncStream<EventFrame>.Continuation

    init() {
        (self.stream, self.continuation) = AsyncStream.makeStream(
            of: EventFrame.self,
            bufferingPolicy: .bufferingNewest(32))
    }

    func sendChatFinal(runID: String, text: String) {
        self.continuation.yield(EventFrame(
            type: "event",
            event: "chat",
            payload: AnyCodable([
                "runId": AnyCodable(runID),
                "sessionKey": AnyCodable("main"),
                "state": AnyCodable("final"),
                "message": AnyCodable([
                    "role": AnyCodable("assistant"),
                    "content": AnyCodable(text),
                ]),
            ]),
            seq: 1,
            stateversion: nil))
    }

    func sendAgentAssistant(runID: String, text: String, sequence: Int = 1) {
        self.continuation.yield(EventFrame(
            type: "event",
            event: "agent",
            payload: AnyCodable([
                "runId": AnyCodable(runID),
                "seq": AnyCodable(sequence),
                "stream": AnyCodable("assistant"),
                "ts": AnyCodable(Int(Date().timeIntervalSince1970 * 1000)),
                "data": AnyCodable(["text": AnyCodable(text)]),
            ]),
            seq: sequence,
            stateversion: nil))
    }

    func finish() {
        self.continuation.finish()
    }
}

private final class DurableTalkEventObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String?, Bool)] = []

    func record(runID: String?, matched: Bool) {
        self.lock.lock()
        self.values.append((runID, matched))
        self.lock.unlock()
    }

    func contains(runID: String, matched: Bool) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.contains { $0.0 == runID && $0.1 == matched }
    }

    func count(runID: String, matched: Bool) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.filter { $0.0 == runID && $0.1 == matched }.count
    }
}

private final class DurableTalkResponseExitObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UInt64] = []

    func record(_ generation: UInt64) {
        self.lock.lock()
        self.generations.append(generation)
        self.lock.unlock()
    }

    func count() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.generations.count
    }
}

@MainActor
private final class DurableTalkSystemSpeechSpy: TalkSystemSpeechProviding {
    private(set) var spokenTexts: [String] = []
    private(set) var stopCount = 0

    func speak(text: String, language _: String?, onStart: (() -> Void)?) async throws {
        self.spokenTexts.append(text)
        onStart?()
    }

    func stop() {
        self.stopCount += 1
    }
}

@MainActor
private final class DurableTalkBlockingSystemSpeech: TalkSystemSpeechProviding {
    private(set) var spokenTexts: [String] = []
    private(set) var stopCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func speak(text: String, language _: String?, onStart: (() -> Void)?) async throws {
        self.spokenTexts.append(text)
        onStart?()
        await withCheckedContinuation { self.continuation = $0 }
    }

    func stop() {
        self.stopCount += 1
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private struct DurableTalkOutboxFixture {
    let directory: URL
    let database: OpenClawChatOutboxDatabase
    let store: OpenClawChatOutboxStore
    let owner: OpenClawChatOutboxDeliveryOwner

    static func make(
        stableGatewayID: String = "gateway-talk",
        transport: (any OpenClawChatTransport)? = nil,
        seedVerifiedRouteSnapshot: Bool = true,
        confirmationDelaysNanoseconds: [UInt64] = []) async throws -> Self
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-talk-outbox-\(UUID().uuidString)", isDirectory: true)
        let database = try OpenClawChatOutboxDatabase(
            databaseURL: directory.appendingPathComponent(
                OpenClawChatOutboxDatabase.databaseFilename,
                isDirectory: false))
        let store = try await database.store(stableGatewayID: stableGatewayID)
        if seedVerifiedRouteSnapshot {
            try await store.saveVerifiedRouteSnapshot(OpenClawChatOutboxRouteSnapshot(
                routingContract: "per-sender|main|main",
                capabilities: [OpenClawChatOutboxDatabase.routingCapability],
                operatorScopes: OpenClawChatOutboxDatabase.requiredOperatorScopes,
                verifiedAt: Date()))
        }
        let owner = OpenClawChatOutboxDeliveryOwner(
            store: store,
            stableGatewayID: stableGatewayID,
            transport: transport ?? DurableTalkOfflineTransport(),
            confirmationDelaysNanoseconds: confirmationDelaysNanoseconds)
        return Self(directory: directory, database: database, store: store, owner: owner)
    }

    func close() async throws {
        await self.owner.retire()
        try await self.database.close()
        try FileManager.default.removeItem(at: self.directory)
    }
}

private func finishedEventStream() -> AsyncStream<EventFrame> {
    AsyncStream { $0.finish() }
}

private func persistDurableTalk(
    _ request: TalkDurableChatRequest,
    owner: OpenClawChatOutboxDeliveryOwner,
    gatewayEvents: AsyncStream<EventFrame>? = nil,
    incrementalEvents: AsyncStream<EventFrame>? = nil) async throws -> TalkDurableChatPersistence
{
    let updates = await owner.updates()
    _ = try await owner.enqueue(
        rawCommandID: request.rawCommandID,
        sessionKey: request.sessionKey,
        text: request.message,
        attachments: [],
        thinkingLevel: request.thinkingLevel,
        expectedDestructiveSessionAdmissionToken: request.destructiveSessionAdmissionToken,
        expectedCaptureRouteSnapshot: request.captureRouteSnapshot)
    return TalkDurableChatPersistence(
        request: request,
        ownerGeneration: 1,
        owner: owner,
        gatewayEvents: gatewayEvents ?? finishedEventStream(),
        incrementalEvents: incrementalEvents ?? finishedEventStream(),
        outboxUpdates: updates)
}

private func durableTalkCaptureAdmission(
    token: UUID,
    routingContract: String = "per-sender|main|main") -> OpenClawChatOutboxCaptureAdmission
{
    OpenClawChatOutboxCaptureAdmission(
        destructiveSessionAdmissionToken: token,
        routeSnapshot: OpenClawChatOutboxRouteSnapshot(
            routingContract: routingContract,
            capabilities: [OpenClawChatOutboxDatabase.routingCapability],
            operatorScopes: OpenClawChatOutboxDatabase.requiredOperatorScopes,
            verifiedAt: Date()))
}

private var durableTalkSpeakerRoute: TalkAudioRouteEvidence {
    TalkAudioRouteEvidence(
        outputPortTypes: [AVAudioSession.Port.builtInSpeaker.rawValue],
        outputNames: ["iPhone Speaker"],
        speakerphonePreferred: true,
        category: AVAudioSession.Category.playAndRecord.rawValue,
        mode: AVAudioSession.Mode.spokenAudio.rawValue,
        activation: .active)
}

private func waitForDurableTalk(
    _ description: String,
    iterations: Int = 500,
    condition: @escaping @Sendable () async -> Bool) async throws
{
    for _ in 0..<iterations {
        if await condition() { return }
        await Task.yield()
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw NSError(domain: "TalkDurableOutboxTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Timed out: \(description)",
    ])
}

@MainActor
private func withDurableTalkNodeModel<T>(
    _ body: @MainActor (NodeAppModel) async throws -> T) async rethrows -> T
{
    let talkKey = "talk.enabled"
    let voiceWakeKey = "voiceWake.enabled"
    let previousTalk = UserDefaults.standard.object(forKey: talkKey)
    let previousVoiceWake = UserDefaults.standard.object(forKey: voiceWakeKey)
    UserDefaults.standard.set(false, forKey: talkKey)
    UserDefaults.standard.set(false, forKey: voiceWakeKey)
    defer {
        if let previousTalk {
            UserDefaults.standard.set(previousTalk, forKey: talkKey)
        } else {
            UserDefaults.standard.removeObject(forKey: talkKey)
        }
        if let previousVoiceWake {
            UserDefaults.standard.set(previousVoiceWake, forKey: voiceWakeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: voiceWakeKey)
        }
    }
    let model = NodeAppModel(talkMode: TalkModeManager(allowSimulatorCapture: true))
    defer {
        model.talkMode.isEnabled = false
        model.voiceWake.setEnabled(false)
    }
    return try await body(model)
}

@MainActor
private func withBackgroundTalkOptIn<T>(
    _ body: @MainActor () async throws -> T) async rethrows -> T
{
    let key = "talk.background.enabled"
    let previous = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(true, forKey: key)
    defer {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    return try await body()
}

@MainActor
@Suite("S3.1 durable Talk outbox", .serialized)
struct TalkDurableOutboxTests {
    @Test func transientChatPreparationFailureCanRetrySameOwnerWithoutLooping() {
        var retry = ChatPreparationRetryState()
        let initialTaskID = retry.taskID(owner: "gateway-a", ownerGeneration: 7)

        // A reconnect after a failed open (no attached view model) changes the
        // SwiftUI task identity exactly once for that reconnect edge.
        retry.gatewayDidConnect(hasAttachedViewModel: false)
        let reconnectTaskID = retry.taskID(owner: "gateway-a", ownerGeneration: 7)
        #expect(reconnectTaskID != initialTaskID)

        // A healthy attached view refreshes in place and cannot create a retry loop.
        retry.gatewayDidConnect(hasAttachedViewModel: true)
        #expect(retry.taskID(owner: "gateway-a", ownerGeneration: 7) == reconnectTaskID)

        // The visible Retry control remains an explicit bounded second seam.
        retry.request()
        #expect(retry.taskID(owner: "gateway-a", ownerGeneration: 7) != reconnectTaskID)
    }

    @Test func concurrentNodeOwnerRequestsForSameGatewayConvergeToOneIdentity() async throws {
        let fixture = try await DurableTalkOutboxFixture.make(stableGatewayID: "gateway-a")
        let openGate = DurableTalkGate()
        let provider = DurableTalkNodeStoreProvider(
            stores: ["gateway-a": fixture.store],
            gates: ["gateway-a": openGate])
        try await withDurableTalkNodeModel { appModel in
            appModel._test_configureChatOutbox(
                stableGatewayID: "gateway-a",
                storeProvider: { try await provider.store(for: $0) },
                transportProvider: { _ in DurableTalkOfflineTransport() })
            let first = Task { @MainActor in
                try await appModel.chatOutboxDelivery(stableGatewayID: "gateway-a")
            }
            try await waitForDurableTalk(
                "first owner open suspends",
                iterations: 3_000
            ) {
                await provider.callCount(for: "gateway-a") == 1
            }
            let second = Task { @MainActor in
                try await appModel.chatOutboxDelivery(stableGatewayID: "gateway-a")
            }
            try await waitForDurableTalk(
                "second same-owner open suspends",
                iterations: 3_000
            ) {
                await provider.callCount(for: "gateway-a") == 2
            }
            await openGate.open()
            let firstOwner = try await first.value
            let secondOwner = try await second.value
            #expect(firstOwner === secondOwner)
            let state = appModel._test_chatOutboxOwnerState()
            #expect(state.owner === firstOwner)
            #expect(state.stableGatewayID == "gateway-a")
            await appModel._test_retireChatOutboxDeliveryOwner()
        }
        try await fixture.close()
    }

    @Test func staleNodeOwnerSelectionCannotReplaceNewGatewayOwner() async throws {
        let fixture = try await DurableTalkOutboxFixture.make(stableGatewayID: "gateway-a")
        let storeB = try await fixture.database.store(stableGatewayID: "gateway-b")
        let openAGate = DurableTalkGate()
        let provider = DurableTalkNodeStoreProvider(
            stores: ["gateway-a": fixture.store, "gateway-b": storeB],
            gates: ["gateway-a": openAGate])
        try await withDurableTalkNodeModel { appModel in
            appModel._test_configureChatOutbox(
                stableGatewayID: "gateway-a",
                storeProvider: { try await provider.store(for: $0) },
                transportProvider: { _ in DurableTalkOfflineTransport() })
            let staleA = Task { @MainActor in
                try await appModel.chatOutboxDelivery(stableGatewayID: "gateway-a")
            }
            try await waitForDurableTalk(
                "A owner open suspends",
                iterations: 3_000
            ) {
                await provider.callCount(for: "gateway-a") == 1
            }

            appModel._test_setChatOutboxGatewayOwnerID("gateway-b")
            let ownerB = try await appModel.chatOutboxDelivery(stableGatewayID: "gateway-b")
            await openAGate.open()
            await #expect(throws: Error.self) {
                _ = try await staleA.value
            }

            let state = appModel._test_chatOutboxOwnerState()
            #expect(state.owner === ownerB)
            #expect(state.stableGatewayID == "gateway-b")
            #expect(state.desiredStableGatewayID == "gateway-b")
            await appModel._test_retireChatOutboxDeliveryOwner()
        }
        try await fixture.close()
    }

    @Test func failedNodePurgeDropsPoisonedDatabaseAndReopensCleanly() async throws {
        let firstDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-node-purge-first-\(UUID().uuidString)", isDirectory: true)
        let secondDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-node-purge-second-\(UUID().uuidString)", isDirectory: true)
        let firstDatabase = try OpenClawChatOutboxDatabase(
            databaseURL: firstDirectory.appendingPathComponent(
                OpenClawChatOutboxDatabase.databaseFilename))
        let secondDatabase = try OpenClawChatOutboxDatabase(
            databaseURL: secondDirectory.appendingPathComponent(
                OpenClawChatOutboxDatabase.databaseFilename))
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }

        try await withDurableTalkNodeModel { appModel in
            appModel._test_configureChatOutbox(
                stableGatewayID: "gateway-a",
                storeProvider: nil,
                transportProvider: { _ in DurableTalkOfflineTransport() })
            appModel._test_setChatOutboxDatabase(
                firstDatabase,
                reopenProvider: { secondDatabase })
            let poisonedOwner = try await appModel.chatOutboxDelivery(stableGatewayID: "gateway-a")
            try await firstDatabase.close()
            let generationBeforeFailure = appModel._test_chatOutboxOwnerState().ownerGeneration

            await #expect(throws: Error.self) {
                try await appModel.securePurgeChatOutboxForCredentialReset()
            }
            let failedState = appModel._test_chatOutboxOwnerState()
            #expect(failedState.owner == nil)
            #expect(!failedState.purgeInProgress)
            #expect(!failedState.hasDatabase)
            #expect(failedState.ownerGeneration > generationBeforeFailure)

            let reopenedOwner = try await appModel.chatOutboxDelivery(stableGatewayID: "gateway-a")
            #expect(reopenedOwner !== poisonedOwner)
            let reopenedRows = try await reopenedOwner.unresolvedCommands()
            #expect(reopenedRows.isEmpty)
            let secondStore = try await secondDatabase.store(stableGatewayID: "gateway-a")
            let route = OpenClawChatOutboxRouteSnapshot(
                routingContract: "per-sender|main|main",
                capabilities: [OpenClawChatOutboxDatabase.routingCapability],
                operatorScopes: OpenClawChatOutboxDatabase.requiredOperatorScopes,
                verifiedAt: Date())
            try await secondStore.saveVerifiedRouteSnapshot(route)
            _ = try await secondStore.persistBeforeDraftClear(OpenClawChatOutboxDraft(
                rawCommandID: "purge-me",
                sessionKey: "main",
                text: "do not resurrect",
                thinkingLevel: "off",
                route: route))

            try await appModel.securePurgeChatOutboxForCredentialReset()
            let cleanOwner = try await appModel.chatOutboxDelivery(stableGatewayID: "gateway-a")
            #expect(cleanOwner !== reopenedOwner)
            let cleanRows = try await cleanOwner.unresolvedCommands()
            #expect(cleanRows.isEmpty)
            #expect(!appModel._test_chatOutboxOwnerState().purgeInProgress)
            await appModel._test_retireChatOutboxDeliveryOwner()
        }
        try? await secondDatabase.close()
    }

    @Test func nodeRecoveryDrainsPersistedTalkWithoutChatView() async throws {
        let transport = DurableTalkAcceptedTransport(
            stableGatewayID: "gateway-a",
            autoConfirmHistory: true)
        let fixture = try await DurableTalkOutboxFixture.make(
            stableGatewayID: "gateway-a",
            transport: transport,
            confirmationDelaysNanoseconds: [0, 0])
        let storedRoute = try await fixture.store.loadVerifiedRouteSnapshot()
        let route = try #require(storedRoute)
        _ = try await fixture.store.persistBeforeDraftClear(OpenClawChatOutboxDraft(
            rawCommandID: "cold-talk-row",
            sessionKey: "main",
            text: "recover without Chat",
            thinkingLevel: "off",
            route: route))

        try await withDurableTalkNodeModel { appModel in
            appModel._test_configureChatOutbox(
                stableGatewayID: "gateway-a",
                storeProvider: { _ in fixture.store },
                transportProvider: { _ in transport })
            await appModel._test_startChatOutboxRecovery(
                stableGatewayID: "gateway-a",
                reason: "cold-launch-test")
            try await waitForDurableTalk("Node recovery dispatches without Chat") {
                await transport.dispatchedRawCommandID() == "cold-talk-row"
            }
            try await waitForDurableTalk(
                "Node recovery confirms persisted Talk row",
                iterations: 3_000
            ) {
                (try? await fixture.store.loadUnresolved().isEmpty) == true
            }
            #expect(appModel._test_chatOutboxOwnerState().owner != nil)
            await appModel._test_retireChatOutboxDeliveryOwner()
        }
        try await fixture.close()
    }

    @Test func nodeReconnectWakesOfflinePersistedTalkWithoutChatView() async throws {
        let transport = DurableTalkSwitchableTransport(stableGatewayID: "gateway-a")
        let fixture = try await DurableTalkOutboxFixture.make(
            stableGatewayID: "gateway-a",
            transport: transport)
        let storedRoute = try await fixture.store.loadVerifiedRouteSnapshot()
        let route = try #require(storedRoute)
        _ = try await fixture.store.persistBeforeDraftClear(OpenClawChatOutboxDraft(
            rawCommandID: "reconnect-talk-row",
            sessionKey: "main",
            text: "recover on reconnect",
            thinkingLevel: "off",
            route: route))
        await transport.connection.setConnected(false)

        try await withDurableTalkNodeModel { appModel in
            appModel._test_configureChatOutbox(
                stableGatewayID: "gateway-a",
                storeProvider: { _ in fixture.store },
                transportProvider: { _ in transport })
            await appModel._test_startChatOutboxRecovery(
                stableGatewayID: "gateway-a",
                reason: "cold-offline-test")
            try await waitForDurableTalk("offline Node recovery inspects route") {
                await transport.connection.acquisitionCallCount() >= 1
            }
            #expect(await transport.connection.dispatchedIDs().isEmpty)
            let offlineRows = try await fixture.store.loadUnresolved()
            #expect(offlineRows.map(\.rawCommandID) == ["reconnect-talk-row"])

            await transport.connection.setConnected(true)
            await appModel._test_startChatOutboxRecovery(
                stableGatewayID: "gateway-a",
                reason: "operator-reconnect-test")
            try await waitForDurableTalk("reconnect lifecycle wake dispatches exact row") {
                await transport.connection.dispatchedIDs() == ["reconnect-talk-row"]
            }
            #expect(appModel._test_chatOutboxOwnerState().owner != nil)
            await appModel._test_retireChatOutboxDeliveryOwner()
        }
        try await fixture.close()
    }

    @Test func fullyOfflinePTTStartDoesNotMutateTranscriptOrCreatePendingWork() async {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let admissionToken = UUID()
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager.updateGatewayConnected(false)
        manager._test_seedTranscript("unchanged transcript")

        await #expect(throws: Error.self) {
            try await manager.beginPushToTalk()
        }
        #expect(manager._test_lastTranscript() == "unchanged transcript")
        #expect(manager._test_pendingDurableRequest() == nil)
        #expect(!manager.isPushToTalkActive)
    }

    @Test func concurrentPTTBeginDuringRouteAdmissionCreatesOneCaptureIdentity() async throws {
        let admissionGate = DurableTalkGate()
        let provider = DurableTalkAdmissionProvider(gate: admissionGate, gatedCall: 1)
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(token: await provider.admissionToken())
            },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager.updateGatewayConnected(true)

        let first = Task { @MainActor in try await manager.beginPushToTalk() }
        try await waitForDurableTalk("first PTT begin waits for route admission") {
            await admissionGate.waiterCount() == 1
        }
        await #expect(throws: Error.self) {
            _ = try await manager.beginPushToTalk()
        }
        #expect(await provider.callCount() == 1)
        await admissionGate.open()
        let firstPayload = try await first.value
        let identity = try #require(manager._test_durableCaptureIdentity())
        #expect(firstPayload.captureId == manager._test_activePTTCaptureID())
        #expect(!identity.rawCommandID.isEmpty)
        #expect(await provider.callCount() == 1)
        _ = await manager.cancelPushToTalk()
    }

    @Test func staleRecognitionCallbackCannotCrossIntoReplacementCaptureIdentity() async throws {
        let recorder = DurableTalkRequestRecorder()
        let admissionToken = UUID()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { request in
                await recorder.append(request)
                throw DurableTalkTestError.rejected
            })
        manager.updateGatewayConnected(true)

        _ = try await manager.beginPushToTalk()
        let retiredGeneration = manager._test_recognitionCallbackGeneration()
        let retiredRawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        _ = await manager.cancelPushToTalk()

        _ = try await manager.beginPushToTalk()
        let currentGeneration = manager._test_recognitionCallbackGeneration()
        let currentRawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect(currentGeneration != retiredGeneration)
        #expect(currentRawID != retiredRawID)
        manager._test_seedTranscript("replacement capture")
        manager._test_setPTTAutoStopEnabled(true)

        await manager._test_deliverRecognitionCallback(
            transcript: "late retired partial",
            isFinal: false,
            generation: retiredGeneration)
        await manager._test_deliverRecognitionCallback(
            transcript: "late retired final",
            isFinal: true,
            generation: retiredGeneration)

        #expect(manager._test_lastTranscript() == "replacement capture")
        #expect(manager._test_durableCaptureIdentity()?.rawCommandID == currentRawID)
        #expect(manager.isPushToTalkActive)
        #expect(await recorder.snapshot().isEmpty)

        await manager._test_deliverRecognitionCallback(
            transcript: "current capture partial",
            isFinal: false,
            generation: currentGeneration)
        #expect(manager._test_lastTranscript() == "current capture partial")

        manager._test_setPTTAutoStopEnabled(false)
        _ = await manager.cancelPushToTalk()
    }

    @Test func retiredSilenceAndTimeoutCallbacksCannotEndReplacementCapture() async throws {
        let recorder = DurableTalkRequestRecorder()
        let admissionToken = UUID()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { request in
                await recorder.append(request)
                throw DurableTalkTestError.rejected
            })
        manager.updateGatewayConnected(true)

        _ = try await manager.beginPushToTalk()
        manager._test_seedTranscript("retired capture")
        manager._test_backdateLastHeard(seconds: 30)
        let retiredMonitors = try #require(manager._test_armPTTAutoStopMonitors())
        _ = await manager.cancelPushToTalk()

        _ = try await manager.beginPushToTalk()
        manager._test_seedTranscript("replacement capture")
        manager._test_backdateLastHeard(seconds: 30)
        let replacementRawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        _ = try #require(manager._test_armPTTAutoStopMonitors())

        await manager._test_deliverSilenceMonitorTick(
            generation: retiredMonitors.silenceGeneration,
            transcriptGeneration: retiredMonitors.transcriptGeneration,
            captureID: retiredMonitors.captureID)
        await manager._test_deliverPTTTimeout(
            generation: retiredMonitors.timeoutGeneration,
            captureID: retiredMonitors.captureID)

        #expect(manager.isPushToTalkActive)
        #expect(manager._test_lastTranscript() == "replacement capture")
        #expect(manager._test_durableCaptureIdentity()?.rawCommandID == replacementRawID)
        #expect(await recorder.snapshot().isEmpty)

        manager._test_setPTTAutoStopEnabled(false)
        _ = await manager.cancelPushToTalk()
    }

    @Test func stopOrCancelDuringPTTAdmissionPreventsCaptureResurrection() async throws {
        for action in ["stop", "cancel"] {
            let admissionGate = DurableTalkGate()
            let provider = DurableTalkAdmissionProvider(gate: admissionGate, gatedCall: 1)
            let manager = TalkModeManager(allowSimulatorCapture: true)
            manager.attachDurableChatOutbox(
                gatewayOwnerID: { "gateway-talk" },
                captureAdmission: {
                    durableTalkCaptureAdmission(token: await provider.admissionToken())
                },
                persist: { _ in throw DurableTalkTestError.rejected })
            manager.updateGatewayConnected(true)
            let begin = Task { @MainActor in try await manager.beginPushToTalk() }
            try await waitForDurableTalk("PTT begin waits before \(action)") {
                await admissionGate.waiterCount() == 1
            }
            let terminal: OpenClawTalkPTTStopPayload
            if action == "stop" {
                terminal = await manager.endPushToTalk()
            } else {
                terminal = await manager.cancelPushToTalk()
            }
            #expect(terminal.status == "idle")
            await admissionGate.open()
            await #expect(throws: Error.self) {
                _ = try await begin.value
            }
            #expect(!manager.isPushToTalkActive)
            #expect(!manager.isListening)
            #expect(manager._test_durableCaptureIdentity() == nil)
            #expect(manager._test_pendingDurableRequest() == nil)
        }
    }

    @Test func PTTReservationCancelsInFlightContinuousStartWithoutBeingOverwritten() async throws {
        let continuousGate = DurableTalkGate()
        let provider = DurableTalkAdmissionProvider(gate: continuousGate, gatedCall: 1)
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager._test_setPTTPermissionHooks(microphone: { true }, speech: { true })
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(token: await provider.admissionToken())
            },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager.updateGatewayConnected(true)
        manager.isEnabled = true
        let continuous = Task { @MainActor in await manager.start() }
        try await waitForDurableTalk("continuous start waits for route admission") {
            await continuousGate.waiterCount() == 1
        }

        let ptt = try await manager.beginPushToTalk()
        #expect(manager.isPushToTalkActive)
        #expect(ptt.captureId == manager._test_activePTTCaptureID())
        #expect(await provider.callCount() == 2)
        let pttRawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        await continuousGate.open()
        await continuous.value
        #expect(manager.isPushToTalkActive)
        #expect(manager._test_durableCaptureIdentity()?.rawCommandID == pttRawID)
        _ = await manager.cancelPushToTalk()
        manager.isEnabled = false
    }

    @Test func explicitPTTRetiresRealtimeMicCallbacksBeforeNativeCaptureStarts() async throws {
        let admissionToken = UUID()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager.updateGatewayConnected(true)
        manager.isEnabled = true
        let retiredRelayGeneration = manager._test_seedActiveRealtimeRelayCallbacks()

        _ = try await manager.beginPushToTalk()
        let pttRawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        manager._test_seedTranscript("native PTT transcript")
        #expect(!manager._test_hasActiveRealtimeRelayCallbacks())

        manager._test_applyRealtimeRelayStatus("Thinking", generation: retiredRelayGeneration)
        manager._test_applyRealtimeRelaySpeaking(true, generation: retiredRelayGeneration)
        #expect(manager.isPushToTalkActive)
        #expect(manager.isListening)
        #expect(!manager.isSpeaking)
        #expect(manager._test_lastTranscript() == "native PTT transcript")
        #expect(manager._test_durableCaptureIdentity()?.rawCommandID == pttRawID)

        manager.isEnabled = false
        _ = await manager.cancelPushToTalk()
    }

    @Test func continuousStartCannotOvertakeReservedPTTAdmission() async throws {
        let admissionGate = DurableTalkGate()
        let provider = DurableTalkAdmissionProvider(gate: admissionGate, gatedCall: 1)
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager._test_setPTTPermissionHooks(microphone: { true }, speech: { true })
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(token: await provider.admissionToken())
            },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager.updateGatewayConnected(true)
        manager.isEnabled = true

        let ptt = Task { @MainActor in try await manager.beginPushToTalk() }
        try await waitForDurableTalk("PTT reserves capture before route admission") {
            await admissionGate.waiterCount() == 1
        }
        await manager.start()
        #expect(await provider.callCount() == 1)
        #expect(!manager.isListening)
        #expect(!manager.isPushToTalkActive)

        await admissionGate.open()
        let payload = try await ptt.value
        #expect(manager.isPushToTalkActive)
        #expect(payload.captureId == manager._test_activePTTCaptureID())
        #expect(await provider.callCount() == 1)
        _ = await manager.cancelPushToTalk()
        manager.isEnabled = false
    }

    @Test func backgroundTalkOptInCannotAuthorizeInFlightPTTAdmission() async throws {
        try await withBackgroundTalkOptIn {
            try await withDurableTalkNodeModel { appModel in
                let admissionGate = DurableTalkGate()
                let provider = DurableTalkAdmissionProvider(gate: admissionGate, gatedCall: 1)
                appModel.talkMode.attachDurableChatOutbox(
                    gatewayOwnerID: { "gateway-talk" },
                    captureAdmission: {
                        durableTalkCaptureAdmission(token: await provider.admissionToken())
                    },
                    persist: { _ in throw DurableTalkTestError.rejected })
                appModel.talkMode.updateGatewayConnected(true)
                appModel.talkMode.isEnabled = true
                let begin = Task { @MainActor in try await appModel.talkMode.beginPushToTalk() }
                try await waitForDurableTalk("PTT admission waits before background") {
                    await admissionGate.waiterCount() == 1
                }
                #expect(!appModel.talkMode.canUseBackgroundTalkOptIn)
                appModel.setScenePhase(.background)
                await admissionGate.open()
                await #expect(throws: Error.self) {
                    _ = try await begin.value
                }
                #expect(!appModel.talkMode.isPushToTalkActive)
                #expect(!appModel.talkMode.isListening)
                #expect(appModel.talkMode._test_durableCaptureIdentity() == nil)
                appModel.talkMode.isEnabled = false
                appModel.setScenePhase(.active)
            }
        }
    }

    @Test func backgroundTalkOptInCannotAuthorizeInFlightContinuousAdmission() async throws {
        try await withBackgroundTalkOptIn {
            try await withDurableTalkNodeModel { appModel in
                let admissionGate = DurableTalkGate()
                let provider = DurableTalkAdmissionProvider(gate: admissionGate, gatedCall: 1)
                appModel.talkMode._test_setPTTPermissionHooks(microphone: { true }, speech: { true })
                appModel.talkMode.attachDurableChatOutbox(
                    gatewayOwnerID: { "gateway-talk" },
                    captureAdmission: {
                        durableTalkCaptureAdmission(token: await provider.admissionToken())
                    },
                    persist: { _ in throw DurableTalkTestError.rejected })
                appModel.talkMode.updateGatewayConnected(true)
                appModel.talkMode.isEnabled = true
                let start = Task { @MainActor in await appModel.talkMode.start() }
                try await waitForDurableTalk("continuous admission waits before background") {
                    await admissionGate.waiterCount() == 1
                }
                #expect(!appModel.talkMode.canUseBackgroundTalkOptIn)
                appModel.setScenePhase(.background)
                await admissionGate.open()
                await start.value
                #expect(!appModel.talkMode.isListening)
                #expect(!appModel.talkMode.isPushToTalkActive)
                #expect(appModel.talkMode._test_durableCaptureIdentity() == nil)
                appModel.talkMode.isEnabled = false
                appModel.setScenePhase(.active)
            }
        }
    }

    @Test func connectedCapturePersistsWithOriginalIdentityAfterDisconnect() async throws {
        let transport = DurableTalkSwitchableTransport(stableGatewayID: "gateway-talk")
        let fixture = try await DurableTalkOutboxFixture.make(
            transport: transport,
            seedVerifiedRouteSnapshot: false)
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { try await fixture.owner.admitCapture() },
            persist: { request in
                try await persistDurableTalk(request, owner: fixture.owner)
            })
        manager.updateMainSessionKey("agent:main:main")
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "What is next?")
        let identity = try #require(manager._test_durableCaptureIdentity())
        let captureRoute = try #require(manager._test_durableCaptureRouteSnapshot())
        let verifiedRoute = try await fixture.store.loadVerifiedRouteSnapshot()
        #expect(verifiedRoute != nil)

        await transport.connection.setConnected(false)
        manager.updateGatewayConnected(false)
        let result = await manager.endPushToTalk()

        #expect(result.status == "queued")
        #expect(result.transcript == "What is next?")
        #expect(manager._test_lastTranscript().isEmpty)
        #expect(manager._test_pendingDurableRequest() == nil)
        let commands = try await fixture.store.loadUnresolved()
        #expect(commands.count == 1)
        #expect(commands.first?.rawCommandID == identity.rawCommandID)
        #expect(commands.first?.sessionKey == "agent:main:main")
        #expect(commands.first?.stableGatewayID == "gateway-talk")
        #expect(commands.first?.route.routingContract == captureRoute.routingContract)
        #expect(commands.first?.route.capabilities == captureRoute.capabilities)
        #expect(commands.first?.route.operatorScopes == captureRoute.operatorScopes)
        #expect((commands.first?.route.verifiedAt ?? .distantPast) >= captureRoute.verifiedAt)
        manager.invalidateDurableChatDeliveryOwner()
        try await fixture.close()
    }

    @Test func routingContractChangeDuringCaptureFailsBeforePersistenceAndKeepsSameIdentity() async throws {
        let transport = DurableTalkSwitchableTransport(stableGatewayID: "gateway-talk")
        let fixture = try await DurableTalkOutboxFixture.make(
            transport: transport,
            seedVerifiedRouteSnapshot: false)
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { try await fixture.owner.admitCapture() },
            persist: { request in try await persistDurableTalk(request, owner: fixture.owner) })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "route-bound text")
        let captured = try #require(manager._test_durableCaptureIdentity())

        await transport.connection.setRoutingContract("per-sender|main|changed")
        let result = await manager.endPushToTalk()

        #expect(result.status == "not_queued")
        #expect(manager._test_lastTranscript() == "route-bound text")
        #expect(manager._test_pendingDurableRequest()?.rawCommandID == captured.rawCommandID)
        let unresolvedAfterDrift = try await fixture.store.loadUnresolved()
        #expect(unresolvedAfterDrift.isEmpty)
        try await fixture.close()
    }

    @Test func capabilityOrScopeSetChangeDuringCaptureFailsBeforePersistence() async throws {
        enum DriftCase: CaseIterable { case capability, scope }

        for drift in DriftCase.allCases {
            let transport = DurableTalkSwitchableTransport(stableGatewayID: "gateway-talk")
            let fixture = try await DurableTalkOutboxFixture.make(
                transport: transport,
                seedVerifiedRouteSnapshot: false)
            let manager = TalkModeManager(allowSimulatorCapture: true)
            manager.attachDurableChatOutbox(
                gatewayOwnerID: { "gateway-talk" },
                captureAdmission: { try await fixture.owner.admitCapture() },
                persist: { request in try await persistDurableTalk(request, owner: fixture.owner) })
            manager.updateGatewayConnected(true)
            _ = try await manager._test_prepareActivePTT(
                transcript: "authority set stays capture-bound")
            let captured = try #require(manager._test_durableCaptureIdentity())

            switch drift {
            case .capability:
                await transport.connection.setCapabilities([
                    OpenClawChatOutboxDatabase.routingCapability,
                    "future-optional-capability",
                ])
            case .scope:
                await transport.connection.setOperatorScopes(
                    OpenClawChatOutboxDatabase.requiredOperatorScopes + ["operator.talk.secrets"])
            }
            let result = await manager.endPushToTalk()

            #expect(result.status == "not_queued")
            #expect(manager._test_lastTranscript() == "authority set stays capture-bound")
            #expect(manager._test_pendingDurableRequest()?.rawCommandID == captured.rawCommandID)
            let unresolvedAfterDrift = try await fixture.store.loadUnresolved()
            #expect(unresolvedAfterDrift.isEmpty)
            try await fixture.close()
        }
    }

    @Test func failedPersistenceRetainsTranscriptAndSameIdentityAcrossRetryAndGatewaySwitch() async throws {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let recorder = DurableTalkRequestRecorder()
        var activeGatewayID = "gateway-a"
        var newGatewayEffects = 0
        let admissionToken = UUID()
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { activeGatewayID },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { request in
                await recorder.append(request)
                guard request.stableGatewayID == activeGatewayID else {
                    throw OpenClawChatOutboxError.routeSnapshotChanged
                }
                if activeGatewayID == "gateway-b" {
                    newGatewayEffects += 1
                }
                throw DurableTalkTestError.rejected
            })
        manager.updateMainSessionKey("session-a")
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "keep this exact request")

        let first = await manager.endPushToTalk()
        let pending = try #require(manager._test_pendingDurableRequest())
        #expect(first.status == "not_queued")
        #expect(manager._test_lastTranscript() == "keep this exact request")

        await #expect(throws: Error.self) {
            try await manager.beginPushToTalk()
        }
        #expect(manager._test_lastTranscript() == "keep this exact request")
        #expect(manager.pendingDurableCommandID == pending.rawCommandID)

        activeGatewayID = "gateway-b"
        manager.updateMainSessionKey("session-b")
        manager.invalidateDurableChatDeliveryOwner()
        #expect(!(await manager.retryPendingDurableMessage()))
        let attempts = await recorder.snapshot()
        #expect(attempts.count == 1)
        #expect(attempts.allSatisfy { $0.rawCommandID == pending.rawCommandID })
        #expect(attempts.allSatisfy { $0.stableGatewayID == "gateway-a" })
        #expect(attempts.allSatisfy { $0.sessionKey == "session-a" })
        #expect(newGatewayEffects == 0)
        #expect(manager._test_lastTranscript() == "keep this exact request")
    }

    @Test func reconnectCannotStartContinuousCaptureOverPendingDurableMessage() async throws {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let admissionProvider = DurableTalkAdmissionProvider()
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-a" },
            captureAdmission: {
                durableTalkCaptureAdmission(token: await admissionProvider.admissionToken())
            },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "keep pending across reconnect")
        let originalRawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect((await manager.endPushToTalk()).status == "not_queued")
        #expect(await admissionProvider.callCount() == 1)

        manager.isEnabled = true
        manager.updateGatewayConnected(false)
        manager.updateGatewayConnected(true) // schedules the product reconnect start
        await manager.start() // deterministic convergence with that same guard
        await Task.yield()

        #expect(await admissionProvider.callCount() == 1)
        #expect(manager._test_pendingDurableRequest()?.rawCommandID == originalRawID)
        #expect(manager._test_lastTranscript() == "keep pending across reconnect")
        #expect(manager.statusText == "Retry the previous Talk message")
        #expect(!manager.isListening)
        manager.isEnabled = false
    }

    @Test func concurrentStopLifecycleAndPersistenceShareOneTruthfulResult() async throws {
        let fixture = try await DurableTalkOutboxFixture.make()
        let gate = DurableTalkGate()
        let recorder = DurableTalkRequestRecorder()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(
                    token: try await fixture.owner.destructiveSessionAdmissionToken())
            },
            persist: { request in
                await recorder.append(request)
                await gate.wait()
                return try await persistDurableTalk(request, owner: fixture.owner)
            })
        manager.updateGatewayConnected(true)
        let captureID = try await manager._test_prepareActivePTT(transcript: "persist once")

        let first = Task { @MainActor in await manager.endPushToTalk() }
        try await waitForDurableTalk("first stop reaches persistence") {
            await gate.waiterCount() == 1
        }
        #expect(manager._test_lastTranscript() == "persist once")
        #expect(manager.statusText == "Queueing…")
        let second = Task { @MainActor in await manager.endPushToTalk() }
        manager.setForegroundAudioCaptureAllowed(false)
        _ = manager.suspendForBackground()
        manager.stop()
        await gate.open()

        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult.status == "queued")
        #expect(secondResult.status == "queued")
        #expect(firstResult.captureId == captureID)
        #expect(secondResult.captureId == captureID)
        #expect(await recorder.snapshot().count == 1)
        let lifecycleRows = try await fixture.store.loadUnresolved()
        #expect(lifecycleRows.count == 1)
        #expect(!manager._test_hasDurableResponseTask())
        try await fixture.close()
    }

    @Test func credentialResetFencesLatePersistenceSuccessWithoutQueuedResurrection() async throws {
        let fixture = try await DurableTalkOutboxFixture.make()
        let gate = DurableTalkGate()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(
                    token: try await fixture.owner.destructiveSessionAdmissionToken())
            },
            persist: { request in
                await gate.wait()
                return try await persistDurableTalk(request, owner: fixture.owner)
            })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "purge me")
        let stop = Task { @MainActor in await manager.endPushToTalk() }
        try await waitForDurableTalk("reset waits behind admitted persistence") {
            await gate.waiterCount() == 1
        }

        manager.beginCredentialReset()
        await gate.open()
        let result = await stop.value
        #expect(result.status == "cancelled")
        #expect(manager._test_pendingDurableRequest() == nil)
        #expect(manager._test_lastTranscript().isEmpty)
        #expect(!manager.statusText.hasPrefix("Queued"))
        #expect(!manager._test_hasDurableResponseTask())
        try await fixture.close()
    }

    @Test func credentialResetFencesLatePersistenceFailureWithoutRetryResurrection() async throws {
        let gate = DurableTalkGate()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let admissionToken = UUID()
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { _ in
                await gate.wait()
                throw DurableTalkTestError.rejected
            })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "do not resurrect")
        let stop = Task { @MainActor in await manager.endPushToTalk() }
        try await waitForDurableTalk("reset waits behind failing persistence") {
            await gate.waiterCount() == 1
        }

        manager.beginCredentialReset()
        await gate.open()
        let result = await stop.value
        #expect(result.status == "cancelled")
        #expect(manager._test_pendingDurableRequest() == nil)
        #expect(manager._test_lastTranscript().isEmpty)
        #expect(!manager.statusText.contains("retry"))
        #expect(!manager._test_hasDurableResponseTask())
    }

    @Test func resetDuringPermissionAwaitCannotResurrectPTTCapture() async throws {
        let permissionGate = DurableTalkGate()
        let manager = TalkModeManager(allowSimulatorCapture: false)
        let admissionToken = UUID()
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager._test_setPTTPermissionHooks(
            microphone: {
                await permissionGate.wait()
                return true
            },
            speech: { true })
        manager.updateGatewayConnected(true)

        let start = Task { @MainActor in
            try await manager.beginPushToTalk()
        }
        try await waitForDurableTalk("PTT waits for permission") {
            await permissionGate.waiterCount() == 1
        }
        manager.beginCredentialReset()
        await permissionGate.open()
        await #expect(throws: Error.self) {
            _ = try await start.value
        }
        #expect(!manager.isPushToTalkActive)
        #expect(!manager.isListening)
        #expect(manager._test_durableCaptureIdentity() == nil)
        #expect(manager._test_lastTranscript().isEmpty)
    }

    @Test func successfulSessionResetDuringPTTPermissionAwaitInvalidatesCaptureToken() async throws {
        let permissionGate = DurableTalkGate()
        let fixture = try await DurableTalkOutboxFixture.make(
            transport: DurableTalkAcceptedTransport(stableGatewayID: "gateway-talk"),
            seedVerifiedRouteSnapshot: false)
        let manager = TalkModeManager(allowSimulatorCapture: false)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { try await fixture.owner.admitCapture() },
            captureAdmissionToken: {
                try await fixture.owner.destructiveSessionAdmissionToken()
            },
            captureAdmissionIsCurrent: { _, token in
                (try? await fixture.owner.destructiveSessionAdmissionToken()) == token
            },
            persist: { request in
                try await persistDurableTalk(request, owner: fixture.owner)
            })
        manager._test_setPTTPermissionHooks(
            microphone: {
                await permissionGate.wait()
                return true
            },
            speech: { true })
        manager.updateGatewayConnected(true)

        let begin = Task { @MainActor in try await manager.beginPushToTalk() }
        try await waitForDurableTalk("PTT waits after capture admission for permission") {
            await permissionGate.waiterCount() == 1
        }
        let capturedToken = try await fixture.owner.destructiveSessionAdmissionToken()
        try await fixture.owner.performDestructiveSessionAction {}
        let resetToken = try await fixture.owner.destructiveSessionAdmissionToken()
        #expect(resetToken != capturedToken)
        await permissionGate.open()
        await #expect(throws: Error.self) {
            _ = try await begin.value
        }
        #expect(!manager.isPushToTalkActive)
        #expect(!manager.isListening)
        #expect(manager._test_durableCaptureIdentity() == nil)
        #expect(manager._test_lastTranscript().isEmpty)
        try await fixture.close()
    }

    @Test func successfulSessionResetDuringContinuousPermissionAwaitInvalidatesStartToken() async throws {
        let permissionGate = DurableTalkGate()
        let fixture = try await DurableTalkOutboxFixture.make(
            transport: DurableTalkAcceptedTransport(stableGatewayID: "gateway-talk"),
            seedVerifiedRouteSnapshot: false)
        let admissionCalls = DurableTalkAdmissionProvider()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                _ = await admissionCalls.admissionToken()
                return try await fixture.owner.admitCapture()
            },
            captureAdmissionToken: {
                try await fixture.owner.destructiveSessionAdmissionToken()
            },
            captureAdmissionIsCurrent: { _, token in
                (try? await fixture.owner.destructiveSessionAdmissionToken()) == token
            },
            persist: { request in
                try await persistDurableTalk(request, owner: fixture.owner)
            })
        manager._test_setPTTPermissionHooks(
            microphone: {
                await permissionGate.wait()
                return true
            },
            speech: { true })
        manager.updateGatewayConnected(true)
        manager.isEnabled = true

        let start = Task { @MainActor in await manager.start() }
        try await waitForDurableTalk("continuous start waits for permission") {
            await permissionGate.waiterCount() == 1
        }
        let capturedToken = try await fixture.owner.destructiveSessionAdmissionToken()
        try await fixture.owner.performDestructiveSessionAction {}
        let resetToken = try await fixture.owner.destructiveSessionAdmissionToken()
        #expect(resetToken != capturedToken)
        await permissionGate.open()
        await start.value
        #expect(await admissionCalls.callCount() == 0)
        #expect(!manager.isListening)
        #expect(!manager.isPushToTalkActive)
        #expect(manager._test_durableCaptureIdentity() == nil)
        manager.isEnabled = false
        try await fixture.close()
    }

    @Test func credentialResetDuringAdmissionLookupCannotResurrectCapture() async throws {
        let admissionGate = DurableTalkGate()
        let provider = DurableTalkAdmissionProvider(gate: admissionGate, gatedCall: 1)
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(token: await provider.admissionToken())
            },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager.updateGatewayConnected(true)

        let start = Task { @MainActor in try await manager.beginPushToTalk() }
        try await waitForDurableTalk("capture waits for destructive admission") {
            await admissionGate.waiterCount() == 1
        }
        manager.beginCredentialReset()
        await admissionGate.open()
        await #expect(throws: Error.self) {
            _ = try await start.value
        }
        #expect(!manager.isPushToTalkActive)
        #expect(manager._test_durableCaptureIdentity() == nil)
        #expect(manager._test_pendingDurableRequest() == nil)
        #expect(manager._test_lastTranscript().isEmpty)
    }

    @Test func credentialResetDuringContinuousAdmissionLookupCannotResurrectCapture() async throws {
        let admissionGate = DurableTalkGate()
        let provider = DurableTalkAdmissionProvider(gate: admissionGate, gatedCall: 1)
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(token: await provider.admissionToken())
            },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager._test_setPTTPermissionHooks(microphone: { true }, speech: { true })
        manager.updateGatewayConnected(true)
        manager.isEnabled = true

        let start = Task { @MainActor in await manager.start() }
        try await waitForDurableTalk(
            "continuous capture waits for destructive admission",
            iterations: 3_000
        ) {
            await admissionGate.waiterCount() == 1
        }
        manager.beginCredentialReset()
        await admissionGate.open()
        await start.value
        #expect(!manager.isListening)
        #expect(!manager.isPushToTalkActive)
        #expect(manager._test_durableCaptureIdentity() == nil)
        #expect(manager._test_pendingDurableRequest() == nil)
        #expect(manager._test_lastTranscript().isEmpty)
        manager.isEnabled = false
    }

    @Test func credentialResetDuringRetryAdmissionLookupCannotRecreatePendingWork() async throws {
        let admissionGate = DurableTalkGate()
        let provider = DurableTalkAdmissionProvider(gate: admissionGate, gatedCall: 2)
        let recorder = DurableTalkRequestRecorder()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(token: await provider.admissionToken())
            },
            persist: { request in
                await recorder.append(request)
                throw DurableTalkTestError.rejected
            })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "retry must be fenced")
        #expect((await manager.endPushToTalk()).status == "not_queued")

        let retry = Task { @MainActor in await manager.retryPendingDurableMessage() }
        try await waitForDurableTalk("retry waits for fresh destructive admission") {
            await admissionGate.waiterCount() == 1
        }
        manager.beginCredentialReset()
        await admissionGate.open()
        #expect(!(await retry.value))
        #expect(await recorder.snapshot().count == 1)
        #expect(manager._test_pendingDurableRequest() == nil)
        #expect(manager._test_lastTranscript().isEmpty)
    }

    @Test func backgroundDuringExplicitRetryAllowsDeliveryButSuppressesResponsePresentation() async throws {
        try await withBackgroundTalkOptIn {
            let fixture = try await DurableTalkOutboxFixture.make()
            let admissionGate = DurableTalkGate()
            let ownerToken = try await fixture.owner.destructiveSessionAdmissionToken()
            let provider = DurableTalkAdmissionProvider(
                token: ownerToken,
                gate: admissionGate,
                gatedCall: 2)
            try await withDurableTalkNodeModel { appModel in
                var persistAttempts = 0
                appModel.talkMode.attachDurableChatOutbox(
                    gatewayOwnerID: { "gateway-talk" },
                    captureAdmission: {
                        durableTalkCaptureAdmission(token: await provider.admissionToken())
                    },
                    persist: { request in
                        persistAttempts += 1
                        if persistAttempts == 1 { throw DurableTalkTestError.rejected }
                        return try await persistDurableTalk(request, owner: fixture.owner)
                    })
                appModel.talkMode.updateGatewayConnected(true)
                appModel.talkMode.isEnabled = true
                _ = try await appModel.talkMode._test_prepareActivePTT(
                    transcript: "retry remains authoritative")
                #expect((await appModel.talkMode.endPushToTalk()).status == "not_queued")
                let retry = Task { @MainActor in
                    await appModel.talkMode.retryPendingDurableMessage()
                }
                try await waitForDurableTalk("explicit retry waits for admission") {
                    await admissionGate.waiterCount() == 1
                }
                #expect(!appModel.talkMode.canUseBackgroundTalkOptIn)
                appModel.setScenePhase(.background)
                await admissionGate.open()
                #expect(await retry.value)
                #expect(persistAttempts == 2)
                #expect(!appModel.talkMode._test_hasDurableResponseTask())
                #expect(appModel.talkMode.statusText == "Queued — reply will remain in Chat")
                appModel.talkMode.isEnabled = false
                appModel.setScenePhase(.active)
            }
            try await fixture.close()
        }
    }

    @Test func explicitRetryRefreshesAdmissionButPreservesRawIdentityAndClearsOnlyAfterCommit() async throws {
        let fixture = try await DurableTalkOutboxFixture.make()
        let recorder = DurableTalkRequestRecorder()
        var shouldReject = true
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(
                    token: try await fixture.owner.destructiveSessionAdmissionToken())
            },
            persist: { request in
                await recorder.append(request)
                if shouldReject { throw DurableTalkTestError.rejected }
                return try await persistDurableTalk(request, owner: fixture.owner)
            })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "same identity")
        #expect((await manager.endPushToTalk()).status == "not_queued")
        let pending = try #require(manager._test_pendingDurableRequest())
        let firstToken = pending.destructiveSessionAdmissionToken
        #expect(manager._test_lastTranscript() == "same identity")

        try await fixture.owner.performDestructiveSessionAction {}
        shouldReject = false
        #expect(await manager.retryPendingDurableMessage())
        let attempts = await recorder.snapshot()
        #expect(attempts.count == 2)
        #expect(attempts.allSatisfy { $0.rawCommandID == pending.rawCommandID })
        #expect(attempts.last?.destructiveSessionAdmissionToken != firstToken)
        #expect(manager._test_pendingDurableRequest() == nil)
        #expect(manager._test_lastTranscript().isEmpty)
        let retriedRows = try await fixture.store.loadUnresolved()
        #expect(retriedRows.map(\.rawCommandID) == [pending.rawCommandID])
        manager.invalidateDurableChatDeliveryOwner()
        try await fixture.close()
    }

    @Test func discardClearsOnlyUnpersistedPendingTalkAndAllowsNewIdentity() async throws {
        let admissionToken = UUID()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { _ in throw DurableTalkTestError.rejected })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "discard this")
        #expect((await manager.endPushToTalk()).status == "not_queued")
        let discardedID = try #require(manager._test_pendingDurableRequest()?.rawCommandID)

        #expect(manager.discardPendingDurableMessage())
        #expect(manager._test_pendingDurableRequest() == nil)
        #expect(manager._test_lastTranscript().isEmpty)
        _ = try await manager._test_prepareActivePTT(transcript: "new message")
        #expect(manager._test_durableCaptureIdentity()?.rawCommandID != discardedID)
    }

    @Test func backgroundBeforePTTEndBodyCannotEraseThePersistingTranscript() async throws {
        let fixture = try await DurableTalkOutboxFixture.make()
        let endGate = DurableTalkGate()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(
                    token: try await fixture.owner.destructiveSessionAdmissionToken())
            },
            persist: { request in try await persistDurableTalk(request, owner: fixture.owner) })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "preserve before body")
        manager._test_setPTTEndBeforeBodyHook { await endGate.wait() }

        let ending = Task { @MainActor in await manager.endPushToTalk() }
        try await waitForDurableTalk("PTT end is reserved before its body") {
            await endGate.waiterCount() == 1
        }
        manager.setForegroundAudioCaptureAllowed(false)
        _ = manager.suspendForBackground()
        manager.stop()
        #expect(manager._test_lastTranscript() == "preserve before body")
        await endGate.open()
        let result = await ending.value
        #expect(result.status == "queued")
        #expect(result.transcript == "preserve before body")
        let preBodyRows = try await fixture.store.loadUnresolved()
        #expect(preBodyRows.count == 1)
        try await fixture.close()
    }

    @Test func credentialResetCannotLetRetiredEndTaskConsumeReplacementCapture() async throws {
        let recorder = DurableTalkRequestRecorder()
        let endGate = DurableTalkGate()
        let admissionToken = UUID()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { request in
                await recorder.append(request)
                throw DurableTalkTestError.rejected
            })
        manager.updateGatewayConnected(true)
        _ = try await manager.beginPushToTalk()
        manager._test_seedTranscript("retired A")
        let retiredCaptureID = try #require(manager._test_activePTTCaptureID())
        manager._test_setPTTEndBeforeBodyHook { await endGate.wait() }

        let retiredEnd = Task { @MainActor in await manager.endPushToTalk() }
        try await waitForDurableTalk("retired end task waits before body") {
            await endGate.waiterCount() == 1
        }
        manager.beginCredentialReset()
        _ = try await manager.beginPushToTalk()
        manager._test_seedTranscript("replacement B")
        let replacementCaptureID = try #require(manager._test_activePTTCaptureID())
        let replacementRawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect(replacementCaptureID != retiredCaptureID)

        await endGate.open()
        let retiredResult = await retiredEnd.value
        #expect(retiredResult.captureId == retiredCaptureID)
        #expect(retiredResult.status == "cancelled")
        #expect(manager.isPushToTalkActive)
        #expect(manager._test_activePTTCaptureID() == replacementCaptureID)
        #expect(manager._test_lastTranscript() == "replacement B")
        #expect(manager._test_durableCaptureIdentity()?.rawCommandID == replacementRawID)
        #expect(await recorder.snapshot().isEmpty)

        manager._test_setPTTEndBeforeBodyHook {}
        _ = await manager.cancelPushToTalk()
    }

    @Test func exactRawRunSpeaksAndForeignFinalIsIgnored() async throws {
        let transport = DurableTalkAcceptedTransport(stableGatewayID: "gateway-talk")
        let fixture = try await DurableTalkOutboxFixture.make(transport: transport)
        let gatewayEvents = DurableTalkEventSource()
        let observations = DurableTalkEventObservation()
        let speech = DurableTalkSystemSpeechSpy()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.systemSpeech = speech
        manager._test_setTTSAudioHooks(
            prepare: { durableTalkSpeakerRoute },
            restore: {})
        manager._test_setDurableEventObservedHook { runID, matched in
            observations.record(runID: runID, matched: matched)
        }
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(
                    token: try await fixture.owner.destructiveSessionAdmissionToken())
            },
            persist: { request in
                try await persistDurableTalk(
                    request,
                    owner: fixture.owner,
                    gatewayEvents: gatewayEvents.stream)
            })
        manager.updateMainSessionKey("main")
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "tell me exactly")
        let rawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect((await manager.endPushToTalk()).status == "queued")
        try await waitForDurableTalk("Talk response observer starts") {
            await MainActor.run { manager._test_hasDurableResponseTask() }
        }

        gatewayEvents.sendChatFinal(runID: "parallel-foreign-run", text: "wrong reply")
        try await waitForDurableTalk("foreign event is consumed and rejected") {
            observations.contains(runID: "parallel-foreign-run", matched: false)
        }
        #expect(speech.spokenTexts.isEmpty)
        #expect(manager._test_hasDurableResponseTask())

        gatewayEvents.sendChatFinal(runID: rawID, text: "the exact reply")
        try await waitForDurableTalk("exact run is spoken") {
            await MainActor.run { speech.spokenTexts == ["the exact reply"] }
        }
        #expect(!speech.spokenTexts.contains("wrong reply"))
        gatewayEvents.finish()
        manager.invalidateDurableChatDeliveryOwner()
        try await fixture.close()
    }

    @Test func backgroundDuringAdmissionRecheckCannotResurrectExactRunSpeech() async throws {
        let transport = DurableTalkAcceptedTransport(stableGatewayID: "gateway-talk")
        let fixture = try await DurableTalkOutboxFixture.make(transport: transport)
        let gatewayEvents = DurableTalkEventSource()
        let authorizationGate = DurableTalkGate()
        let speech = DurableTalkSystemSpeechSpy()
        let responseExits = DurableTalkResponseExitObservation()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.systemSpeech = speech
        manager._test_setTTSAudioHooks(
            prepare: { durableTalkSpeakerRoute },
            restore: {})
        manager._test_setDurableResponseExitedHook { responseExits.record($0) }
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(
                    token: try await fixture.owner.destructiveSessionAdmissionToken())
            },
            captureAdmissionIsCurrent: { _, _ in
                await authorizationGate.wait()
                return true
            },
            persist: { request in
                try await persistDurableTalk(
                    request,
                    owner: fixture.owner,
                    gatewayEvents: gatewayEvents.stream)
            })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "authorize before speech")
        let rawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect((await manager.endPushToTalk()).status == "queued")
        try await waitForDurableTalk("response observer starts before admission recheck") {
            await MainActor.run { manager._test_hasDurableResponseTask() }
        }

        gatewayEvents.sendChatFinal(runID: rawID, text: "must stay silent")
        try await waitForDurableTalk("presentation admission recheck suspends") {
            await authorizationGate.waiterCount() == 1
        }
        manager.setForegroundAudioCaptureAllowed(false)
        await authorizationGate.open()
        try await waitForDurableTalk("cancelled admission response exits") {
            responseExits.count() == 1
        }

        #expect(speech.spokenTexts.isEmpty)
        #expect(!manager._test_hasDurableResponseTask())
        let incrementalState = manager._test_incrementalSpeechState()
        #expect(!incrementalState.active)
        #expect(incrementalState.queued == 0)
        #expect(!incrementalState.workerActive)
        #expect(!incrementalState.ownsPlayback)
        gatewayEvents.finish()
        try await fixture.close()
    }

    @Test func backgroundDuringFinalPreparationCannotStartExactRunSpeech() async throws {
        let transport = DurableTalkAcceptedTransport(stableGatewayID: "gateway-talk")
        let fixture = try await DurableTalkOutboxFixture.make(transport: transport)
        let gatewayEvents = DurableTalkEventSource()
        let playbackGate = DurableTalkGate()
        let speech = DurableTalkSystemSpeechSpy()
        let responseExits = DurableTalkResponseExitObservation()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.systemSpeech = speech
        manager._test_setTTSAudioHooks(
            prepare: { durableTalkSpeakerRoute },
            restore: {})
        manager._test_setDurableResponseExitedHook { responseExits.record($0) }
        manager._test_setDurablePresentationBeforePlaybackHook {
            await playbackGate.wait()
        }
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(
                    token: try await fixture.owner.destructiveSessionAdmissionToken())
            },
            persist: { request in
                try await persistDurableTalk(
                    request,
                    owner: fixture.owner,
                    gatewayEvents: gatewayEvents.stream)
            })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "prepare exact speech")
        let rawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect((await manager.endPushToTalk()).status == "queued")
        try await waitForDurableTalk("response observer starts before final preparation") {
            await MainActor.run { manager._test_hasDurableResponseTask() }
        }

        gatewayEvents.sendChatFinal(runID: rawID, text: "must not start")
        try await waitForDurableTalk("final presentation preparation suspends") {
            await playbackGate.waiterCount() == 1
        }
        manager.setForegroundAudioCaptureAllowed(false)
        await playbackGate.open()
        try await waitForDurableTalk("cancelled prepared response exits") {
            responseExits.count() == 1
        }

        #expect(speech.spokenTexts.isEmpty)
        #expect(!manager._test_hasDurableResponseTask())
        let incrementalState = manager._test_incrementalSpeechState()
        #expect(!incrementalState.active)
        #expect(incrementalState.queued == 0)
        #expect(!incrementalState.workerActive)
        #expect(!incrementalState.ownsPlayback)
        gatewayEvents.finish()
        try await fixture.close()
    }

    @Test func sessionSwitchAfterPersistenceFencesExactOldRunSpeech() async throws {
        let transport = DurableTalkAcceptedTransport(stableGatewayID: "gateway-talk")
        let fixture = try await DurableTalkOutboxFixture.make(transport: transport)
        let gatewayEvents = DurableTalkEventSource()
        let speech = DurableTalkSystemSpeechSpy()
        let responseExits = DurableTalkResponseExitObservation()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.systemSpeech = speech
        manager._test_setTTSAudioHooks(
            prepare: { durableTalkSpeakerRoute },
            restore: {})
        manager._test_setDurableResponseExitedHook { responseExits.record($0) }
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(
                    token: try await fixture.owner.destructiveSessionAdmissionToken())
            },
            persist: { request in
                try await persistDurableTalk(
                    request,
                    owner: fixture.owner,
                    gatewayEvents: gatewayEvents.stream)
            })
        manager.updateMainSessionKey("session-a")
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "stay in A")
        let rawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect((await manager.endPushToTalk()).status == "queued")
        try await waitForDurableTalk("old-session response observer starts") {
            await MainActor.run { manager._test_hasDurableResponseTask() }
        }

        manager.updateMainSessionKey("session-b")
        #expect(!manager._test_hasDurableResponseTask())
        try await waitForDurableTalk("old-session response task exits") {
            responseExits.count() == 1
        }
        gatewayEvents.sendChatFinal(runID: rawID, text: "reply for A")
        gatewayEvents.finish()
        await Task.yield()
        #expect(speech.spokenTexts.isEmpty)
        #expect(!manager._test_hasDurableResponseTask())
        try await fixture.close()
    }

    @Test func backgroundAfterPersistenceFencesExactRunSpeechEvenWithBackgroundTalkOptIn() async throws {
        let transport = DurableTalkAcceptedTransport(stableGatewayID: "gateway-talk")
        let fixture = try await DurableTalkOutboxFixture.make(transport: transport)
        let gatewayEvents = DurableTalkEventSource()
        let speech = DurableTalkSystemSpeechSpy()
        let responseExits = DurableTalkResponseExitObservation()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.systemSpeech = speech
        manager._test_setTTSAudioHooks(
            prepare: { durableTalkSpeakerRoute },
            restore: {})
        manager._test_setDurableResponseExitedHook { responseExits.record($0) }
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: {
                durableTalkCaptureAdmission(
                    token: try await fixture.owner.destructiveSessionAdmissionToken())
            },
            persist: { request in
                try await persistDurableTalk(
                    request,
                    owner: fixture.owner,
                    gatewayEvents: gatewayEvents.stream)
            })
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "do not surprise me")
        let rawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect((await manager.endPushToTalk()).status == "queued")
        try await waitForDurableTalk("foreground response observer starts") {
            await MainActor.run { manager._test_hasDurableResponseTask() }
        }

        manager.setForegroundAudioCaptureAllowed(false)
        #expect(!manager._test_hasDurableResponseTask())
        try await waitForDurableTalk("backgrounded response task exits") {
            responseExits.count() == 1
        }
        _ = manager.suspendForBackground(keepActive: true)
        gatewayEvents.sendChatFinal(runID: rawID, text: "late background reply")
        gatewayEvents.finish()
        await Task.yield()
        #expect(speech.spokenTexts.isEmpty)
        #expect(!manager._test_hasDurableResponseTask())
        try await fixture.close()
    }

    @Test func successfulResetAfterCanonicalConfirmationFencesIncrementalAndFinalOldRunSpeech() async throws {
        let transport = DurableTalkAcceptedTransport(
            stableGatewayID: "gateway-talk",
            autoConfirmHistory: true)
        let fixture = try await DurableTalkOutboxFixture.make(
            transport: transport,
            seedVerifiedRouteSnapshot: false,
            confirmationDelaysNanoseconds: [0, 0])
        let gatewayEvents = DurableTalkEventSource()
        let incrementalEvents = DurableTalkEventSource()
        let responseExits = DurableTalkResponseExitObservation()
        let speech = DurableTalkSystemSpeechSpy()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.systemSpeech = speech
        manager._test_setTTSAudioHooks(
            prepare: { durableTalkSpeakerRoute },
            restore: {})
        manager._test_setDurableResponseExitedHook { responseExits.record($0) }
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { try await fixture.owner.admitCapture() },
            persist: { request in
                try await persistDurableTalk(
                    request,
                    owner: fixture.owner,
                    gatewayEvents: gatewayEvents.stream,
                    incrementalEvents: incrementalEvents.stream)
            })
        manager.updateMainSessionKey("main")
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "finish before reset")
        let rawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect((await manager.endPushToTalk()).status == "queued")
        try await waitForDurableTalk("canonical history confirms and deletes Talk row") {
            (try? await fixture.store.loadUnresolved().isEmpty) == true
        }
        try await waitForDurableTalk("old Talk response remains awaiting exact run") {
            await MainActor.run { manager._test_hasDurableResponseTask() }
        }

        let oldAdmissionToken = try await fixture.owner.destructiveSessionAdmissionToken()
        try await fixture.owner.performDestructiveSessionAction {}
        let newAdmissionToken = try await fixture.owner.destructiveSessionAdmissionToken()
        #expect(newAdmissionToken != oldAdmissionToken)

        incrementalEvents.sendAgentAssistant(runID: rawID, text: "late incremental chunk.")
        gatewayEvents.sendChatFinal(runID: rawID, text: "late final reply")
        try await waitForDurableTalk("reset-fenced response task exits") {
            responseExits.count() == 1
        }
        try await waitForDurableTalk("reset authorization clears incremental speech state") {
            let state = await MainActor.run { manager._test_incrementalSpeechState() }
            return !state.active && state.queued == 0 && !state.workerActive && !state.ownsPlayback
        }
        #expect(speech.spokenTexts.isEmpty)
        #expect(!manager._test_hasDurableResponseTask())
        #expect(speech.spokenTexts.isEmpty)
        let incrementalState = manager._test_incrementalSpeechState()
        #expect(!incrementalState.active)
        #expect(incrementalState.queued == 0)
        #expect(!incrementalState.workerActive)
        #expect(!incrementalState.ownsPlayback)
        gatewayEvents.finish()
        incrementalEvents.finish()
        try await fixture.close()
    }

    @Test func successfulResetStopsAlreadyPlayingExactRunSpeech() async throws {
        let transport = DurableTalkAcceptedTransport(
            stableGatewayID: "gateway-talk",
            autoConfirmHistory: true)
        let fixture = try await DurableTalkOutboxFixture.make(
            transport: transport,
            seedVerifiedRouteSnapshot: false,
            confirmationDelaysNanoseconds: [0, 0])
        let gatewayEvents = DurableTalkEventSource()
        let speech = DurableTalkBlockingSystemSpeech()
        let responseExits = DurableTalkResponseExitObservation()
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager.systemSpeech = speech
        manager._test_setTTSAudioHooks(
            prepare: { durableTalkSpeakerRoute },
            restore: {})
        manager._test_setDurableResponseExitedHook { responseExits.record($0) }
        manager.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { try await fixture.owner.admitCapture() },
            persist: { request in
                try await persistDurableTalk(
                    request,
                    owner: fixture.owner,
                    gatewayEvents: gatewayEvents.stream)
            })
        manager.updateMainSessionKey("main")
        manager.updateGatewayConnected(true)
        _ = try await manager._test_prepareActivePTT(transcript: "speak until reset")
        let rawID = try #require(manager._test_durableCaptureIdentity()?.rawCommandID)
        #expect((await manager.endPushToTalk()).status == "queued")
        try await waitForDurableTalk("canonical history clears row before active speech reset") {
            (try? await fixture.store.loadUnresolved().isEmpty) == true
        }
        try await waitForDurableTalk("response observer awaits active speech final") {
            await MainActor.run { manager._test_hasDurableResponseTask() }
        }

        gatewayEvents.sendChatFinal(runID: rawID, text: "active old reply.")
        try await waitForDurableTalk("exact old response begins system speech") {
            await MainActor.run { speech.spokenTexts == ["active old reply."] }
        }
        let stopsBeforeReset = speech.stopCount

        try await fixture.owner.performDestructiveSessionAction {}
        try await waitForDurableTalk("owner token rotation stops active old response") {
            await MainActor.run { speech.stopCount > stopsBeforeReset }
        }
        try await waitForDurableTalk("token-rotated active response exits") {
            responseExits.count() == 1
        }
        #expect(!manager._test_hasDurableResponseTask())
        #expect(!manager.isSpeaking)
        gatewayEvents.finish()
        try await fixture.close()
    }

    @Test func backgroundTransfersOverlappingPTTVoiceWakeOwnershipWithoutRestartingIt() async throws {
        let backgroundKey = "talk.background.enabled"
        let talkEnabledKey = "talk.enabled"
        let voiceWakeEnabledKey = "voiceWake.enabled"
        let previousBackgroundValue = UserDefaults.standard.object(forKey: backgroundKey)
        let previousTalkEnabledValue = UserDefaults.standard.object(forKey: talkEnabledKey)
        let previousVoiceWakeEnabledValue = UserDefaults.standard.object(forKey: voiceWakeEnabledKey)
        defer {
            if let previousBackgroundValue {
                UserDefaults.standard.set(previousBackgroundValue, forKey: backgroundKey)
            } else {
                UserDefaults.standard.removeObject(forKey: backgroundKey)
            }
            if let previousTalkEnabledValue {
                UserDefaults.standard.set(previousTalkEnabledValue, forKey: talkEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: talkEnabledKey)
            }
            if let previousVoiceWakeEnabledValue {
                UserDefaults.standard.set(previousVoiceWakeEnabledValue, forKey: voiceWakeEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: voiceWakeEnabledKey)
            }
        }
        UserDefaults.standard.set(true, forKey: backgroundKey)
        UserDefaults.standard.set(false, forKey: talkEnabledKey)
        UserDefaults.standard.set(false, forKey: voiceWakeEnabledKey)

        let appModel = NodeAppModel()
        defer { appModel.voiceWake.setEnabled(false) }
        let admissionToken = UUID()
        appModel.talkMode.attachDurableChatOutbox(
            gatewayOwnerID: { "gateway-talk" },
            captureAdmission: { durableTalkCaptureAdmission(token: admissionToken) },
            persist: { _ in throw DurableTalkTestError.rejected })
        appModel.talkMode.updateGatewayConnected(true)
        appModel.talkMode.isEnabled = true
        let captureID = try await appModel.talkMode._test_prepareActivePTT(
            transcript: "background safely")
        appModel.voiceWake.isEnabled = true
        appModel.voiceWake.isListening = true
        appModel._test_acquirePTTVoiceWakeLease(captureID: captureID)
        appModel._test_acquirePTTVoiceWakeLease() // overlapping pttOnce owner
        #expect(appModel._test_pttVoiceWakeLeaseState().count == 2)
        #expect(!appModel.voiceWake.isListening)

        appModel.setScenePhase(.background)
        let backgroundState = appModel._test_pttVoiceWakeLeaseState()
        #expect(backgroundState.count == 1)
        #expect(backgroundState.captureID == nil)
        #expect(!appModel.talkMode.isPushToTalkActive)
        #expect(!appModel.voiceWake.isListening)
        #expect(appModel.voiceWake._test_resumeAfterExternalAudioCaptureCallCount() == 0)

        // The overlapping invoke can finish in background, but it no longer
        // owns permission to restart VoiceWake; the scene owns that decision.
        appModel._test_releasePTTVoiceWakeLease()
        await Task.yield()
        #expect(appModel._test_pttVoiceWakeLeaseState().count == 0)
        #expect(appModel.voiceWake._test_resumeAfterExternalAudioCaptureCallCount() == 0)

        appModel.talkMode.isEnabled = false
        appModel.setScenePhase(.active)
        #expect(appModel.voiceWake._test_resumeAfterExternalAudioCaptureCallCount() == 1)
    }
}
