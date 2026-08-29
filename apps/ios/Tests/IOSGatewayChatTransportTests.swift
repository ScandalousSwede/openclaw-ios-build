import Foundation
import OpenClawKit
import OpenClawProtocol
import os
import Testing
@testable import OpenClaw

private actor IOSSessionMutationGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.open else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func release() {
        self.open = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waiterCount() -> Int { self.waiters.count }
}

private actor IOSSessionMutationRouterSpy: IOSGatewaySessionMutationRouting {
    private var gatewayID: String
    private var generation: UInt64 = 1
    private var methods: [String] = []
    private let gate: IOSSessionMutationGate?
    private let returnedGatewayID: String?

    init(
        gatewayID: String,
        gate: IOSSessionMutationGate? = nil,
        returnedGatewayID: String? = nil)
    {
        self.gatewayID = gatewayID
        self.gate = gate
        self.returnedGatewayID = returnedGatewayID
    }

    func currentSessionMutationRoute(ifGatewayID stableGatewayID: String)
        -> IOSGatewaySessionMutationRoute?
    {
        guard stableGatewayID == self.gatewayID else { return nil }
        let admittedGeneration = self.generation
        return IOSGatewaySessionMutationRoute(
            stableGatewayID: self.returnedGatewayID ?? stableGatewayID) { [weak self] method, _, _ in
            guard let self else { throw CancellationError() }
            return try await self.perform(method: method, admittedGeneration: admittedGeneration)
        }
    }

    func replaceGateway(with gatewayID: String) {
        self.gatewayID = gatewayID
        self.generation &+= 1
    }

    func recordedMethods() -> [String] { self.methods }

    private func perform(method: String, admittedGeneration: UInt64) async throws -> Data {
        await self.gate?.wait()
        guard admittedGeneration == self.generation else { throw CancellationError() }
        self.methods.append(method)
        if method == "sessions.create" {
            return Data(#"{"ok":true,"key":"session-new","sessionId":"session-id"}"#.utf8)
        }
        return Data("{}".utf8)
    }
}

private func waitForIOSSessionMutation(
    _ description: String,
    condition: @escaping @Sendable () async -> Bool) async throws
{
    for _ in 0..<500 {
        if await condition() { return }
        await Task.yield()
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw NSError(domain: "IOSGatewayChatTransportTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Timed out: \(description)",
    ])
}

@Suite(.serialized) struct IOSGatewayChatTransportTests {
    private func object(from json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        let value = try JSONSerialization.jsonObject(with: data)
        return try #require(value as? [String: Any])
    }

    @Test func agentWaitTreatsSuccessAsCompletion() {
        #expect(IOSGatewayChatTransport.isAgentWaitCompletionStatus("success"))
        #expect(IOSGatewayChatTransport.isAgentWaitCompletionStatus(" ok "))
        #expect(IOSGatewayChatTransport.isAgentWaitCompletionStatus("completed"))
        #expect(IOSGatewayChatTransport.isAgentWaitCompletionStatus("succeeded"))
        #expect(!IOSGatewayChatTransport.isAgentWaitCompletionStatus("timeout"))
        #expect(!IOSGatewayChatTransport.isAgentWaitCompletionStatus("failed"))
    }

    @Test func agentWaitTimeoutAddsGatewayMargin() {
        #expect(IOSGatewayChatTransport.agentWaitRequestTimeoutSeconds(timeoutMs: 1) == 6)
        #expect(IOSGatewayChatTransport.agentWaitRequestTimeoutSeconds(timeoutMs: 1000) == 6)
        #expect(IOSGatewayChatTransport.agentWaitRequestTimeoutSeconds(timeoutMs: 30000) == 35)
    }

    @Test func reliabilityDiagnosticsValidateAndBoundPublicIdentifiers() {
        #expect(
            IOSGatewayChatTransport.diagnosticUUID("9B2D6A3B-1334-4D09-8606-7C8E19EAB625")
                == "9b2d6a3b-1334-4d09-8606-7c8e19eab625")
        #expect(IOSGatewayChatTransport.diagnosticUUID("not-a-uuid\nsecret") == "redacted")
        #expect(IOSGatewayChatTransport.diagnosticToken("run_123:ok") == "run_123:ok")
        #expect(IOSGatewayChatTransport.diagnosticToken("run\nsecret") == "redacted")
        #expect(IOSGatewayChatTransport.diagnosticToken(String(repeating: "a", count: 129)) == "redacted")
    }

    @Test func agentWaitCompletionDecodesFallbackRunId() throws {
        let data = Data(#"{"status":"completed"}"#.utf8)
        let completion = try IOSGatewayChatTransport.decodeAgentWaitCompletion(data, fallbackRunId: "run-local")
        #expect(completion.runId == "run-local")
        #expect(completion.status == "completed")
        #expect(completion.completed)
    }

    @Test func helloBindsRoutingCapabilityAndAuthenticatedOperatorScopes() throws {
        let data = Data(
            #"""
            {"type":"hello-ok","protocol":4,"server":{"version":"2026.7.1"},
            "features":{"capabilities":["chat-send-routing-contract"]},
            "snapshot":{"presence":[],"health":{},"stateVersion":{"presence":0,"health":0},"uptimeMs":0},
            "auth":{"role":"operator","scopes":["operator.write","operator.talk.secrets","operator.read"]},
            "policy":{}}
            """#
                .utf8)
        let hello = try JSONDecoder().decode(HelloOk.self, from: data)

        #expect(hello.supportsServerCapability(.chatSendRoutingContract))
        #expect(hello.authenticatedOperatorScopes == [
            "operator.read",
            "operator.talk.secrets",
            "operator.write",
        ])
    }

    @Test func routingContractUsesNormalizedGatewayMainSemantics() throws {
        let data = Data(#"{"defaultId":"Main","mainKey":"Primary","scope":"Per-Sender","agents":[]}"#.utf8)
        #expect(try IOSGatewayChatTransport.decodeSessionRoutingContract(data) == "per-sender|primary|main")
    }

    @Test func listSessionsParamsIncludeGlobalSessionsButNotUnknown() throws {
        let params = try self.object(from: IOSGatewayChatTransport.makeListSessionsParamsJSON(limit: 12))
        #expect(params["includeGlobal"] as? Bool == true)
        #expect(params["includeUnknown"] as? Bool == false)
        #expect(params["limit"] as? Int == 12)
    }

    @Test func chatSendParamsOmitEmptyAttachmentsAndKeepSessionFields() throws {
        let params = try self.object(
            from: IOSGatewayChatTransport.makeChatSendParamsJSON(
                sessionKey: "agent:main",
                message: "hello",
                thinking: "low",
                idempotencyKey: "send-1",
                attachments: []))
        #expect(params["sessionKey"] as? String == "agent:main")
        #expect(params["message"] as? String == "hello")
        #expect(params["thinking"] as? String == "low")
        #expect(params["idempotencyKey"] as? String == "send-1")
        #expect(params["timeoutMs"] as? Int == IOSGatewayChatTransport.defaultChatSendTimeoutMs)
        #expect(params["attachments"] == nil)
    }

    @Test func guardedChatSendIncludesExactRoutingContractAndRawCommandIdentity() throws {
        let params = try self.object(
            from: IOSGatewayChatTransport.makeChatSendParamsJSON(
                sessionKey: "agent:main:main",
                message: "hello",
                thinking: "low",
                idempotencyKey: "raw-command-id",
                expectedSessionRoutingContract: "per-sender|main|main",
                attachments: []))
        #expect(params["idempotencyKey"] as? String == "raw-command-id")
        #expect(params["expectedSessionRoutingContract"] as? String == "per-sender|main|main")
    }

    @Test func boundedHistoryPageRequestUsesDeployedSchemaFields() throws {
        let params = try self.object(
            from: IOSGatewayChatTransport.makeHistoryParamsJSON(
                sessionKey: "agent:main:main",
                limit: 250,
                offset: 500,
                maxChars: 400_000))
        #expect(Set(params.keys) == ["sessionKey", "limit", "offset", "maxChars"])
        #expect(params["sessionKey"] as? String == "agent:main:main")
        #expect(params["limit"] as? Int == 250)
        #expect(params["offset"] as? Int == 500)
        #expect(params["maxChars"] as? Int == 400_000)
    }

    @Test func ordinaryHistoryRequestOmitsOptionalTailFields() throws {
        let params = try self.object(
            from: IOSGatewayChatTransport.makeHistoryParamsJSON(sessionKey: "agent:main:main"))
        #expect(Set(params.keys) == ["sessionKey"])
        #expect(params["sessionKey"] as? String == "agent:main:main")
    }

    @Test func pagedHistoryBoundsMatchDeployedLimits() throws {
        let maximums = try self.object(
            from: IOSGatewayChatTransport.makeBoundedHistoryPageParamsJSON(
                sessionKey: "agent:main:main",
                limit: 5000,
                offset: -10,
                maxChars: 2_000_000))
        #expect(maximums["limit"] as? Int == 1000)
        #expect(maximums["offset"] as? Int == 0)
        #expect(maximums["maxChars"] as? Int == 500_000)

        let minimums = try self.object(
            from: IOSGatewayChatTransport.makeBoundedHistoryPageParamsJSON(
                sessionKey: "agent:main:main",
                limit: 0,
                offset: 0,
                maxChars: 0))
        #expect(minimums["limit"] as? Int == 1)
        #expect(minimums["maxChars"] as? Int == 1)
    }

    @Test func historyPageRequiresCoherentAdvancingMetadata() throws {
        let page = try IOSGatewayChatTransport.decodeHistoryPage(
            Data(
                #"""
                {"sessionKey":"agent:main:main","sessionId":"session-1","messages":[],
                "offset":200,"nextOffset":400,"hasMore":true,"totalMessages":850}
                """#
                    .utf8),
            requestedOffset: 200)
        #expect(page.payload.sessionKey == "agent:main:main")
        #expect(page.offset == 200)
        #expect(page.nextOffset == 400)
        #expect(page.hasMore)
        #expect(page.totalMessages == 850)
    }

    @Test func historyTerminalPageRequiresAbsentNextOffset() throws {
        let page = try IOSGatewayChatTransport.decodeHistoryPage(
            Data(
                #"""
                {"sessionKey":"agent:main:main","sessionId":"session-1","messages":[],
                "offset":800,"hasMore":false,"totalMessages":850}
                """#
                    .utf8),
            requestedOffset: 800)
        #expect(page.nextOffset == nil)
        #expect(!page.hasMore)
    }

    @Test func historyPageAcceptsOnlyDeployedEmptySessionMetadataException() throws {
        let emptySession = Data(
            #"{"sessionKey":"agent:main:new-session","messages":[]}"#.utf8)
        let page = try IOSGatewayChatTransport.decodeHistoryPage(emptySession, requestedOffset: 0)
        #expect(page.offset == 0)
        #expect(page.totalMessages == 0)
        #expect(!page.hasMore)
        #expect(page.nextOffset == nil)

        #expect(throws: IOSGatewayChatTransport.HistoryPageValidationError.offsetMissing) {
            try IOSGatewayChatTransport.decodeHistoryPage(emptySession, requestedOffset: 1)
        }

        let nonemptySessionless = Data(
            #"""
            {"sessionKey":"agent:main:new-session","messages":[{"role":"user","content":"redacted"}]}
            """#
                .utf8)
        #expect(throws: IOSGatewayChatTransport.HistoryPageValidationError.offsetMissing) {
            try IOSGatewayChatTransport.decodeHistoryPage(nonemptySessionless, requestedOffset: 0)
        }
    }

    @Test func historyPageFailsClosedOnMissingOrMismatchedMetadata() {
        let missingMetadata = Data(
            #"{"sessionKey":"agent:main:main","sessionId":"session-1","messages":[]}"#.utf8)
        #expect(throws: IOSGatewayChatTransport.HistoryPageValidationError.offsetMissing) {
            try IOSGatewayChatTransport.decodeHistoryPage(missingMetadata, requestedOffset: 0)
        }

        let mismatchedOffset = Data(
            #"""
            {"sessionKey":"agent:main:main","sessionId":"session-1","messages":[],
            "offset":200,"hasMore":false,"totalMessages":200}
            """#
                .utf8)
        let mismatch = IOSGatewayChatTransport.HistoryPageValidationError.offsetMismatch(
            expected: 0,
            actual: 200)
        #expect(throws: mismatch) {
            try IOSGatewayChatTransport.decodeHistoryPage(mismatchedOffset, requestedOffset: 0)
        }
    }

    @Test func historyPageRejectsLoopsAndInconsistentNextOffset() {
        let looping = Data(
            #"""
            {"sessionKey":"agent:main:main","sessionId":"session-1","messages":[],
            "offset":200,"nextOffset":200,"hasMore":true,"totalMessages":850}
            """#
                .utf8)
        let loop = IOSGatewayChatTransport.HistoryPageValidationError.nextOffsetDidNotAdvance(
            offset: 200,
            nextOffset: 200)
        #expect(throws: loop) {
            try IOSGatewayChatTransport.decodeHistoryPage(looping, requestedOffset: 200)
        }

        let terminalWithNext = Data(
            #"""
            {"sessionKey":"agent:main:main","sessionId":"session-1","messages":[],
            "offset":800,"nextOffset":850,"hasMore":false,"totalMessages":850}
            """#
                .utf8)
        #expect(throws: IOSGatewayChatTransport.HistoryPageValidationError.unexpectedNextOffset(850)) {
            try IOSGatewayChatTransport.decodeHistoryPage(terminalWithNext, requestedOffset: 800)
        }
    }

    @Test func historyPageRequiresTotalHasMoreAndAdvancingNextOffset() {
        let missingHasMore = Data(
            #"""
            {"sessionKey":"agent:main:main","sessionId":"session-1","messages":[],
            "offset":0,"totalMessages":850}
            """#
                .utf8)
        #expect(throws: IOSGatewayChatTransport.HistoryPageValidationError.hasMoreMissing) {
            try IOSGatewayChatTransport.decodeHistoryPage(missingHasMore, requestedOffset: 0)
        }

        let negativeTotal = Data(
            #"""
            {"sessionKey":"agent:main:main","sessionId":"session-1","messages":[],
            "offset":0,"hasMore":false,"totalMessages":-1}
            """#
                .utf8)
        #expect(throws: IOSGatewayChatTransport.HistoryPageValidationError.totalMessagesInvalid(-1)) {
            try IOSGatewayChatTransport.decodeHistoryPage(negativeTotal, requestedOffset: 0)
        }

        let missingNext = Data(
            #"""
            {"sessionKey":"agent:main:main","sessionId":"session-1","messages":[],
            "offset":0,"hasMore":true,"totalMessages":850}
            """#
                .utf8)
        #expect(throws: IOSGatewayChatTransport.HistoryPageValidationError.nextOffsetMissing) {
            try IOSGatewayChatTransport.decodeHistoryPage(missingNext, requestedOffset: 0)
        }

        let nextOutsideTotal = Data(
            #"""
            {"sessionKey":"agent:main:main","sessionId":"session-1","messages":[],
            "offset":800,"nextOffset":850,"hasMore":true,"totalMessages":850}
            """#
                .utf8)
        let outside = IOSGatewayChatTransport.HistoryPageValidationError.nextOffsetOutsideTotal(
            nextOffset: 850,
            totalMessages: 850)
        #expect(throws: outside) {
            try IOSGatewayChatTransport.decodeHistoryPage(nextOutsideTotal, requestedOffset: 800)
        }
    }

    @Test func dispatchMappingPreservesEveryDurableOutcome() {
        #expect(IOSGatewayChatTransport.mapDispatchResult(
            .notDispatched,
            rawCommandID: "raw-1") == .notDispatched)
        #expect(IOSGatewayChatTransport.mapDispatchResult(
            .ambiguous(code: "url:-1005"),
            rawCommandID: "raw-1") == .ambiguous(code: "url:-1005"))
        #expect(IOSGatewayChatTransport.mapDispatchResult(
            .rejected(code: "INVALID_REQUEST", reason: "session-routing-changed"),
            rawCommandID: "raw-1") == .blockedRouteChanged)
        #expect(IOSGatewayChatTransport.mapDispatchResult(
            .rejected(code: "INVALID_REQUEST", reason: "invalid-session"),
            rawCommandID: "raw-1") == .dispatchRejected(
                code: "INVALID_REQUEST",
                reason: "invalid-session"))
    }

    @Test func dispatchAcceptsOnlyAckRunIDEqualToRawCommandID() {
        let accepted = GatewayRequestDispatchResult.response(
            Data(#"{"runId":"raw-1","status":"started"}"#.utf8))
        let mismatched = GatewayRequestDispatchResult.response(
            Data(#"{"runId":"raw-1:user","status":"started"}"#.utf8))
        let malformed = GatewayRequestDispatchResult.response(Data(#"{"status":"started"}"#.utf8))

        #expect(IOSGatewayChatTransport.mapDispatchResult(
            accepted,
            rawCommandID: "raw-1") == .accepted(runID: "raw-1", status: "started"))
        #expect(IOSGatewayChatTransport.mapDispatchResult(
            mismatched,
            rawCommandID: "raw-1") == .ambiguous(code: "ack-run-id-mismatch"))
        #expect(IOSGatewayChatTransport.mapDispatchResult(
            malformed,
            rawCommandID: "raw-1") == .ambiguous(code: "invalid-ack"))
    }

    @Test func outboxLeaseFailsClosedWithoutStableGatewayIdentity() async {
        let transport = IOSGatewayChatTransport(gateway: GatewayNodeSession())
        switch await transport.acquireOutboxRouteLease() {
        case .unavailable(reason: .gatewayIdentityUnavailable):
            break
        default:
            Issue.record("missing gateway identity must fail closed")
        }
    }

    @Test func outboxLeaseReportsOperatorSessionUnavailableSeparatelyFromOffline() async {
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            stableGatewayID: "gateway-a",
            routeAbsenceReason: { .operatorSessionUnavailable })
        switch await transport.acquireOutboxRouteLease() {
        case .unavailable(reason: .operatorSessionUnavailable):
            break
        default:
            Issue.record("missing operator route must not be projected as generic offline")
        }
    }

    @Test func requestsFailFastWhenGatewayNotConnected() async {
        let gateway = GatewayNodeSession()
        let transport = IOSGatewayChatTransport(gateway: gateway)

        do {
            _ = try await transport.requestHistory(sessionKey: "node-test")
            Issue.record("Expected requestHistory to throw when gateway not connected")
        } catch {}

        do {
            _ = try await transport.sendMessage(
                sessionKey: "node-test",
                message: "hello",
                thinking: "low",
                idempotencyKey: "idempotency",
                attachments: [])
            Issue.record("Expected sendMessage to throw when gateway not connected")
        } catch {}

        do {
            _ = try await transport.requestHealth(timeoutMs: 250)
            Issue.record("Expected requestHealth to throw when gateway not connected")
        } catch {}

        do {
            try await transport.resetSession(sessionKey: "node-test")
            Issue.record("Expected resetSession to throw when gateway not connected")
        } catch {}

        do {
            _ = try await transport.createSession(
                key: "session-new",
                label: nil,
                parentSessionKey: "node-test")
            Issue.record("Expected createSession to throw when gateway not connected")
        } catch {}

        do {
            try await transport.setActiveSessionKey("node-test")
            Issue.record("Expected setActiveSessionKey to throw when gateway not connected")
        } catch {}
    }

    @Test func sessionMutationsDispatchOnlyThroughTheCapturedStableRoute() async throws {
        let router = IOSSessionMutationRouterSpy(gatewayID: "gateway-a")
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            stableGatewayID: "gateway-a",
            sessionMutationRouter: router)

        let created = try await transport.createSession(
            key: "session-new",
            label: "New",
            parentSessionKey: "session-a")
        try await transport.resetSession(sessionKey: "session-a")
        try await transport.compactSession(sessionKey: "session-a")

        #expect(created.key == "session-new")
        #expect(await router.recordedMethods() == [
            "sessions.create",
            "sessions.reset",
            "sessions.compact",
        ])
    }

    @Test func replacementGatewayCannotReceiveCapturedSessionMutation() async throws {
        for action in ["create", "reset", "compact"] {
            let gate = IOSSessionMutationGate()
            let router = IOSSessionMutationRouterSpy(gatewayID: "gateway-a", gate: gate)
            let transport = IOSGatewayChatTransport(
                gateway: GatewayNodeSession(),
                stableGatewayID: "gateway-a",
                sessionMutationRouter: router)
            let request = Task {
                if action == "create" {
                    _ = try await transport.createSession(
                        key: "session-new",
                        label: nil,
                        parentSessionKey: "session-a")
                } else if action == "reset" {
                    try await transport.resetSession(sessionKey: "session-a")
                } else {
                    try await transport.compactSession(sessionKey: "session-a")
                }
            }
            try await waitForIOSSessionMutation("\(action) reaches captured route") {
                await gate.waiterCount() == 1
            }
            await router.replaceGateway(with: "gateway-b")
            await gate.release()
            await #expect(throws: CancellationError.self) {
                try await request.value
            }
            #expect(await router.recordedMethods().isEmpty)
        }
    }

    @Test func mismatchedMutationRouteFailsClosedBeforeAnyEffect() async {
        let router = IOSSessionMutationRouterSpy(
            gatewayID: "gateway-a",
            returnedGatewayID: "gateway-b")
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            stableGatewayID: "gateway-a",
            sessionMutationRouter: router)

        await #expect(throws: CancellationError.self) {
            _ = try await transport.createSession(
                key: "session-new",
                label: nil,
                parentSessionKey: "session-a")
        }
        await #expect(throws: CancellationError.self) {
            try await transport.resetSession(sessionKey: "session-a")
        }
        await #expect(throws: CancellationError.self) {
            try await transport.compactSession(sessionKey: "session-a")
        }
        #expect(await router.recordedMethods().isEmpty)
    }

    @Test func mapsSessionMessageEventToSessionMessage() {
        let payload = AnyCodable([
            "sessionKey": AnyCodable("agent:main:main"),
            "agentId": AnyCodable("main"),
            "messageId": AnyCodable("msg-1"),
            "messageSeq": AnyCodable(7),
            "message": AnyCodable([
                "role": AnyCodable("assistant"),
                "content": AnyCodable([
                    AnyCodable([
                        "type": AnyCodable("text"),
                        "text": AnyCodable("agent reply"),
                    ]),
                ]),
                "timestamp": AnyCodable(1234.5),
            ]),
        ])
        let frame = EventFrame(
            type: "event",
            event: "session.message",
            payload: payload,
            seq: 1,
            stateversion: nil)
        let mapped = IOSGatewayChatTransport.mapEventFrame(frame)

        switch mapped {
        case let .sessionMessage(message):
            #expect(message.sessionKey == "agent:main:main")
            #expect(message.agentId == "main")
            #expect(message.messageId == "msg-1")
            #expect(message.messageSeq == 7)
            #expect(message.message?.role == "assistant")
            #expect(message.message?.content.first?.text == "agent reply")
            #expect(message.message?.transcriptMessageID == "msg-1")
        default:
            Issue.record("expected .sessionMessage from session.message event, got \(String(describing: mapped))")
        }
    }

    @Test func sessionMessageKeepsEmbeddedTranscriptIdentityOverEnvelopeFallback() throws {
        let captured = OSAllocatedUnfairLock(initialState: [String]())
        OpenClawDiagnosticRecorder.installSink { line in
            captured.withLock { $0.append(line) }
        }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        let payload = AnyCodable([
            "sessionKey": AnyCodable("agent:main:main"),
            "messageId": AnyCodable("envelope-id"),
            "message": AnyCodable([
                "role": AnyCodable("assistant"),
                "content": AnyCodable("agent reply"),
                "timestamp": AnyCodable(1234.5),
                "__openclaw": AnyCodable(["id": AnyCodable("embedded-id")]),
            ]),
        ])
        let frame = EventFrame(
            type: "event",
            event: "session.message",
            payload: payload,
            seq: 1,
            stateversion: nil)

        switch IOSGatewayChatTransport.mapEventFrame(frame) {
        case let .sessionMessage(message):
            #expect(message.message?.transcriptMessageID == "embedded-id")
        default:
            Issue.record("expected .sessionMessage with embedded identity")
        }

        let mappedMessageDiagnostics = captured.withLock { lines in
            lines.compactMap(OpenClawDiagnosticRecorder.decodeRecord)
                .filter { $0.state == "mapped_session_message" }
        }
        try #require(mappedMessageDiagnostics.count == 1)
        let diagnostic = try #require(mappedMessageDiagnostics.first)
        let expectedEmbeddedHash = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "expected",
            messageIdentifier: "embedded-id").messageID
        let envelopeHash = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "expected",
            messageIdentifier: "envelope-id").messageID
        #expect(diagnostic.messageID == expectedEmbeddedHash)
        #expect(diagnostic.messageID != envelopeHash)
    }

    @Test func mapsChatEventToChat() {
        let payload = AnyCodable([
            "runId": AnyCodable("run-1"),
            "sessionKey": AnyCodable("main"),
            "state": AnyCodable("final"),
        ])
        let frame = EventFrame(type: "event", event: "chat", payload: payload, seq: 1, stateversion: nil)
        let mapped = IOSGatewayChatTransport.mapEventFrame(frame)

        switch mapped {
        case let .chat(chat):
            #expect(chat.runId == "run-1")
            #expect(chat.sessionKey == "main")
            #expect(chat.state == "final")
        default:
            Issue.record("expected .chat from chat event, got \(String(describing: mapped))")
        }
    }

    @Test func mappedEventDiagnosticsContainOnlySanitizedCorrelationIdentity() throws {
        let captured = OSAllocatedUnfairLock(initialState: [String]())
        OpenClawDiagnosticRecorder.installSink { line in
            captured.withLock { lines in
                lines.append(line)
            }
        }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        let chatFrame = EventFrame(
            type: "event",
            event: "chat",
            payload: AnyCodable([
                "runId": AnyCodable("run-chat"),
                "sessionKey": AnyCodable("private-session-key"),
                "state": AnyCodable("final"),
                "message": AnyCodable("PRIVATE_CHAT_BODY"),
            ]),
            seq: 41,
            stateversion: nil)
        let messageFrame = EventFrame(
            type: "event",
            event: "session.message",
            payload: AnyCodable([
                "sessionKey": AnyCodable("private-session-key"),
                "messageId": AnyCodable("message-7"),
                "messageSeq": AnyCodable(7),
                "message": AnyCodable([
                    "role": AnyCodable("assistant"),
                    "content": AnyCodable("PRIVATE_TRANSCRIPT_BODY"),
                    "timestamp": AnyCodable(1234.5),
                ]),
            ]),
            seq: 42,
            stateversion: nil)
        let agentFrame = EventFrame(
            type: "event",
            event: "agent",
            payload: AnyCodable([
                "runId": AnyCodable("run-agent"),
                "seq": AnyCodable(9),
                "stream": AnyCodable("tool"),
                "ts": AnyCodable(1234),
                "data": AnyCodable([
                    "args": AnyCodable("PRIVATE_TOOL_ARGUMENTS"),
                    "result": AnyCodable("PRIVATE_TOOL_RESULT"),
                ]),
            ]),
            seq: 43,
            stateversion: nil)

        #expect(IOSGatewayChatTransport.mapEventFrame(chatFrame) != nil)
        #expect(IOSGatewayChatTransport.mapEventFrame(messageFrame) != nil)
        #expect(IOSGatewayChatTransport.mapEventFrame(agentFrame) != nil)

        let lines = captured.withLock { $0 }
        let diagnostics = try lines.map { line in
            try #require(OpenClawDiagnosticRecorder.decodeRecord(line))
        }
        let mappedChats = diagnostics.filter { $0.state == "mapped_chat" }
        let mappedMessages = diagnostics.filter { $0.state == "mapped_session_message" }
        let mappedAgents = diagnostics.filter { $0.state == "mapped_agent" }
        try #require(mappedChats.count == 1)
        try #require(mappedMessages.count == 1)
        try #require(mappedAgents.count == 1)

        let chat = try #require(mappedChats.first)
        #expect(chat.kind == .chat)
        #expect(chat.sessionHash?.count == 16)
        #expect(chat.sessionHash != "private-session-key")
        #expect(chat.runID?.count == 16)
        #expect(chat.runID != "run-chat")
        #expect(chat.sequence == 41)
        #expect(chat.stream == "chat")
        #expect(chat.messageID == nil)
        #expect(chat.eventID == nil)

        let message = try #require(mappedMessages.first)
        #expect(message.sessionHash == chat.sessionHash)
        #expect(message.messageID?.count == 16)
        #expect(message.messageID != "message-7")
        #expect(message.sequence == 7)
        #expect(message.stream == "session.message")
        #expect(message.runID == nil)
        #expect(message.eventID == nil)

        let agent = try #require(mappedAgents.first)
        #expect(agent.runID?.count == 16)
        #expect(agent.runID != "run-agent")
        #expect(agent.eventID?.count == 16)
        #expect(agent.eventID != "run-agent-9")
        #expect(agent.sequence == 9)
        #expect(agent.stream == "tool")
        #expect(agent.sessionHash == nil)
        #expect(agent.messageID == nil)

        let serialized = try lines.map { line -> String in
            let payload = String(line.dropFirst("aies_diagnostic=".count))
            let data = try #require(Data(base64Encoded: payload))
            return try #require(String(data: data, encoding: .utf8))
        }.joined(separator: "\n")
        #expect(!serialized.contains("private-session-key"))
        #expect(!serialized.contains("PRIVATE_CHAT_BODY"))
        #expect(!serialized.contains("PRIVATE_TRANSCRIPT_BODY"))
        #expect(!serialized.contains("PRIVATE_TOOL_ARGUMENTS"))
        #expect(!serialized.contains("PRIVATE_TOOL_RESULT"))
        #expect(!serialized.contains("run-chat"))
        #expect(!serialized.contains("message-7"))
        #expect(!serialized.contains("run-agent"))
    }

    @Test func mapsUnknownEventToNil() {
        let frame = EventFrame(
            type: "event",
            event: "unknown",
            payload: AnyCodable(["a": AnyCodable(1)]),
            seq: 1,
            stateversion: nil)
        let mapped = IOSGatewayChatTransport.mapEventFrame(frame)
        #expect(mapped == nil)
    }
}
