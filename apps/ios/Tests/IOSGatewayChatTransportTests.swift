import Foundation
import OpenClawKit
import OpenClawProtocol
import os
import Testing
@testable import OpenClaw

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
            try await transport.setActiveSessionKey("node-test")
            Issue.record("Expected setActiveSessionKey to throw when gateway not connected")
        } catch {}
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
