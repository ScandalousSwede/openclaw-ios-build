import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import OSLog

struct IOSGatewaySessionMutationRoute: Sendable {
    typealias Request = @Sendable (
        _ method: String,
        _ paramsJSON: String?,
        _ timeoutSeconds: Int) async throws -> Data

    let stableGatewayID: String
    private let requestImpl: Request

    init(stableGatewayID: String, request: @escaping Request) {
        self.stableGatewayID = stableGatewayID
        self.requestImpl = request
    }

    func request(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data {
        try await self.requestImpl(method, paramsJSON, timeoutSeconds)
    }
}

protocol IOSGatewaySessionMutationRouting: Sendable {
    func currentSessionMutationRoute(ifGatewayID stableGatewayID: String)
        async -> IOSGatewaySessionMutationRoute?
}

private struct LiveIOSGatewaySessionMutationRouter: IOSGatewaySessionMutationRouting {
    let gateway: GatewayNodeSession

    func currentSessionMutationRoute(ifGatewayID stableGatewayID: String)
        async -> IOSGatewaySessionMutationRoute?
    {
        guard let route = await self.gateway.currentRoute(ifGatewayID: stableGatewayID) else {
            return nil
        }
        return IOSGatewaySessionMutationRoute(stableGatewayID: stableGatewayID) { method, paramsJSON, timeout in
            try await self.gateway.request(
                method: method,
                paramsJSON: paramsJSON,
                timeoutSeconds: timeout,
                ifCurrentRoute: route)
        }
    }
}

struct IOSGatewayChatTransport: OpenClawChatTransport {
    static let logger = Logger(subsystem: "ai.openclaw", category: "ios.chat.transport")
    static let defaultChatSendTimeoutMs = 30000
    private static let requiredOperatorScopes: Set<String> = ["operator.read", "operator.write"]
    private let gateway: GatewayNodeSession
    private let stableGatewayID: String?
    private let sessionMutationRouter: any IOSGatewaySessionMutationRouting
    private let routeAbsenceReason: @Sendable () async -> OpenClawChatTransportRouteLeaseUnavailableReason

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

    private struct HistoryParams: Codable {
        var sessionKey: String
        var limit: Int?
        var offset: Int
        var maxChars: Int?
    }

    private struct HistoryPageMetadata: Decodable {
        var offset: Int?
        var nextOffset: Int?
        var hasMore: Bool?
        var totalMessages: Int?
    }

    enum HistoryPageValidationError: Error, Equatable, Sendable {
        case offsetMissing
        case offsetInvalid(Int)
        case offsetMismatch(expected: Int, actual: Int)
        case totalMessagesMissing
        case totalMessagesInvalid(Int)
        case offsetOutsideTotal(offset: Int, totalMessages: Int)
        case hasMoreMissing
        case nextOffsetMissing
        case nextOffsetDidNotAdvance(offset: Int, nextOffset: Int)
        case nextOffsetOutsideTotal(nextOffset: Int, totalMessages: Int)
        case unexpectedNextOffset(Int)
    }

    private struct ChatSendParams: Codable {
        var sessionKey: String
        var expectedSessionRoutingContract: String?
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

    init(
        gateway: GatewayNodeSession,
        stableGatewayID: String? = nil,
        sessionMutationRouter: (any IOSGatewaySessionMutationRouting)? = nil,
        routeAbsenceReason: @escaping @Sendable () async
            -> OpenClawChatTransportRouteLeaseUnavailableReason = { .routeUnavailable })
    {
        self.gateway = gateway
        let normalizedGatewayID = stableGatewayID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stableGatewayID = normalizedGatewayID?.isEmpty == false ? normalizedGatewayID : nil
        self.sessionMutationRouter = sessionMutationRouter ?? LiveIOSGatewaySessionMutationRouter(gateway: gateway)
        self.routeAbsenceReason = routeAbsenceReason
    }

