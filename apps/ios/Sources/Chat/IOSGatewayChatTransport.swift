import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import OSLog

struct IOSGatewayChatTransport: OpenClawChatTransport {
    static let logger = Logger(subsystem: "ai.openclaw", category: "ios.chat.transport")
    static let defaultChatSendTimeoutMs = 30000
    private let gateway: GatewayNodeSession

    private struct CreateSessionParams: Codable {
        var key: String
        var label: String?
        var parentSessionKey: String?
    }

    private struct RunParams: Codable {
        var sessionKey: String
        var runId: String
    }

    private struct ListSessionsParams: Codable {
        var includeGlobal: Bool
        var includeUnknown: Bool
        var limit: Int?
    }

    private struct SessionKeyParams: Codable {
        var key: String
    }

    private struct ChatSendParams: Codable {
        var sessionKey: String
        var message: String
        var thinking: String
        var attachments: [OpenClawChatAttachmentPayload]?
        var timeoutMs: Int
        var idempotencyKey: String
    }

    private struct AgentWaitParams: Codable {
        var runId: String
        var timeoutMs: Int
    }

    private struct AgentWaitResponse: Codable {
        var runId: String?
        var status: String?
        var error: String?
    }

    struct AgentWaitCompletion: Equatable {
        var runId: String
        var status: String
        var completed: Bool
    }

