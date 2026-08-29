import Foundation

public enum OpenClawChatTransportEvent: Sendable {
    case health(ok: Bool)
    case tick
    case chat(OpenClawChatEventPayload)
    case sessionMessage(OpenClawSessionMessageEventPayload)
    case agent(OpenClawAgentEventPayload)
    case seqGap
}

public enum OpenClawChatDispatchOutcome: Sendable, Equatable {
    case notDispatched
    case dispatchRejected(code: String, reason: String?)
    case accepted(runID: String, status: String)
    case ambiguous(code: String?)
    case blockedRouteChanged
}

public enum OpenClawChatTransportRouteLeaseUnavailableReason: String, Sendable, Equatable {
    case unsupportedTransport = "unsupported_transport"
    case gatewayIdentityUnavailable = "gateway_identity_unavailable"
    case gatewayMismatch = "gateway_mismatch"
    case routeUnavailable = "route_unavailable"
    case operatorRoleMissing = "operator_role_missing"
    case operatorSessionUnavailable = "operator_session_unavailable"
    case capabilityUnavailable = "capability_unavailable"
    case operatorScopesUnavailable = "operator_scopes_unavailable"
    case routingContractUnavailable = "routing_contract_unavailable"
}

/// One bounded canonical-history page returned by the deployed gateway.
/// Missing an identity across a bounded scan is inconclusive; only an exact positive match
/// confirms dispatch.
public struct OpenClawChatHistoryPage: Sendable {
    public let payload: OpenClawChatHistoryPayload
    public let offset: Int
    public let nextOffset: Int?
    public let hasMore: Bool
    public let totalMessages: Int

    public init(
        payload: OpenClawChatHistoryPayload,
        offset: Int,
        nextOffset: Int?,
        hasMore: Bool,
        totalMessages: Int)
    {
        self.payload = payload
        self.offset = offset
        self.nextOffset = nextOffset
        self.hasMore = hasMore
        self.totalMessages = totalMessages
    }
}

/// Immutable delivery context for one durable outbox reconciliation cycle.
/// Both dispatch and history stay on the physical route that admitted this lease.
public struct OpenClawChatTransportRouteLease: Sendable {
    public typealias DispatchMessage = @Sendable (
        _ sessionKey: String,
        _ message: String,
        _ thinking: String,
        _ idempotencyKey: String,
        _ attachments: [OpenClawChatAttachmentPayload]) async -> OpenClawChatDispatchOutcome
    public typealias RequestHistoryPage = @Sendable (
        _ sessionKey: String,
        _ limit: Int,
        _ offset: Int,
        _ maxChars: Int) async throws -> OpenClawChatHistoryPage

    public let stableGatewayID: String
    public let sessionRoutingContract: String
    public let capabilities: [String]
    public let operatorScopes: [String]
    private let dispatchMessageImpl: DispatchMessage
    private let requestHistoryPageImpl: RequestHistoryPage

    public init(
        stableGatewayID: String,
        sessionRoutingContract: String,
        capabilities: [String],
        operatorScopes: [String],
        dispatchMessage: @escaping DispatchMessage,
        requestHistoryPage: @escaping RequestHistoryPage)
    {
        self.stableGatewayID = stableGatewayID
        self.sessionRoutingContract = sessionRoutingContract
        self.capabilities = capabilities
        self.operatorScopes = operatorScopes
        self.dispatchMessageImpl = dispatchMessage
        self.requestHistoryPageImpl = requestHistoryPage
    }

    public func dispatchMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async -> OpenClawChatDispatchOutcome
    {
        await self.dispatchMessageImpl(sessionKey, message, thinking, idempotencyKey, attachments)
    }

    public func requestHistoryPage(
        sessionKey: String,
        limit: Int = 200,
        offset: Int,
        maxChars: Int = 500_000) async throws -> OpenClawChatHistoryPage
    {
        try await self.requestHistoryPageImpl(sessionKey, limit, offset, maxChars)
    }
}

public enum OpenClawChatTransportRouteLeaseResult: Sendable {
    case available(OpenClawChatTransportRouteLease)
    case unavailable(reason: OpenClawChatTransportRouteLeaseUnavailableReason)
}

public enum OpenClawChatSessionRoutingContract {
    public static let changedErrorReason = "session-routing-changed"

    public static func make(scope: String?, mainKey: String?, defaultAgentID: String?) -> String? {
        guard let scope = self.normalize(scope),
              let mainKey = self.normalize(mainKey),
              let defaultAgentID = self.normalize(defaultAgentID)
        else { return nil }
        return "\(scope)|\(mainKey)|\(defaultAgentID)"
    }

    private static func normalize(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}

public protocol OpenClawChatTransport: Sendable {
    func createSession(
        key: String,
        label: String?,
        parentSessionKey: String?) async throws -> OpenClawChatCreateSessionResponse

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload
    func listModels() async throws -> [OpenClawChatModelChoice]
    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse

    func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult

    func abortRun(sessionKey: String, runId: String) async throws
    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse
    func setSessionModel(sessionKey: String, model: String?) async throws
    func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws

    func requestHealth(timeoutMs: Int) async throws -> Bool
    func waitForRunCompletion(runId: String, timeoutMs: Int) async -> Bool
    func events() -> AsyncStream<OpenClawChatTransportEvent>

    func setActiveSessionKey(_ sessionKey: String) async throws
    func resetSession(sessionKey: String) async throws
    func compactSession(sessionKey: String) async throws
}

extension OpenClawChatTransport {
    public func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult {
        .unavailable(reason: .unsupportedTransport)
    }

    public func createSession(
        key _: String,
        label _: String?,
        parentSessionKey _: String?) async throws -> OpenClawChatCreateSessionResponse
    {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.create not supported by this transport"])
    }

    public func setActiveSessionKey(_: String) async throws {}

    public func waitForRunCompletion(runId _: String, timeoutMs _: Int) async -> Bool {
        false
    }

    public func resetSession(sessionKey _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.reset not supported by this transport"])
    }

    public func compactSession(sessionKey _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.compact not supported by this transport"])
    }

    public func abortRun(sessionKey _: String, runId _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "chat.abort not supported by this transport"])
    }

    public func listSessions(limit _: Int?) async throws -> OpenClawChatSessionsListResponse {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.list not supported by this transport"])
    }

    public func listModels() async throws -> [OpenClawChatModelChoice] {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "models.list not supported by this transport"])
    }

    public func setSessionModel(sessionKey _: String, model _: String?) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.patch(model) not supported by this transport"])
    }

    public func setSessionThinking(sessionKey _: String, thinkingLevel _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.patch(thinkingLevel) not supported by this transport"])
    }
}