    func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult {
        guard let stableGatewayID else {
            return .unavailable(reason: .gatewayIdentityUnavailable)
        }
        guard let route = await self.gateway.currentRoute() else {
            return .unavailable(reason: await self.routeAbsenceReason())
        }
        guard let currentGatewayID = await self.gateway.currentGatewayID(ifCurrentRoute: route) else {
            return .unavailable(reason: .routeUnavailable)
        }
        guard currentGatewayID == stableGatewayID else {
            return .unavailable(reason: .gatewayMismatch)
        }
        guard let supportsRoutingContract = await self.gateway.supportsServerCapability(
            .chatSendRoutingContract,
            ifCurrentRoute: route)
        else {
            let reason: OpenClawChatTransportRouteLeaseUnavailableReason =
                await self.gateway.isCurrentRoute(route) ? .capabilityUnavailable : .routeUnavailable
            return .unavailable(reason: reason)
        }
        guard supportsRoutingContract else {
            return .unavailable(reason: .capabilityUnavailable)
        }
        guard let serverCapabilities = await self.gateway.serverCapabilities(ifCurrentRoute: route) else {
            let reason: OpenClawChatTransportRouteLeaseUnavailableReason =
                await self.gateway.isCurrentRoute(route) ? .capabilityUnavailable : .routeUnavailable
            return .unavailable(reason: reason)
        }
        guard let operatorScopes = await self.gateway.operatorScopes(ifCurrentRoute: route) else {
            let reason: OpenClawChatTransportRouteLeaseUnavailableReason =
                await self.gateway.isCurrentRoute(route) ? .operatorScopesUnavailable : .routeUnavailable
            return .unavailable(reason: reason)
        }
        guard Self.requiredOperatorScopes.isSubset(of: operatorScopes) else {
            return .unavailable(reason: .operatorScopesUnavailable)
        }

        let routingContract: String
        do {
            routingContract = try await self.sessionRoutingContract(ifCurrentRoute: route)
        } catch {
            guard await self.gateway.isCurrentRoute(route) else {
                return .unavailable(reason: .routeUnavailable)
            }
            return .unavailable(reason: .routingContractUnavailable)
        }
        guard await self.gateway.currentGatewayID(ifCurrentRoute: route) == stableGatewayID,
              await self.gateway.supportsServerCapability(
                  .chatSendRoutingContract,
                  ifCurrentRoute: route) == true
        else { return .unavailable(reason: .routeUnavailable) }

        let transport = self
        return .available(OpenClawChatTransportRouteLease(
            stableGatewayID: stableGatewayID,
            sessionRoutingContract: routingContract,
            capabilities: serverCapabilities.sorted(),
            operatorScopes: operatorScopes.sorted(),
            diagnosticSocketGeneration: route.diagnosticSocketGeneration,
            diagnosticRouteGeneration: route.diagnosticRouteGeneration,
            dispatchMessage: { sessionKey, message, thinking, idempotencyKey, attachments in
                await transport.dispatchOutboxMessage(
                    sessionKey: sessionKey,
                    message: message,
                    thinking: thinking,
                    idempotencyKey: idempotencyKey,
                    attachments: attachments,
                    routingContract: routingContract,
                    route: route)
            },
            requestHistoryPage: { sessionKey, limit, offset, maxChars in
                try await transport.requestHistoryPage(
                    sessionKey: sessionKey,
                    limit: limit,
                    offset: offset,
                    maxChars: maxChars,
                    ifCurrentRoute: route)
            }))
    }

    private func sessionRoutingContract(ifCurrentRoute route: GatewayNodeSessionRoute) async throws -> String {
        let data = try await self.gateway.request(
            method: "agents.list",
            paramsJSON: "{}",
            timeoutSeconds: 15,
            ifCurrentRoute: route)
        return try Self.decodeSessionRoutingContract(data)
    }