    static func isAgentWaitCompletionStatus(_ status: String) -> Bool {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok", "completed", "success", "succeeded":
            true
        default:
            false
        }
    }

    static func diagnosticUUID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? "redacted"
    }

    static func diagnosticToken(_ value: String, maximumLength: Int = 128) -> String {
        guard !value.isEmpty, value.count <= maximumLength else { return "redacted" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "redacted" }
        return value
    }

    init(gateway: GatewayNodeSession) {
        self.gateway = gateway
    }

    static func agentWaitRequestTimeoutSeconds(timeoutMs: Int) -> Int {
        max(1, Int(ceil(Double(timeoutMs) / 1000.0)) + 5)
    }

    static func makeListSessionsParamsJSON(limit: Int?) throws -> String {
        try self.encodeParams(ListSessionsParams(includeGlobal: true, includeUnknown: false, limit: limit))
    }

    static func makeChatSendParamsJSON(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) throws -> String
    {
        let params = ChatSendParams(
            sessionKey: sessionKey,
            message: message,
            thinking: thinking,
            attachments: attachments.isEmpty ? nil : attachments,
            timeoutMs: self.defaultChatSendTimeoutMs,
            idempotencyKey: idempotencyKey)
        return try self.encodeParams(params)
    }

    static func decodeAgentWaitCompletion(_ data: Data, fallbackRunId: String) throws -> AgentWaitCompletion {
        let decoded = try JSONDecoder().decode(AgentWaitResponse.self, from: data)
        let status = (decoded.status ?? "unknown").lowercased()
        return AgentWaitCompletion(
            runId: decoded.runId ?? fallbackRunId,
            status: status,
            completed: self.isAgentWaitCompletionStatus(status))
    }

    private static func makeCreateSessionParamsJSON(
        key: String,
        label: String?,
        parentSessionKey: String?) throws -> String
    {
        let params = CreateSessionParams(
            key: key,
            label: label,
            parentSessionKey: parentSessionKey)
        return try self.encodeParams(params)
    }

    private static func makeRunParamsJSON(sessionKey: String, runId: String) throws -> String {
        try self.encodeParams(RunParams(sessionKey: sessionKey, runId: runId))
    }

    private static func makeSessionKeyParamsJSON(_ sessionKey: String) throws -> String {
        try self.encodeParams(SessionKeyParams(key: sessionKey))
    }

    private static func makeHistoryParamsJSON(sessionKey: String) throws -> String {
        struct Params: Codable { var sessionKey: String }
        return try self.encodeParams(Params(sessionKey: sessionKey))
    }

    private static func makeAgentWaitParamsJSON(runId: String, timeoutMs: Int) throws -> String {
        try self.encodeParams(AgentWaitParams(runId: runId, timeoutMs: timeoutMs))
    }

    private static func encodeParams(_ params: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(params)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                params,
                EncodingError.Context(codingPath: [], debugDescription: "Encoded gateway params were not UTF-8"))
        }
        return json
    }

    func createSession(
        key: String,
        label: String?,
        parentSessionKey: String?) async throws -> OpenClawChatCreateSessionResponse
    {
        let json = try Self.makeCreateSessionParamsJSON(
            key: key,
            label: label,
            parentSessionKey: parentSessionKey)
        let res = try await self.gateway.request(method: "sessions.create", paramsJSON: json, timeoutSeconds: 15)
        return try JSONDecoder().decode(OpenClawChatCreateSessionResponse.self, from: res)
    }

    func abortRun(sessionKey: String, runId: String) async throws {
        let json = try Self.makeRunParamsJSON(sessionKey: sessionKey, runId: runId)
        _ = try await self.gateway.request(method: "chat.abort", paramsJSON: json, timeoutSeconds: 10)
    }

    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        let json = try Self.makeListSessionsParamsJSON(limit: limit)
        let res = try await self.gateway.request(method: "sessions.list", paramsJSON: json, timeoutSeconds: 15)
        return try JSONDecoder().decode(OpenClawChatSessionsListResponse.self, from: res)
    }

    func setActiveSessionKey(_ sessionKey: String) async throws {
        struct Params: Codable { var key: String }
        let data = try JSONEncoder().encode(Params(key: sessionKey))
        let json = String(data: data, encoding: .utf8)
        _ = try await self.gateway.request(
            method: "sessions.messages.subscribe",
            paramsJSON: json,
            timeoutSeconds: 10)
    }

    func resetSession(sessionKey: String) async throws {
        let json = try Self.makeSessionKeyParamsJSON(sessionKey)
        _ = try await self.gateway.request(method: "sessions.reset", paramsJSON: json, timeoutSeconds: 10)
    }

    func compactSession(sessionKey: String) async throws {
        let json = try Self.makeSessionKeyParamsJSON(sessionKey)
        _ = try await self.gateway.request(method: "sessions.compact", paramsJSON: json, timeoutSeconds: 10)
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let json = try Self.makeHistoryParamsJSON(sessionKey: sessionKey)
        let res = try await self.gateway.request(method: "chat.history", paramsJSON: json, timeoutSeconds: 15)
        return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: res)
    }

    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let diagnosticCommandID = Self.diagnosticUUID(idempotencyKey)
        let startLogMessage =
            "event=chat_send_start command_id=\(diagnosticCommandID) "
                + "message_length=\(message.count) attachments=\(attachments.count)"
        Self.logger.info(
            "\(startLogMessage, privacy: .public)")
        GatewayDiagnostics.log(startLogMessage)
        let json = try Self.makeChatSendParamsJSON(
            sessionKey: sessionKey,
            message: message,
            thinking: thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments)
        do {
            let res = try await self.gateway.request(method: "chat.send", paramsJSON: json, timeoutSeconds: 35)
            let decoded = try JSONDecoder().decode(OpenClawChatSendResponse.self, from: res)
            let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            let diagnosticRunID = Self.diagnosticToken(decoded.runId)
            let diagnosticStatus = Self.diagnosticToken(decoded.status, maximumLength: 32)
            let acceptedLogMessage =
                "event=chat_send_accepted command_id=\(diagnosticCommandID) "
                    + "run_id=\(diagnosticRunID) status=\(diagnosticStatus) elapsed_ms=\(elapsedMs)"
            Self.logger.info("\(acceptedLogMessage, privacy: .public)")
            GatewayDiagnostics.log(acceptedLogMessage)
            return decoded
        } catch {
            let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            let nsError = error as NSError
            let errorDomain = Self.diagnosticToken(nsError.domain, maximumLength: 80)
            let uncertainLogMessage =
                "event=chat_send_failed command_id=\(diagnosticCommandID) "
                    + "outcome=send_failed_unclassified elapsed_ms=\(elapsedMs) "
                    + "error_domain=\(errorDomain) error_code=\(nsError.code)"
            Self.logger.error("\(uncertainLogMessage, privacy: .public)")
            GatewayDiagnostics.log(uncertainLogMessage)
            throw error
        }
    }

    func waitForRunCompletion(runId rawRunId: String, timeoutMs: Int) async -> Bool {
        let runId = rawRunId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runId.isEmpty else { return false }

        do {
            let json = try Self.makeAgentWaitParamsJSON(runId: runId, timeoutMs: timeoutMs)
            let requestTimeoutSeconds = Self.agentWaitRequestTimeoutSeconds(timeoutMs: timeoutMs)
            GatewayDiagnostics.log("agent.wait start runId=\(runId)")
            let res = try await self.gateway.request(
                method: "agent.wait",
                paramsJSON: json,
                timeoutSeconds: requestTimeoutSeconds)
            let completion = try Self.decodeAgentWaitCompletion(res, fallbackRunId: runId)
            GatewayDiagnostics.log("agent.wait completed runId=\(completion.runId) status=\(completion.status)")
            if !completion.completed {
                Self.logger.warning(
                    "agent.wait status \(completion.status, privacy: .public) runId=\(runId, privacy: .public)")
            }
            return completion.completed
        } catch {
            Self.logger.warning("agent.wait failed \(error.localizedDescription, privacy: .public)")
            GatewayDiagnostics.log("agent.wait failed runId=\(runId) error=\(error.localizedDescription)")
            return false
        }
    }

    func requestHealth(timeoutMs: Int) async throws -> Bool {
        let seconds = max(1, Int(ceil(Double(timeoutMs) / 1000.0)))
        let res = try await self.gateway.request(method: "health", paramsJSON: nil, timeoutSeconds: seconds)
        return (try? JSONDecoder().decode(OpenClawGatewayHealthOK.self, from: res))?.ok ?? true
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { continuation in
            let task = Task {
                let stream = await self.gateway.subscribeServerEvents()
                for await evt in stream {
                    if Task.isCancelled { return }
                    if let mapped = Self.mapEventFrame(evt) {
                        continuation.yield(mapped)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    static func mapEventFrame(_ evt: EventFrame) -> OpenClawChatTransportEvent? {
        switch evt.event {
        case "tick":
            return .tick
        case "seqGap":
            return .seqGap
        case "health":
            guard let payload = evt.payload else { return nil }
            let ok = (try? GatewayPayloadDecoding.decode(
                payload,
                as: OpenClawGatewayHealthOK.self))?.ok ?? true
            return .health(ok: ok)
        case "chat":
            guard let payload = evt.payload else { return nil }
            guard let chatPayload = try? GatewayPayloadDecoding.decode(
                payload,
                as: OpenClawChatEventPayload.self)
            else {
                return nil
            }
            Self.recordMappedChatEvent(chatPayload, frame: evt)
            return .chat(chatPayload)
        case "session.message":
            guard let payload = evt.payload else { return nil }
            guard let message = try? GatewayPayloadDecoding.decode(
                payload,
                as: OpenClawSessionMessageEventPayload.self)
            else {
                return nil
            }
            let transcriptMessageID = Self.resolvedTranscriptMessageID(
                embedded: message.message?.transcriptMessageID,
                envelope: message.messageId)
            Self.recordMappedSessionMessageEvent(
                message,
                transcriptMessageID: transcriptMessageID,
                frame: evt)
            if var canonicalMessage = message.message,
               let transcriptMessageID,
               canonicalMessage.transcriptMessageID != transcriptMessageID
            {
                // Prefer embedded canonical identity and use the live envelope
                // only as a fallback. Keep mapping and diagnostic correlation on
                // the exact same normalized identity.
                canonicalMessage.transcriptMessageID = transcriptMessageID
                return .sessionMessage(OpenClawSessionMessageEventPayload(
                    sessionKey: message.sessionKey,
                    agentId: message.agentId,
                    message: canonicalMessage,
                    messageId: message.messageId,
                    messageSeq: message.messageSeq))
            }
            return .sessionMessage(message)
        case "agent":
            guard let payload = evt.payload else { return nil }
            guard let agentPayload = try? GatewayPayloadDecoding.decode(
                payload,
                as: OpenClawAgentEventPayload.self)
            else {
                return nil
            }
            Self.recordMappedAgentEvent(agentPayload, frame: evt)
            return .agent(agentPayload)
        default:
            return nil
        }
    }

    private static func resolvedTranscriptMessageID(embedded: String?, envelope: String?) -> String? {
        for candidate in [embedded, envelope] {
            let normalized = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    private static func recordMappedChatEvent(_ payload: OpenClawChatEventPayload, frame: EventFrame) {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .chat,
            state: "mapped_chat",
            sessionIdentifier: payload.sessionKey,
            runIdentifier: payload.runId,
            sequence: frame.seq,
            stream: "chat"))
    }

    private static func recordMappedSessionMessageEvent(
        _ payload: OpenClawSessionMessageEventPayload,
        transcriptMessageID: String?,
        frame: EventFrame)
    {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .chat,
            state: "mapped_session_message",
            sessionIdentifier: payload.sessionKey,
            messageIdentifier: transcriptMessageID,
            sequence: payload.messageSeq ?? frame.seq,
            stream: "session.message"))
    }

    private static func recordMappedAgentEvent(_ payload: OpenClawAgentEventPayload, frame: EventFrame) {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .chat,
            state: "mapped_agent",
            runIdentifier: payload.runId,
            eventIdentifier: payload.id,
            sequence: payload.seq ?? frame.seq,
            stream: payload.stream))
    }
}