    static func decodeSessionRoutingContract(_ data: Data) throws -> String {
        let result = try JSONDecoder().decode(AgentsListResult.self, from: data)
        guard let contract = OpenClawChatSessionRoutingContract.make(
            scope: result.scope.value as? String,
            mainKey: result.mainkey,
            defaultAgentID: result.defaultid)
        else {
            throw NSError(
                domain: "OpenClawChatTransport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "gateway routing contract unavailable"])
        }
        return contract
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
        expectedSessionRoutingContract: String? = nil,
        attachments: [OpenClawChatAttachmentPayload]) throws -> String
    {
        let params = ChatSendParams(
            sessionKey: sessionKey,
            expectedSessionRoutingContract: expectedSessionRoutingContract,
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

    static func makeHistoryParamsJSON(
        sessionKey: String,
        limit: Int? = nil,
        offset: Int = 0,
        maxChars: Int? = nil) throws -> String
    {
        // Upstream stable protocol authority dc575d148a7cb69d0650d271943279a4cd60a7de
        // introduced the optional, nonnegative integer offset. The deployed gateway
        // validates it on every history call, so native bootstrap requests send zero.
        try self.encodeParams(HistoryParams(
            sessionKey: sessionKey,
            limit: limit,
            offset: max(0, offset),
            maxChars: maxChars))
    }

    static func makeBoundedHistoryPageParamsJSON(
        sessionKey: String,
        limit: Int,
        offset: Int,
        maxChars: Int) throws -> String
    {
        try self.makeHistoryParamsJSON(
            sessionKey: sessionKey,
            limit: min(1000, max(1, limit)),
            offset: max(0, offset),
            maxChars: min(500_000, max(1, maxChars)))
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
        guard let stableGatewayID = self.stableGatewayID,
              let route = await self.sessionMutationRouter.currentSessionMutationRoute(
                ifGatewayID: stableGatewayID),
              route.stableGatewayID == stableGatewayID
        else {
            throw CancellationError()
        }
        let res = try await route.request(
            method: "sessions.create",
            paramsJSON: json,
            timeoutSeconds: 15)
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
        guard let stableGatewayID = self.stableGatewayID,
              let route = await self.sessionMutationRouter.currentSessionMutationRoute(
                ifGatewayID: stableGatewayID),
              route.stableGatewayID == stableGatewayID
        else {
            throw CancellationError()
        }
        _ = try await route.request(
            method: "sessions.reset",
            paramsJSON: json,
            timeoutSeconds: 10)
    }

    func compactSession(sessionKey: String) async throws {
        let json = try Self.makeSessionKeyParamsJSON(sessionKey)
        guard let stableGatewayID = self.stableGatewayID,
              let route = await self.sessionMutationRouter.currentSessionMutationRoute(
                ifGatewayID: stableGatewayID),
              route.stableGatewayID == stableGatewayID
        else {
            throw CancellationError()
        }
        _ = try await route.request(
            method: "sessions.compact",
            paramsJSON: json,
            timeoutSeconds: 10)
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        try await self.requestHistory(sessionKey: sessionKey, ifCurrentRoute: nil)
    }

    private func requestHistory(
        sessionKey: String,
        ifCurrentRoute route: GatewayNodeSessionRoute?) async throws -> OpenClawChatHistoryPayload
    {
        let json = try Self.makeHistoryParamsJSON(sessionKey: sessionKey, offset: 0)
        let res = try await self.requestHistoryData(json: json, ifCurrentRoute: route)
        return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: res)
    }

    private func requestHistoryPage(
        sessionKey: String,
        limit: Int,
        offset: Int,
        maxChars: Int,
        ifCurrentRoute route: GatewayNodeSessionRoute) async throws -> OpenClawChatHistoryPage
    {
        let boundedOffset = max(0, offset)
        let json = try Self.makeBoundedHistoryPageParamsJSON(
            sessionKey: sessionKey,
            limit: limit,
            offset: boundedOffset,
            maxChars: maxChars)
        let data = try await self.requestHistoryData(json: json, ifCurrentRoute: route)
        return try Self.decodeHistoryPage(data, requestedOffset: boundedOffset)
    }

    static func decodeHistoryPage(_ data: Data, requestedOffset: Int) throws -> OpenClawChatHistoryPage {
        let payload = try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: data)
        let metadata = try JSONDecoder().decode(HistoryPageMetadata.self, from: data)
        let metadataAllAbsent = metadata.offset == nil
            && metadata.nextOffset == nil
            && metadata.hasMore == nil
            && metadata.totalMessages == nil
        if metadataAllAbsent,
           requestedOffset == 0,
           payload.sessionId == nil,
           payload.messages?.isEmpty != false
        {
            return OpenClawChatHistoryPage(
                payload: payload,
                offset: 0,
                nextOffset: nil,
                hasMore: false,
                totalMessages: 0)
        }
        guard let offset = metadata.offset else {
            throw HistoryPageValidationError.offsetMissing
        }
        guard offset >= 0 else {
            throw HistoryPageValidationError.offsetInvalid(offset)
        }
        guard offset == requestedOffset else {
            throw HistoryPageValidationError.offsetMismatch(expected: requestedOffset, actual: offset)
        }
        guard let totalMessages = metadata.totalMessages else {
            throw HistoryPageValidationError.totalMessagesMissing
        }
        guard totalMessages >= 0 else {
            throw HistoryPageValidationError.totalMessagesInvalid(totalMessages)
        }
        guard offset <= totalMessages else {
            throw HistoryPageValidationError.offsetOutsideTotal(
                offset: offset,
                totalMessages: totalMessages)
        }
        guard let hasMore = metadata.hasMore else {
            throw HistoryPageValidationError.hasMoreMissing
        }

        if hasMore {
            guard let nextOffset = metadata.nextOffset else {
                throw HistoryPageValidationError.nextOffsetMissing
            }
            guard nextOffset > offset else {
                throw HistoryPageValidationError.nextOffsetDidNotAdvance(
                    offset: offset,
                    nextOffset: nextOffset)
            }
            guard nextOffset < totalMessages else {
                throw HistoryPageValidationError.nextOffsetOutsideTotal(
                    nextOffset: nextOffset,
                    totalMessages: totalMessages)
            }
        } else if let nextOffset = metadata.nextOffset {
            throw HistoryPageValidationError.unexpectedNextOffset(nextOffset)
        }

        return OpenClawChatHistoryPage(
            payload: payload,
            offset: offset,
            nextOffset: metadata.nextOffset,
            hasMore: hasMore,
            totalMessages: totalMessages)
    }

    private func requestHistoryData(
        json: String,
        ifCurrentRoute route: GatewayNodeSessionRoute?) async throws -> Data
    {
        if let route {
            return try await self.gateway.request(
                method: "chat.history",
                paramsJSON: json,
                timeoutSeconds: 15,
                ifCurrentRoute: route)
        }
        return try await self.gateway.request(method: "chat.history", paramsJSON: json, timeoutSeconds: 15)
    }

    private func dispatchOutboxMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload],
        routingContract: String,
        route: GatewayNodeSessionRoute) async -> OpenClawChatDispatchOutcome
    {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let json: String
        do {
            json = try Self.makeChatSendParamsJSON(
                sessionKey: sessionKey,
                message: message,
                thinking: thinking,
                idempotencyKey: idempotencyKey,
                expectedSessionRoutingContract: routingContract,
                attachments: attachments)
        } catch {
            Self.recordDurableSendDiagnostic(
                state: "chat_send_pre_dispatch_rejected",
                stableGatewayID: self.stableGatewayID,
                routingContract: routingContract,
                route: route,
                sessionKey: sessionKey,
                rawCommandID: idempotencyKey,
                outcome: .notDispatched,
                resultClass: "encoding_failed",
                durationMilliseconds: 0)
            return .notDispatched
        }

        Self.recordDurableSendDiagnostic(
            state: "chat_send_dispatch_invoked",
            stableGatewayID: self.stableGatewayID,
            routingContract: routingContract,
            route: route,
            sessionKey: sessionKey,
            rawCommandID: idempotencyKey,
            resultClass: "requested",
            durationMilliseconds: 0)
        let result = await self.gateway.requestTrackingDispatch(
            method: "chat.send",
            paramsJSON: json,
            timeoutSeconds: 35,
            ifCurrentRoute: route)
        let outcome = Self.mapDispatchResult(result, rawCommandID: idempotencyKey)
        let elapsedMilliseconds = max(
            0,
            Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))
        Self.recordDispatchOutcome(
            outcome,
            stableGatewayID: self.stableGatewayID,
            routingContract: routingContract,
            route: route,
            sessionKey: sessionKey,
            rawCommandID: idempotencyKey,
            durationMilliseconds: elapsedMilliseconds)
        return outcome
    }

    static func mapDispatchResult(
        _ result: GatewayRequestDispatchResult,
        rawCommandID: String) -> OpenClawChatDispatchOutcome
    {
        switch result {
        case .notDispatched:
            return .notDispatched
        case let .ambiguous(code):
            return .ambiguous(code: code)
        case let .rejected(code, reason):
            let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedCode == "INVALID_REQUEST",
               normalizedReason == OpenClawChatSessionRoutingContract.changedErrorReason
            {
                return .blockedRouteChanged
            }
            return .dispatchRejected(code: normalizedCode, reason: normalizedReason)
        case let .response(data):
            guard let response = try? JSONDecoder().decode(OpenClawChatSendResponse.self, from: data) else {
                return .ambiguous(code: "invalid-ack")
            }
            guard response.runId == rawCommandID else {
                return .ambiguous(code: "ack-run-id-mismatch")
            }
            return .accepted(runID: response.runId, status: response.status)
        }
    }

    private static func recordDispatchOutcome(
        _ outcome: OpenClawChatDispatchOutcome,
        stableGatewayID: String?,
        routingContract: String,
        route: GatewayNodeSessionRoute,
        sessionKey: String,
        rawCommandID: String,
        durationMilliseconds: Int)
    {
        let state: String = switch outcome {
        case .notDispatched: "not_dispatched"
        case .dispatchRejected: "dispatch_rejected"
        case .accepted: "accepted"
        case .ambiguous: "ambiguous"
        case .blockedRouteChanged: "blocked_route_changed"
        }
        let eventState: String = switch outcome {
        case .accepted: "chat_send_acknowledged"
        case .notDispatched: "chat_send_not_dispatched"
        case .dispatchRejected: "chat_send_rejected"
        case .ambiguous: "chat_send_ambiguous"
        case .blockedRouteChanged: "chat_send_route_blocked"
        }
        let diagnosticOutcome: OpenClawDiagnosticOutboxOutcome = switch outcome {
        case .notDispatched: .notDispatched
        case .dispatchRejected: .dispatchRejected
        case .accepted: .accepted
        case .ambiguous: .ambiguous
        case .blockedRouteChanged: .blockedRouteChanged
        }
        Self.recordDurableSendDiagnostic(
            state: eventState,
            stableGatewayID: stableGatewayID,
            routingContract: routingContract,
            route: route,
            sessionKey: sessionKey,
            rawCommandID: rawCommandID,
            outcome: diagnosticOutcome,
            resultClass: state,
            durationMilliseconds: durationMilliseconds,
            ackRunID: {
                if case let .accepted(runID, _) = outcome { return runID }
                return nil
            }())
    }

    private static func recordDurableSendDiagnostic(
        state: String,
        stableGatewayID: String?,
        routingContract: String,
        route: GatewayNodeSessionRoute,
        sessionKey: String,
        rawCommandID: String,
        outcome: OpenClawDiagnosticOutboxOutcome? = nil,
        resultClass: String,
        durationMilliseconds: Int,
        ackRunID: String? = nil)
    {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .chat,
            state: state,
            connectionRole: .operator,
            socketGeneration: route.diagnosticSocketGeneration,
            routeGeneration: route.diagnosticRouteGeneration,
            sessionIdentifier: sessionKey,
            runIdentifier: ackRunID,
            diagnosticAttemptID: rawCommandID,
            resultClass: resultClass,
            outboxOutcome: outcome,
            outboxCommandIdentifier: rawCommandID,
            deliveryTarget: .operatorChat,
            deliveryGatewayIdentifier: stableGatewayID,
            routingContractIdentifier: routingContract,
            ackRunIdentifier: ackRunID,
            durationMilliseconds: durationMilliseconds))
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
