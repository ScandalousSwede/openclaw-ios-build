import Foundation
import OpenClawProtocol
import OSLog

public protocol WebSocketTasking: AnyObject {
    var state: URLSessionTask.State { get }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

extension URLSessionWebSocketTask: WebSocketTasking {}

private final class WebSocketPingContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ resume: () -> Void) {
        self.lock.lock()
        if self.didResume {
            self.lock.unlock()
            return
        }
        self.didResume = true
        self.lock.unlock()
        resume()
    }
}

public struct WebSocketTaskBox: @unchecked Sendable {
    public let task: any WebSocketTasking
    public init(task: any WebSocketTasking) {
        self.task = task
    }

    public var state: URLSessionTask.State {
        self.task.state
    }

    public func resume() {
        self.task.resume()
    }

    public func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.task.cancel(with: closeCode, reason: reason)
    }

    public func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await self.task.send(message)
    }

    public func receive() async throws -> URLSessionWebSocketTask.Message {
        try await self.task.receive()
    }

    public func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    {
        self.task.receive(completionHandler: completionHandler)
    }

    public func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = WebSocketPingContinuationGate()
            self.task.sendPing { error in
                // URLSession can race ping callbacks with cancellation; only the first
                // pong result owns this checked continuation or Swift traps the app.
                gate.resumeOnce {
                    ThrowingContinuationSupport.resumeVoid(continuation, error: error)
                }
            }
        }
    }
}

public protocol WebSocketSessioning: AnyObject {
    func makeWebSocketTask(url: URL) -> WebSocketTaskBox
}

extension URLSession: WebSocketSessioning {
    public func makeWebSocketTask(url: URL) -> WebSocketTaskBox {
        let task = self.webSocketTask(with: url)
        // Avoid "Message too long" receive errors for large snapshots / history payloads.
        task.maximumMessageSize = 16 * 1024 * 1024 // 16 MB
        return WebSocketTaskBox(task: task)
    }
}

public struct WebSocketSessionBox: @unchecked Sendable {
    public let session: any WebSocketSessioning

    public init(session: any WebSocketSessioning) {
        self.session = session
    }
}

public struct GatewayConnectOptions: Sendable {
    public var role: String
    public var scopes: [String]
    public var scopesAreExplicit: Bool
    public var caps: [String]
    public var commands: [String]
    public var permissions: [String: Bool]
    public var clientId: String
    public var clientMode: String
    public var clientDisplayName: String?
    /// Stable owner identity for route-bound client state. Nil keeps legacy
    /// unscoped connections from being mistaken for a durable outbox route.
    public var stableGatewayID: String?
    /// When false, the connection omits the signed device identity payload and cannot use
    /// device-scoped auth (role/scope upgrades will require pairing). Keep this true for
    /// role/scoped sessions such as operator UI clients.
    public var includeDeviceIdentity: Bool

    public init(
        role: String,
        scopes: [String],
        scopesAreExplicit: Bool = false,
        caps: [String],
        commands: [String],
        permissions: [String: Bool],
        clientId: String,
        clientMode: String,
        clientDisplayName: String?,
        stableGatewayID: String? = nil,
        includeDeviceIdentity: Bool = true)
    {
        self.role = role
        self.scopes = scopes
        self.scopesAreExplicit = scopesAreExplicit
        self.caps = caps
        self.commands = commands
        self.permissions = permissions
        self.clientId = clientId
        self.clientMode = clientMode
        self.clientDisplayName = clientDisplayName
        self.stableGatewayID = stableGatewayID
        self.includeDeviceIdentity = includeDeviceIdentity
    }
}

public enum GatewayAuthSource: String, Sendable, Equatable {
    case deviceToken = "device-token"
    case sharedToken = "shared-token"
    case bootstrapToken = "bootstrap-token"
    case password
    case none

    /// Resolves only caller-supplied credentials using the same precedence as
    /// the wire-level connect payload: shared token, password, then one-shot
    /// bootstrap token. Stored role credentials are selected separately.
    public static func explicitCredentialSource(
        token: String?,
        bootstrapToken: String?,
        password: String?) -> GatewayAuthSource
    {
        if token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .sharedToken
        }
        if password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .password
        }
        if bootstrapToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .bootstrapToken
        }
        return .none
    }
}

/// Avoid ambiguity with the app's own AnyCodable type.
private typealias ProtoAnyCodable = OpenClawProtocol.AnyCodable

private func gatewayErrorDetails(_ error: ErrorShape?) -> [String: ProtoAnyCodable] {
    var details: [String: ProtoAnyCodable] = [:]
    if let nested = error?.details?.value as? [String: ProtoAnyCodable] {
        details.merge(nested) { _, nestedValue in nestedValue }
    }
    if let error {
        if details["code"] == nil {
            details["code"] = ProtoAnyCodable(error.code)
        } else {
            details["errorCode"] = ProtoAnyCodable(error.code)
        }
        details["message"] = ProtoAnyCodable(error.message)
        if let retryable = error.retryable {
            details["retryable"] = ProtoAnyCodable(retryable)
        }
        if let retryAfterMs = error.retryafterms {
            details["retryAfterMs"] = ProtoAnyCodable(retryAfterMs)
        }
    }
    return details
}

private enum ConnectChallengeError: Error {
    case timeout
}

public enum GatewayRequestDispatchResult: Sendable, Equatable {
    case response(Data)
    case notDispatched
    case rejected(code: String, reason: String?)
    case ambiguous(code: String?)
}

struct GatewayRPCDiagnosticParameterShape: Equatable, Sendable {
    static let chatHistoryValidatorIdentity = "chat-history-0790d9f593ad"
    static let currentProtocolSchemaVersion = "gateway-protocol-v4"

    let offsetPresent: Bool
    let offsetType: OpenClawDiagnosticRPCOffsetType
    let offsetValue: Int?
    let limitPresent: Bool
    let limitValue: Int?
    let maxCharsPresent: Bool
    let maxCharsValue: Int?
    let encodedPropertyNames: [OpenClawDiagnosticRPCEncodedPropertyName]
    let gatewayValidatorIdentity: String?
    let protocolSchemaVersion: String
    let requestEnvelopeVersion: Int
    let sessionIdentifier: String?

    static func inspect(method: String, params: [String: AnyCodable]?) -> Self {
        let isChatHistory = method == "chat.history"
        let offsetPresent = params?["offset"] != nil
        let offsetType: OpenClawDiagnosticRPCOffsetType
        if let value = params?["offset"]?.value {
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    offsetType = .invalid
                } else {
                    let value = number.doubleValue
                    offsetType = value.isFinite && value.rounded(.towardZero) == value
                        ? .integer
                        : .invalid
                }
            } else if value is Bool {
                offsetType = .invalid
            } else if value is Int {
                offsetType = .integer
            } else if let value = value as? Double,
                      value.isFinite,
                      value.rounded(.towardZero) == value
            {
                offsetType = .integer
            } else {
                offsetType = .invalid
            }
        } else {
            offsetType = .absent
        }
        return Self(
            offsetPresent: offsetPresent,
            offsetType: offsetType,
            offsetValue: isChatHistory ? Self.boundedInteger(params?["offset"]?.value) : nil,
            limitPresent: params?["limit"] != nil,
            limitValue: isChatHistory ? Self.boundedInteger(params?["limit"]?.value) : nil,
            maxCharsPresent: params?["maxChars"] != nil,
            maxCharsValue: isChatHistory ? Self.boundedInteger(params?["maxChars"]?.value) : nil,
            encodedPropertyNames: isChatHistory
                ? (params?.keys.compactMap(OpenClawDiagnosticRPCEncodedPropertyName.init(rawValue:))
                    .sorted { $0.rawValue < $1.rawValue } ?? [])
                : [],
            gatewayValidatorIdentity: isChatHistory ? Self.chatHistoryValidatorIdentity : nil,
            protocolSchemaVersion: Self.currentProtocolSchemaVersion,
            requestEnvelopeVersion: GATEWAY_PROTOCOL_VERSION,
            sessionIdentifier: params?["sessionKey"]?.value as? String)
    }

    private static func boundedInteger(_ rawValue: Any?) -> Int? {
        guard let rawValue else { return nil }
        let value: Double
        if let number = rawValue as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            value = number.doubleValue
        } else if rawValue is Bool {
            return nil
        } else if let integer = rawValue as? Int {
            value = Double(integer)
        } else if let double = rawValue as? Double {
            value = double
        } else {
            return nil
        }
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              (-1_000_000...1_000_000).contains(value)
        else { return nil }
        return Int(value)
    }

    static func classifyGatewayValidation(
        errorCode: String?,
        message: String?)
        -> (
            path: OpenClawDiagnosticGatewayValidationPath?,
            messageClass: OpenClawDiagnosticGatewayErrorMessageClass?)
    {
        guard errorCode == "INVALID_REQUEST", let message else { return (nil, nil) }
        let normalized = message.lowercased()
        let path: OpenClawDiagnosticGatewayValidationPath = if normalized.contains("/sessionkey") {
            .sessionKey
        } else if normalized.contains("/agentid") {
            .agentID
        } else if normalized.contains("/maxchars") {
            .maxChars
        } else if normalized.contains("/offset") {
            .offset
        } else if normalized.contains("/limit") {
            .limit
        } else if normalized.contains("additional propert") || normalized.contains("unexpected propert") {
            .additionalProperty
        } else if normalized.contains("unknown agent") || normalized.contains("does not match session key") {
            .selectedAgent
        } else {
            .unknown
        }
        let messageClass: OpenClawDiagnosticGatewayErrorMessageClass =
            if normalized.contains("must be integer") || normalized.contains("expected integer") {
                .integerRequired
            } else if normalized.contains("must be string") || normalized.contains("non-empty string") {
                .nonEmptyStringRequired
            } else if normalized.contains("required") {
                .requiredPropertyMissing
            } else if normalized.contains("minimum") || normalized.contains("greater than or equal") {
                .minimumViolation
            } else if normalized.contains("maximum") || normalized.contains("less than or equal") {
                .maximumViolation
            } else if normalized.contains("additional propert") || normalized.contains("unexpected propert") {
                .unexpectedProperty
            } else if normalized.contains("unknown agent") || normalized.contains("does not match session key") {
                .selectedAgentInvalid
            } else {
                .invalidRequestOther
            }
        return (path, messageClass)
    }
}

private final class GatewayRequestDispatchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var dispatchStarted = false

    func markDispatchStarted() {
        self.lock.lock()
        self.dispatchStarted = true
        self.lock.unlock()
    }

    func didStartDispatch() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.dispatchStarted
    }
}

private let defaultOperatorConnectScopes: [String] = [
    "operator.admin",
    "operator.read",
    "operator.write",
    "operator.approvals",
    "operator.pairing",
]

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}

private struct SelectedConnectAuth {
    let authToken: String?
    let authBootstrapToken: String?
    let authDeviceToken: String?
    let authPassword: String?
    let signatureToken: String?
    let storedToken: String?
    let storedScopes: [String]?
    let authSource: GatewayAuthSource
    let suppressedDeviceTokenRetry: Bool
}

private enum ParsedBootstrapHandoffCredentials {
    case credentials([GatewayBootstrapHandoffCredential])
    case malformed
}

private enum GatewayConnectErrorCodes {
    static let authTokenMismatch = GatewayConnectAuthDetailCode.authTokenMismatch.rawValue
    static let authDeviceTokenMismatch = GatewayConnectAuthDetailCode.authDeviceTokenMismatch.rawValue
    static let authTokenMissing = GatewayConnectAuthDetailCode.authTokenMissing.rawValue
    static let authTokenNotConfigured = GatewayConnectAuthDetailCode.authTokenNotConfigured.rawValue
    static let authPasswordMissing = GatewayConnectAuthDetailCode.authPasswordMissing.rawValue
    static let authPasswordMismatch = GatewayConnectAuthDetailCode.authPasswordMismatch.rawValue
    static let authPasswordNotConfigured = GatewayConnectAuthDetailCode.authPasswordNotConfigured.rawValue
    static let authRateLimited = GatewayConnectAuthDetailCode.authRateLimited.rawValue
    static let pairingRequired = GatewayConnectAuthDetailCode.pairingRequired.rawValue
    static let controlUiDeviceIdentityRequired = GatewayConnectAuthDetailCode.controlUiDeviceIdentityRequired.rawValue
    static let deviceIdentityRequired = GatewayConnectAuthDetailCode.deviceIdentityRequired.rawValue
}

public actor GatewayChannelActor {
    private let logger = Logger(subsystem: "ai.openclaw", category: "gateway")
    private let diagnosticConnectionRole: OpenClawDiagnosticConnectionRole
    private var task: WebSocketTaskBox?
    private struct PendingRequest {
        let connectionGeneration: UInt64
        let routeGeneration: UInt64?
        let rpcMethod: String
        let parameterShape: GatewayRPCDiagnosticParameterShape
        let admittedAt: Date
        let admittedUptime: TimeInterval
        let continuation: CheckedContinuation<GatewayFrame, Error>
    }

    private var pending: [String: PendingRequest] = [:]
    private var connected = false
    private var isConnecting = false
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    /// Physical socket epoch. Callbacks and operations retain the generation that admitted
    /// them so a late socket cannot mutate or dispatch through its replacement.
    private var connectionGeneration: UInt64 = 0
    private var disconnectedConnectionGeneration: UInt64?
    private var url: URL
    private var token: String?
    private var bootstrapToken: String?
    private var password: String?
    private let session: WebSocketSessioning
    private var backoffMs: Double = 500
    private var shouldReconnect = true
    private var lastSeq: Int?
    private var lastTick: Date?
    private var tickIntervalMs: Double = 30000
    private var lastAuthSource: GatewayAuthSource = .none
    private var bootstrapHandoffReceipt: GatewayBootstrapHandoffConnectionReceipt?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    // Remote gateways (tailscale/wan) can take longer to deliver connect.challenge.
    // Connect now requires this nonce before we send device-auth.
    private let connectTimeoutSeconds: Double = 30
    private let connectChallengeTimeoutSeconds: Double = 6.0
    // Some networks will silently drop idle TCP/TLS flows around ~30s. The gateway tick is server->client,
    // but NATs/proxies often require outbound traffic to keep the connection alive.
    private let keepaliveIntervalSeconds: Double = 15.0
    private var watchdogTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var pendingDeviceTokenRetry = false
    private var deviceTokenRetryBudgetUsed = false
    private var reconnectPausedForAuthFailure = false
    private let defaultRequestTimeoutMs: Double = 15000
    private let pushHandler: (@Sendable (GatewayPush, UInt64) async -> Void)?
    private let snapshotAdmissionHandler:
        (@Sendable (HelloOk, UInt64) async -> Void)?
    private let bootstrapHandoffHandler:
        (@Sendable (GatewayBootstrapHandoffConnectionReceipt, UInt64) async -> Void)?
    private let connectOptions: GatewayConnectOptions?
    private let disconnectHandler: (@Sendable (String, UInt64) async -> Void)?

    public init(
        url: URL,
        token: String?,
        bootstrapToken: String? = nil,
        password: String? = nil,
        session: WebSocketSessionBox? = nil,
        pushHandler: (@Sendable (GatewayPush) async -> Void)? = nil,
        connectOptions: GatewayConnectOptions? = nil,
        diagnosticConnectionRole: OpenClawDiagnosticConnectionRole = .unknown,
        disconnectHandler: (@Sendable (String) async -> Void)? = nil)
    {
        self.url = url
        self.token = token
        self.bootstrapToken = bootstrapToken
        self.password = password
        self.session = session?.session ?? URLSession(configuration: .default)
        self.diagnosticConnectionRole = diagnosticConnectionRole
        if let pushHandler {
            self.pushHandler = { push, _ in await pushHandler(push) }
        } else {
            self.pushHandler = nil
        }
        self.snapshotAdmissionHandler = nil
        self.bootstrapHandoffHandler = nil
        self.connectOptions = connectOptions
        if let disconnectHandler {
            self.disconnectHandler = { reason, _ in await disconnectHandler(reason) }
        } else {
            self.disconnectHandler = nil
        }
        Task { [weak self] in
            await self?.startWatchdog()
        }
    }

    /// Generation-aware transport callbacks for route owners that must fence stale sockets.
    public init(
        url: URL,
        token: String?,
        bootstrapToken: String? = nil,
        password: String? = nil,
        session: WebSocketSessionBox? = nil,
        generationAwarePushHandler: (@Sendable (GatewayPush, UInt64) async -> Void)?,
        generationAwareSnapshotAdmissionHandler:
            (@Sendable (HelloOk, UInt64) async -> Void)? = nil,
        generationAwareBootstrapHandoffHandler:
            (@Sendable (GatewayBootstrapHandoffConnectionReceipt, UInt64) async -> Void)? = nil,
        connectOptions: GatewayConnectOptions? = nil,
        diagnosticConnectionRole: OpenClawDiagnosticConnectionRole = .unknown,
        generationAwareDisconnectHandler: (@Sendable (String, UInt64) async -> Void)? = nil)
    {
        self.url = url
        self.token = token
        self.bootstrapToken = bootstrapToken
        self.password = password
        self.session = session?.session ?? URLSession(configuration: .default)
        self.diagnosticConnectionRole = diagnosticConnectionRole
        self.pushHandler = generationAwarePushHandler
        self.snapshotAdmissionHandler = generationAwareSnapshotAdmissionHandler
        self.bootstrapHandoffHandler = generationAwareBootstrapHandoffHandler
        self.connectOptions = connectOptions
        self.disconnectHandler = generationAwareDisconnectHandler
        Task { [weak self] in
            await self?.startWatchdog()
        }
    }

    public func authSource() -> GatewayAuthSource {
        self.lastAuthSource
    }

    func bootstrapHandoffConnectionReceipt(
        ifCurrentConnectionGeneration expectedGeneration: UInt64) -> GatewayBootstrapHandoffConnectionReceipt?
    {
        guard self.isConnected(connectionGeneration: expectedGeneration),
              self.bootstrapHandoffReceipt?.physicalConnectionGeneration == expectedGeneration
        else { return nil }
        return self.bootstrapHandoffReceipt
    }

    public func shutdown() async {
        self.shouldReconnect = false
        if self.connected {
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .socket,
                state: "shutdown",
                connectionRole: self.diagnosticConnectionRole,
                socketGeneration: self.connectionGeneration))
        }
        self.connected = false
        // Retire callback ownership before cancellation can invoke an old receive handler.
        self.connectionGeneration &+= 1
        self.disconnectedConnectionGeneration = self.connectionGeneration

        self.watchdogTask?.cancel()
        self.watchdogTask = nil

        self.tickTask?.cancel()
        self.tickTask = nil

        self.keepaliveTask?.cancel()
        self.keepaliveTask = nil

        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil

        await self.failPending(NSError(
            domain: "Gateway",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "gateway channel shutdown"]),
            connectionGeneration: nil,
            resultClass: "cancelled")

        let waiters = self.connectWaiters
        self.connectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: NSError(
                domain: "Gateway",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "gateway channel shutdown"]))
        }
    }

    private func startWatchdog() {
        self.watchdogTask?.cancel()
        self.watchdogTask = Task { [weak self] in
            guard let self else { return }
            await self.watchdogLoop()
        }
    }

    private func watchdogLoop() async {
        // Keep nudging reconnect in case exponential backoff stalls.
        while self.shouldReconnect {
            guard await self.sleepUnlessCancelled(nanoseconds: 30 * 1_000_000_000) else { return } // 30s cadence
            guard self.shouldReconnect else { return }
            if self.reconnectPausedForAuthFailure { continue }
            if self.connected { continue }
            do {
                try await self.connect()
            } catch {
                if self.shouldPauseReconnectAfterAuthFailure(error) {
                    self.reconnectPausedForAuthFailure = true
                    self.logger.error(
                        "gateway watchdog reconnect paused for non-recoverable auth failure \(error.localizedDescription, privacy: .public)")
                    continue
                }
                let wrapped = self.wrap(error, context: "gateway watchdog reconnect")
                self.logger.error("gateway watchdog reconnect failed \(wrapped.localizedDescription, privacy: .public)")
            }
        }
    }

    public func connect() async throws {
        guard self.shouldReconnect else { throw CancellationError() }
        if self.connected, self.task?.state == .running { return }
        if self.isConnecting {
            try await withCheckedThrowingContinuation { cont in
                self.connectWaiters.append(cont)
            }
            return
        }
        self.isConnecting = true
        defer { self.isConnecting = false }
        if self.connected {
            let staleGeneration = self.connectionGeneration
            let staleError = NSError(
                domain: "Gateway",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "gateway socket stopped before reconnect"])
            await self.transitionToDisconnected(
                reason: staleError.localizedDescription,
                error: staleError,
                connectionGeneration: staleGeneration,
                shouldReconnect: false)
            guard self.shouldReconnect else { throw CancellationError() }
        }
        let attemptID = UUID().uuidString
        let startedAt = ProcessInfo.processInfo.systemUptime
        let connectStartMessage =
            "gateway.trace event=connect_start attempt_id=\(attemptID) "
                + "scheme=\(self.url.scheme ?? "unknown")"
        self.logger.info("\(connectStartMessage, privacy: .public)")

        self.bootstrapHandoffReceipt = nil
        self.connectionGeneration &+= 1
        let connectionGeneration = self.connectionGeneration
        self.disconnectedConnectionGeneration = nil
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .socket,
            state: "connecting",
            connectionRole: self.diagnosticConnectionRole,
            socketGeneration: connectionGeneration))
        self.task?.cancel(with: .goingAway, reason: nil)
        let connectTask = self.session.makeWebSocketTask(url: self.url)
        self.task = connectTask
        connectTask.resume()
        let connectHello: HelloOk
        do {
            connectHello = try await AsyncTimeout.withTimeout(
                seconds: self.connectTimeoutSeconds,
                onTimeout: {
                    NSError(
                        domain: "Gateway",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "connect timed out"])
                },
                operation: {
                    try await self.sendConnect(
                        task: connectTask,
                        connectionGeneration: connectionGeneration)
                })
            try self.requireCurrentSocket(connectTask, connectionGeneration: connectionGeneration)
        } catch {
            guard self.ownsSocket(connectTask, connectionGeneration: connectionGeneration) else {
                throw CancellationError()
            }
            let wrapped: Error = if let authError = error as? GatewayConnectAuthError {
                authError
            } else {
                self.wrap(error, context: "connect to gateway @ \(self.url.absoluteString)")
            }
            self.connected = false
            self.disconnectedConnectionGeneration = connectionGeneration
            connectTask.cancel(with: .goingAway, reason: nil)
            if self.task?.task === connectTask.task {
                self.task = nil
            }
            await self.disconnectHandler?("connect failed: \(wrapped.localizedDescription)", connectionGeneration)
            let waiters = self.connectWaiters
            self.connectWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: wrapped)
            }
            let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            let connectFailedMessage =
                "gateway.trace event=connect_failed attempt_id=\(attemptID) elapsed_ms=\(elapsedMs)"
            self.logger.error("\(connectFailedMessage, privacy: .public)")
            self.logger.error("gateway ws connect failed \(wrapped.localizedDescription, privacy: .public)")
            throw wrapped
        }
        guard self.ownsSocket(connectTask, connectionGeneration: connectionGeneration),
              self.disconnectedConnectionGeneration != connectionGeneration,
              self.shouldReconnect
        else { throw CancellationError() }
        if let handoffReceipt = self.bootstrapHandoffReceipt,
           handoffReceipt.physicalConnectionGeneration == connectionGeneration
        {
            // Persisted, token-free bootstrap issuance must cross the actor
            // boundary before listen() can report an immediate socket failure.
            // The route owner can attach it to the first surviving snapshot.
            await self.bootstrapHandoffHandler?(handoffReceipt, connectionGeneration)
            guard self.ownsSocket(connectTask, connectionGeneration: connectionGeneration),
                  self.disconnectedConnectionGeneration != connectionGeneration,
                  self.shouldReconnect
            else { throw CancellationError() }
        }
        self.connected = true
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .socket,
            state: "connected",
            connectionRole: self.diagnosticConnectionRole,
            socketGeneration: connectionGeneration))
        self.reconnectPausedForAuthFailure = false
        self.backoffMs = 500
        self.lastSeq = nil
        self.listen(task: connectTask, connectionGeneration: connectionGeneration)
        self.startTickWatchdog(connectionGeneration: connectionGeneration)
        self.startKeepalive(connectionGeneration: connectionGeneration)
        // The channel must be admitted and listening before an onConnected callback
        // can issue a route-bound request through the snapshot. Bootstrap evidence
        // was acknowledged independently before listen() began.
        Task { [weak self] in
            guard let self else { return }
            if self.snapshotAdmissionHandler != nil {
                await self.deliverSnapshotAdmissionIfCurrent(
                    connectHello,
                    connectionGeneration: connectionGeneration)
            } else {
                await self.deliverPushIfCurrent(
                    .snapshot(connectHello),
                    connectionGeneration: connectionGeneration)
            }
        }

        let waiters = self.connectWaiters
        self.connectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: ())
        }
        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        let connectSucceededMessage =
            "gateway.trace event=connect_succeeded attempt_id=\(attemptID) "
                + "elapsed_ms=\(elapsedMs) role=\(self.connectOptions?.role ?? "unknown")"
        self.logger.info("\(connectSucceededMessage, privacy: .public)")
    }

    private func startKeepalive(connectionGeneration: UInt64) {
        self.keepaliveTask?.cancel()
        self.keepaliveTask = Task { [weak self] in
            guard let self else { return }
            await self.keepaliveLoop(connectionGeneration: connectionGeneration)
        }
    }

    private func keepaliveLoop(connectionGeneration: UInt64) async {
        while self.shouldReconnect {
            guard await self.sleepUnlessCancelled(
                nanoseconds: UInt64(self.keepaliveIntervalSeconds * 1_000_000_000))
            else { return }
            guard self.shouldReconnect else { return }
            guard self.isConnected(connectionGeneration: connectionGeneration) else { return }
            guard let task = self.task else { continue }
            // Best-effort ping keeps NAT/proxy state alive without generating RPC load.
            do {
                try await task.sendPing()
            } catch {
                // Avoid spamming logs; the reconnect paths will surface meaningful errors.
            }
        }
    }

    private func sendConnect(
        task: WebSocketTaskBox,
        connectionGeneration: UInt64) async throws -> HelloOk
    {
        let platform = InstanceIdentity.platformString
        let primaryLocale = Locale.preferredLanguages.first ?? Locale.current.identifier
        let options = self.connectOptions ?? GatewayConnectOptions(
            role: "operator",
            scopes: defaultOperatorConnectScopes,
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "openclaw-macos",
            clientMode: "ui",
            clientDisplayName: InstanceIdentity.displayName)
        let clientDisplayName = options.clientDisplayName ?? InstanceIdentity.displayName
        let clientId = options.clientId
        let clientMode = options.clientMode
        let role = options.role
        let requestedScopes = options.scopes
        let scopesAreExplicit = options.scopesAreExplicit
        let includeDeviceIdentity = options.includeDeviceIdentity
        let identity = includeDeviceIdentity ? DeviceIdentityStore.loadOrCreate() : nil
        let selectedAuth = self.selectConnectAuth(
            role: role,
            includeDeviceIdentity: includeDeviceIdentity,
            deviceId: identity?.deviceId,
            requestedScopes: requestedScopes)
        let scopes = self.resolveConnectScopes(
            role: role,
            requestedScopes: requestedScopes,
            scopesAreExplicit: scopesAreExplicit,
            selectedAuth: selectedAuth)

        let reqId = UUID().uuidString
        var client: [String: ProtoAnyCodable] = [
            "id": ProtoAnyCodable(clientId),
            "displayName": ProtoAnyCodable(clientDisplayName),
            "version": ProtoAnyCodable(
                Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"),
            "platform": ProtoAnyCodable(platform),
            "mode": ProtoAnyCodable(clientMode),
            "instanceId": ProtoAnyCodable(InstanceIdentity.instanceId),
        ]
        client["deviceFamily"] = ProtoAnyCodable(InstanceIdentity.deviceFamily)
        if let model = InstanceIdentity.modelIdentifier {
            client["modelIdentifier"] = ProtoAnyCodable(model)
        }
        var params: [String: ProtoAnyCodable] = [
            "minProtocol": ProtoAnyCodable(GATEWAY_MIN_PROTOCOL_VERSION),
            "maxProtocol": ProtoAnyCodable(GATEWAY_PROTOCOL_VERSION),
            "client": ProtoAnyCodable(client),
            "caps": ProtoAnyCodable(options.caps),
            "locale": ProtoAnyCodable(primaryLocale),
            "userAgent": ProtoAnyCodable(ProcessInfo.processInfo.operatingSystemVersionString),
            "role": ProtoAnyCodable(role),
            "scopes": ProtoAnyCodable(scopes),
        ]
        if !options.commands.isEmpty {
            params["commands"] = ProtoAnyCodable(options.commands)
        }
        if !options.permissions.isEmpty {
            params["permissions"] = ProtoAnyCodable(options.permissions)
        }
        if self.pendingDeviceTokenRetry,
           selectedAuth.authDeviceToken != nil || selectedAuth.suppressedDeviceTokenRetry
        {
            self.pendingDeviceTokenRetry = false
        }
        self.lastAuthSource = selectedAuth.authSource
        self.logger.info("gateway connect auth=\(selectedAuth.authSource.rawValue, privacy: .public)")
        if let authToken = selectedAuth.authToken {
            var auth: [String: ProtoAnyCodable] = ["token": ProtoAnyCodable(authToken)]
            if let authDeviceToken = selectedAuth.authDeviceToken {
                auth["deviceToken"] = ProtoAnyCodable(authDeviceToken)
            }
            params["auth"] = ProtoAnyCodable(auth)
        } else if let authBootstrapToken = selectedAuth.authBootstrapToken {
            params["auth"] = ProtoAnyCodable(["bootstrapToken": ProtoAnyCodable(authBootstrapToken)])
        } else if let password = selectedAuth.authPassword {
            params["auth"] = ProtoAnyCodable(["password": ProtoAnyCodable(password)])
        }
        let signedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        let connectNonce = try await self.waitForConnectChallenge(
            task: task,
            connectionGeneration: connectionGeneration)
        try self.requireCurrentSocket(task, connectionGeneration: connectionGeneration)
        if includeDeviceIdentity, let identity {
            let payload = GatewayDeviceAuthPayload.buildV3(
                deviceId: identity.deviceId,
                clientId: clientId,
                clientMode: clientMode,
                role: role,
                scopes: scopes,
                signedAtMs: signedAtMs,
                token: selectedAuth.signatureToken,
                nonce: connectNonce,
                platform: platform,
                deviceFamily: InstanceIdentity.deviceFamily)
            if let device = GatewayDeviceAuthPayload.signedDeviceDictionary(
                payload: payload,
                identity: identity,
                signedAtMs: signedAtMs,
                nonce: connectNonce)
            {
                params["device"] = ProtoAnyCodable(device)
            }
        }

        let frame = RequestFrame(
            type: "req",
            id: reqId,
            method: "connect",
            params: ProtoAnyCodable(params))
        let data = try self.encoder.encode(frame)
        var bootstrapRequestWasDispatched = false
        do {
            try await task.send(.data(data))
            bootstrapRequestWasDispatched = selectedAuth.authSource == .bootstrapToken
            try self.requireCurrentSocket(task, connectionGeneration: connectionGeneration)
            let response = try await self.waitForConnectResponse(
                reqId: reqId,
                task: task,
                connectionGeneration: connectionGeneration)
            try self.requireCurrentSocket(task, connectionGeneration: connectionGeneration)
            let hello = try await self.handleConnectResponse(
                response,
                identity: identity,
                role: role,
                connectionGeneration: connectionGeneration)
            try self.requireCurrentSocket(task, connectionGeneration: connectionGeneration)
            self.pendingDeviceTokenRetry = false
            self.deviceTokenRetryBudgetUsed = false
            return hello
        } catch {
            if bootstrapRequestWasDispatched,
               !self.shouldRetainBootstrapTokenAfterConnectError(error)
            {
                // Once a bootstrap request was physically dispatched, a lost or
                // malformed response is ambiguous: replaying the one-shot could mint
                // another role set. Only the gateway's explicit wait-then-retry
                // pairing response authorizes reuse.
                self.bootstrapToken = nil
            }
            let shouldRetryWithDeviceToken = self.shouldRetryWithStoredDeviceToken(
                error: error,
                explicitGatewayToken: self.token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                storedToken: selectedAuth.storedToken,
                attemptedDeviceTokenRetry: selectedAuth.authDeviceToken != nil)
            if shouldRetryWithDeviceToken {
                self.pendingDeviceTokenRetry = true
                self.deviceTokenRetryBudgetUsed = true
                self.backoffMs = min(self.backoffMs, 250)
            } else if selectedAuth.authDeviceToken != nil,
                      let identity,
                      self.shouldClearStoredDeviceTokenAfterRetry(error)
            {
                // Retry failed with an explicit device-token mismatch; clear stale local token.
                DeviceAuthStore.clearToken(deviceId: identity.deviceId, role: role)
            }
            throw error
        }
    }

    private func shouldRetainBootstrapTokenAfterConnectError(_ error: Error) -> Bool {
        guard let authError = error as? GatewayConnectAuthError else { return false }
        return authError.detail == .pairingRequired &&
            authError.recommendedNextStep == .waitThenRetry &&
            authError.retryableOverride == true &&
            authError.pauseReconnectOverride == false
    }

    private func selectConnectAuth(
        role: String,
        includeDeviceIdentity: Bool,
        deviceId: String?,
        requestedScopes: [String]) -> SelectedConnectAuth
    {
        let explicitToken = self.token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let explicitBootstrapToken =
            self.bootstrapToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let explicitPassword = self.password?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let explicitCredentialSource = GatewayAuthSource.explicitCredentialSource(
            token: explicitToken,
            bootstrapToken: explicitBootstrapToken,
            password: explicitPassword)
        let storedEntry =
            (includeDeviceIdentity && deviceId != nil)
            ? DeviceAuthStore.loadToken(deviceId: deviceId!, role: role)
            : nil
        let storedToken = storedEntry?.token
        let storedScopes = storedEntry?.scopes ?? []
        let requestedScopesExceedStoredToken = Self.requestedScopesExceedStoredToken(
            role: role,
            requestedScopes: requestedScopes,
            storedToken: storedToken,
            storedScopes: storedScopes)
        let suppressedDeviceTokenRetry =
            includeDeviceIdentity && self.pendingDeviceTokenRetry &&
            requestedScopesExceedStoredToken && storedToken != nil && explicitToken != nil
        // Scope upgrades must be judged from the requested scopes. A stale
        // device-token retry carries the old grant and is rejected before pairing repair.
        let shouldUseDeviceRetryToken =
            includeDeviceIdentity && self.pendingDeviceTokenRetry &&
            !requestedScopesExceedStoredToken && storedToken != nil && explicitToken != nil &&
            self.isTrustedDeviceRetryEndpoint()
        let authToken: String? = switch explicitCredentialSource {
        case .sharedToken:
            explicitToken
        case .none:
            // A freshly scanned setup code should force its explicit auth path instead of
            // silently reusing an older stored device token.
            includeDeviceIdentity ? storedToken : nil
        case .password, .bootstrapToken, .deviceToken:
            nil
        }
        let authBootstrapToken = explicitCredentialSource == .bootstrapToken
            ? explicitBootstrapToken
            : nil
        let authPassword = explicitCredentialSource == .password ? explicitPassword : nil
        let authDeviceToken = shouldUseDeviceRetryToken ? storedToken : nil
        let authSource: GatewayAuthSource = if authDeviceToken != nil ||
            (explicitCredentialSource == .none && authToken != nil)
        {
            .deviceToken
        } else {
            explicitCredentialSource
        }
        return SelectedConnectAuth(
            authToken: authToken,
            authBootstrapToken: authBootstrapToken,
            authDeviceToken: authDeviceToken,
            authPassword: authPassword,
            signatureToken: authToken ?? authBootstrapToken,
            storedToken: storedToken,
            storedScopes: storedEntry?.scopes,
            authSource: authSource,
            suppressedDeviceTokenRetry: suppressedDeviceTokenRetry)
    }

    nonisolated static func _test_requestedScopesExceedStoredToken(
        role: String,
        requestedScopes: [String],
        storedToken: String?,
        storedScopes: [String]) -> Bool
    {
        self.requestedScopesExceedStoredToken(
            role: role,
            requestedScopes: requestedScopes,
            storedToken: storedToken,
            storedScopes: storedScopes)
    }

    private nonisolated static func requestedScopesExceedStoredToken(
        role: String,
        requestedScopes: [String],
        storedToken: String?,
        storedScopes: [String]) -> Bool
    {
        storedToken != nil && !storedScopes.isEmpty &&
            !self.storedDeviceTokenScopesAllow(
                role: role,
                requestedScopes: requestedScopes,
                storedScopes: storedScopes)
    }

    private nonisolated static func storedDeviceTokenScopesAllow(
        role: String,
        requestedScopes: [String],
        storedScopes: [String]) -> Bool
    {
        let requested = self.normalizedScopeList(requestedScopes)
        if requested.isEmpty {
            return true
        }
        let allowed = self.normalizedScopeList(storedScopes)
        if allowed.isEmpty {
            return false
        }
        let allowedSet = Set(allowed)
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedRole != "operator" {
            let prefix = "\(normalizedRole)."
            return requested.allSatisfy { scope in
                scope.hasPrefix(prefix) && allowedSet.contains(scope)
            }
        }
        return requested.allSatisfy { scope in
            self.operatorScopeSatisfied(scope, granted: allowedSet)
        }
    }

    private nonisolated static func normalizedScopeList(_ scopes: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for scope in scopes {
            let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || seen.contains(trimmed) {
                continue
            }
            seen.insert(trimmed)
            out.append(trimmed)
        }
        return out
    }

    private nonisolated static func operatorScopeSatisfied(_ scope: String, granted: Set<String>) -> Bool {
        if !scope.hasPrefix("operator.") {
            return false
        }
        if granted.contains("operator.admin") {
            return true
        }
        if scope == "operator.read" {
            return granted.contains("operator.read") || granted.contains("operator.write")
        }
        if scope == "operator.write" {
            return granted.contains("operator.write")
        }
        return granted.contains(scope)
    }

    private func shouldPersistBootstrapHandoffTokens() -> Bool {
        guard self.lastAuthSource == .bootstrapToken else { return false }
        let scheme = self.url.scheme?.lowercased()
        if scheme == "wss" {
            return true
        }
        guard scheme == "ws", let host = self.url.host else { return false }
        // QR setup explicitly permits plaintext WebSocket only for local-network
        // endpoints. Persist the bounded handoff so the one-shot bootstrap token
        // is never replayed on the first reconnect.
        return LoopbackHost.isLocalNetworkHost(host)
    }

    private func filteredBootstrapHandoffScopes(role: String, scopes: [String]) -> [String]? {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalizedRole {
        case "node":
            return []
        case "operator":
            let allowedOperatorScopes: Set = [
                "operator.approvals",
                "operator.read",
                "operator.talk.secrets",
                "operator.write",
            ]
            return Array(Set(scopes.filter { allowedOperatorScopes.contains($0) })).sorted()
        default:
            return nil
        }
    }

    private func resolveConnectScopes(
        role: String,
        requestedScopes: [String],
        scopesAreExplicit: Bool,
        selectedAuth: SelectedConnectAuth) -> [String]
    {
        if selectedAuth.authSource == .bootstrapToken,
           let filteredScopes = self.filteredBootstrapHandoffScopes(role: role, scopes: requestedScopes)
        {
            return filteredScopes
        }
        if selectedAuth.authSource == .deviceToken,
           !scopesAreExplicit,
           let storedScopes = selectedAuth.storedScopes,
           !storedScopes.isEmpty
        {
            return storedScopes
        }
        return requestedScopes
    }

    private func persistIssuedDeviceToken(
        deviceId: String,
        role: String,
        token: String,
        scopes: [String])
    {
        _ = DeviceAuthStore.storeToken(
            deviceId: deviceId,
            role: role,
            token: token,
            scopes: scopes)
    }

    private func parseBootstrapHandoffScopes(_ value: ProtoAnyCodable?) -> [String]? {
        guard let value else { return [] }
        guard let rawScopes = value.value as? [ProtoAnyCodable] else { return nil }
        var scopes: [String] = []
        scopes.reserveCapacity(rawScopes.count)
        for rawScope in rawScopes {
            guard let scope = rawScope.value as? String else { return nil }
            let normalized = scope.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                scopes.append(normalized)
            }
        }
        return Array(Set(scopes)).sorted()
    }

    private func parseBootstrapHandoffCredential(
        _ raw: [String: ProtoAnyCodable],
        defaultRole: String?) -> GatewayBootstrapHandoffCredential?
    {
        let roleValue: String
        if let rawRole = raw["role"] {
            guard let role = rawRole.value as? String else { return nil }
            roleValue = role
        } else if let defaultRole {
            roleValue = defaultRole
        } else {
            return nil
        }
        let normalizedRole = roleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let role = GatewayBootstrapHandoffRole(rawValue: normalizedRole),
              let scopes = self.parseBootstrapHandoffScopes(raw["scopes"])
        else { return nil }

        let token: String?
        if let rawToken = raw["deviceToken"] {
            guard let tokenValue = rawToken.value as? String else { return nil }
            token = tokenValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } else {
            token = nil
        }
        return GatewayBootstrapHandoffCredential(role: role, token: token, scopes: scopes)
    }

    private func parseBootstrapHandoffCredentials(
        auth: [String: ProtoAnyCodable],
        primaryRole: String) -> ParsedBootstrapHandoffCredentials
    {
        var credentials: [GatewayBootstrapHandoffCredential] = []
        let hasPrimaryCredentialFields = auth["deviceToken"] != nil || auth["role"] != nil || auth["scopes"] != nil
        if hasPrimaryCredentialFields {
            guard let primary = self.parseBootstrapHandoffCredential(auth, defaultRole: primaryRole) else {
                return .malformed
            }
            credentials.append(primary)
        }

        if let rawAdditional = auth["deviceTokens"] {
            guard let entries = rawAdditional.value as? [ProtoAnyCodable] else { return .malformed }
            for entry in entries {
                guard let rawEntry = entry.value as? [String: ProtoAnyCodable],
                      let credential = self.parseBootstrapHandoffCredential(rawEntry, defaultRole: nil)
                else { return .malformed }
                credentials.append(credential)
            }
        }
        return .credentials(credentials)
    }

    private func recordBootstrapHandoff(
        auth: [String: ProtoAnyCodable],
        identity: DeviceIdentity?,
        primaryRole: String,
        connectionGeneration: UInt64)
    {
        var plan: GatewayBootstrapHandoffPlan = switch self.parseBootstrapHandoffCredentials(
            auth: auth,
            primaryRole: primaryRole)
        {
        case let .credentials(credentials):
            GatewayBootstrapHandoffValidator.validate(credentials)
        case .malformed:
            GatewayBootstrapHandoffValidator.malformedPlan()
        }

        if !self.shouldPersistBootstrapHandoffTokens() {
            plan = GatewayBootstrapHandoffPlan(
                issuedRoles: plan.issuedRoles,
                issues: plan.issues + [.untrustedEndpoint],
                writes: [])
        }

        var persistence = GatewayBootstrapHandoffPersistence.notAttempted
        if plan.issues.isEmpty {
            if let identity {
                do {
                    _ = try DeviceAuthStore.storeTokensAtomically(
                        deviceId: identity.deviceId,
                        writes: plan.writes)
                    persistence = .succeeded
                } catch {
                    persistence = .failed
                    self.logger.error("bootstrap handoff credential persistence failed")
                }
            } else {
                persistence = .failed
            }
        }

        self.bootstrapHandoffReceipt = GatewayBootstrapHandoffConnectionReceipt(
            physicalConnectionGeneration: connectionGeneration,
            issuedRoles: plan.issuedRoles,
            issues: plan.issues,
            persistence: persistence)
        // A setup credential is one-shot. A later physical reconnect must use the
        // freshly persisted node credential (or fail honestly), never replay it.
        self.bootstrapToken = nil
    }

    private func handleConnectResponse(
        _ res: ResponseFrame,
        identity: DeviceIdentity?,
        role: String,
        connectionGeneration: UInt64) async throws -> HelloOk
    {
        if res.ok == false {
            let error = res.error
            let msg = error?.message ?? "gateway connect failed"
            let details = gatewayErrorDetails(error)
            let detailCode = details["code"]?.value as? String
            let canRetryWithDeviceToken = details["canRetryWithDeviceToken"]?.value as? Bool ?? false
            let recommendedNextStep = details["recommendedNextStep"]?.value as? String
            let requestId = details["requestId"]?.value as? String
            let reason = details["reason"]?.value as? String
            let owner = details["owner"]?.value as? String
            let title = details["title"]?.value as? String
            let userMessage = details["userMessage"]?.value as? String
            let actionLabel = details["actionLabel"]?.value as? String
            let actionCommand = details["actionCommand"]?.value as? String
            let docsURLString = details["docsUrl"]?.value as? String
            let retryableOverride = details["retryable"]?.value as? Bool
            let pauseReconnectOverride = details["pauseReconnect"]?.value as? Bool
            throw GatewayConnectAuthError(
                message: msg,
                detailCodeRaw: detailCode,
                canRetryWithDeviceToken: canRetryWithDeviceToken,
                recommendedNextStepRaw: recommendedNextStep,
                requestId: requestId,
                detailsReason: reason,
                ownerRaw: owner,
                titleOverride: title,
                userMessageOverride: userMessage,
                actionLabel: actionLabel,
                actionCommand: actionCommand,
                docsURLString: docsURLString,
                retryableOverride: retryableOverride,
                pauseReconnectOverride: pauseReconnectOverride)
        }
        guard let payload = res.payload else {
            throw NSError(
                domain: "Gateway",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "connect failed (missing payload)"])
        }
        let payloadData = try self.encoder.encode(payload)
        let ok = try decoder.decode(HelloOk.self, from: payloadData)
        if let tick = ok.policy["tickIntervalMs"]?.value as? Double {
            self.tickIntervalMs = tick
        } else if let tick = ok.policy["tickIntervalMs"]?.value as? Int {
            self.tickIntervalMs = Double(tick)
        }
        let auth = ok.auth
        if self.lastAuthSource == .bootstrapToken {
            self.recordBootstrapHandoff(
                auth: auth,
                identity: identity,
                primaryRole: role,
                connectionGeneration: connectionGeneration)
        } else if let identity {
            if let deviceToken = auth["deviceToken"]?.value as? String {
                let authRole = auth["role"]?.value as? String ?? role
                let scopes = (auth["scopes"]?.value as? [ProtoAnyCodable])?
                    .compactMap { $0.value as? String } ?? []
                self.persistIssuedDeviceToken(
                    deviceId: identity.deviceId,
                    role: authRole,
                    token: deviceToken,
                    scopes: scopes)
            }
        }
        self.lastTick = Date()
        return ok
    }

    private func deliverPushIfCurrent(
        _ push: GatewayPush,
        connectionGeneration: UInt64) async
    {
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration != connectionGeneration
        else {
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .socket,
                state: "stale_callback_ignored",
                connectionRole: self.diagnosticConnectionRole,
                socketGeneration: connectionGeneration))
            return
        }
        await self.pushHandler?(push, connectionGeneration)
    }

    private func deliverSnapshotAdmissionIfCurrent(
        _ hello: HelloOk,
        connectionGeneration: UInt64) async
    {
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration != connectionGeneration
        else {
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .socket,
                state: "stale_callback_ignored",
                connectionRole: self.diagnosticConnectionRole,
                socketGeneration: connectionGeneration))
            return
        }
        await self.snapshotAdmissionHandler?(hello, connectionGeneration)
    }

    private func listen(task: WebSocketTaskBox, connectionGeneration: UInt64) {
        guard self.isConnected(connectionGeneration: connectionGeneration),
              self.task?.task === task.task
        else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(err):
                Task {
                    await self.handleReceiveFailure(
                        err,
                        connectionGeneration: connectionGeneration)
                }
            case let .success(msg):
                Task {
                    await self.handle(msg, connectionGeneration: connectionGeneration)
                    await self.listen(task: task, connectionGeneration: connectionGeneration)
                }
            }
        }
    }

    private func handleReceiveFailure(
        _ err: Error,
        connectionGeneration: UInt64) async
    {
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration != connectionGeneration
        else {
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .socket,
                state: "stale_callback_ignored",
                connectionRole: self.diagnosticConnectionRole,
                socketGeneration: connectionGeneration))
            return
        }
        let wrapped = self.wrap(err, context: "gateway receive")
        let disconnectedMessage =
            "gateway.trace event=disconnected socket_generation=\(connectionGeneration) "
                + "outcome=requests_failed"
        self.logger.error("\(disconnectedMessage, privacy: .public)")
        self.logger.error("gateway ws receive failed \(wrapped.localizedDescription, privacy: .public)")
        await self.transitionToDisconnected(
            reason: "receive failed: \(wrapped.localizedDescription)",
            error: wrapped,
            connectionGeneration: connectionGeneration,
            shouldReconnect: true)
    }

    private func transitionToDisconnected(
        reason: String,
        error: Error,
        connectionGeneration: UInt64,
        shouldReconnect: Bool) async
    {
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration != connectionGeneration
        else { return }

        // Claim the transition before socket cancellation can enqueue another failure.
        self.disconnectedConnectionGeneration = connectionGeneration
        self.connected = false
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .socket,
            state: "disconnected",
            connectionRole: self.diagnosticConnectionRole,
            socketGeneration: connectionGeneration))
        self.tickTask?.cancel()
        self.tickTask = nil
        self.keepaliveTask?.cancel()
        self.keepaliveTask = nil
        let disconnectedTask = self.task
        self.task = nil
        disconnectedTask?.cancel(with: .goingAway, reason: nil)
        await self.failPending(error, connectionGeneration: connectionGeneration)
        await self.disconnectHandler?(reason, connectionGeneration)

        guard shouldReconnect,
              self.shouldReconnect,
              self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration == connectionGeneration
        else { return }
        Task { [weak self] in
            await self?.scheduleReconnect(after: connectionGeneration)
        }
    }

    private func isConnected(connectionGeneration: UInt64) -> Bool {
        self.connected &&
            self.connectionGeneration == connectionGeneration &&
            self.disconnectedConnectionGeneration != connectionGeneration
    }

    private func ownsSocket(
        _ candidate: WebSocketTaskBox,
        connectionGeneration: UInt64) -> Bool
    {
        guard self.connectionGeneration == connectionGeneration,
              let task = self.task
        else { return false }
        return task.task === candidate.task
    }

    private func requireCurrentSocket(
        _ candidate: WebSocketTaskBox,
        connectionGeneration: UInt64) throws
    {
        try Task.checkCancellation()
        guard self.ownsSocket(candidate, connectionGeneration: connectionGeneration),
              self.disconnectedConnectionGeneration != connectionGeneration
        else { throw CancellationError() }
    }

    private func handle(
        _ msg: URLSessionWebSocketTask.Message,
        connectionGeneration: UInt64) async
    {
        guard self.isConnected(connectionGeneration: connectionGeneration) else {
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .socket,
                state: "stale_callback_ignored",
                connectionRole: self.diagnosticConnectionRole,
                socketGeneration: connectionGeneration))
            return
        }
        let data: Data? = switch msg {
        case let .data(d): d
        case let .string(s): s.data(using: .utf8)
        @unknown default: nil
        }
        guard let data else { return }
        guard let frame = try? self.decoder.decode(GatewayFrame.self, from: data) else {
            self.logger.error("gateway decode failed")
            return
        }
        switch frame {
        case let .res(res):
            let id = res.id
            if let pending = self.pending[id],
               pending.connectionGeneration == connectionGeneration
            {
                self.pending.removeValue(forKey: id)
                self.recordRPCDiagnostic(
                    state: "request_completed",
                    operationIdentifier: id,
                    pending: pending,
                    resultClass: res.ok == false ? "gateway_rejected" : "success",
                    gatewayErrorCode: res.ok == false ? res.error?.code : nil,
                    gatewayErrorMessage: res.ok == false ? res.error?.message : nil)
                pending.continuation.resume(returning: .res(res))
            }
        case let .event(evt):
            if evt.event == "connect.challenge" { return }
            if let seq = evt.seq {
                if let last = lastSeq, seq > last + 1 {
                    await self.pushHandler?(
                        .seqGap(expected: last + 1, received: seq),
                        connectionGeneration)
                    guard self.isConnected(connectionGeneration: connectionGeneration) else { return }
                }
                self.lastSeq = seq
            }
            if evt.event == "tick" { self.lastTick = Date() }
            await self.pushHandler?(.event(evt), connectionGeneration)
        default:
            break
        }
    }

    private func waitForConnectChallenge(
        task: WebSocketTaskBox,
        connectionGeneration: UInt64) async throws -> String
    {
        return try await AsyncTimeout.withTimeout(
            seconds: self.connectChallengeTimeoutSeconds,
            onTimeout: { ConnectChallengeError.timeout },
            operation: { [weak self] in
                guard let self else { throw ConnectChallengeError.timeout }
                while true {
                    let msg = try await task.receive()
                    try await self.requireCurrentSocket(
                        task,
                        connectionGeneration: connectionGeneration)
                    guard let data = self.decodeMessageData(msg) else { continue }
                    guard let frame = try? self.decoder.decode(GatewayFrame.self, from: data) else { continue }
                    if case let .event(evt) = frame, evt.event == "connect.challenge",
                       let payload = evt.payload?.value as? [String: ProtoAnyCodable],
                       let nonce = GatewayConnectChallengeSupport.nonce(from: payload)
                    {
                        return nonce
                    }
                }
            })
    }

    private func waitForConnectResponse(
        reqId: String,
        task: WebSocketTaskBox,
        connectionGeneration: UInt64) async throws -> ResponseFrame
    {
        while true {
            let msg = try await task.receive()
            try self.requireCurrentSocket(task, connectionGeneration: connectionGeneration)
            guard let data = self.decodeMessageData(msg) else { continue }
            guard let frame = try? self.decoder.decode(GatewayFrame.self, from: data) else {
                throw NSError(
                    domain: "Gateway",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "connect failed (invalid response)"])
            }
            if case let .res(res) = frame, res.id == reqId {
                return res
            }
        }
    }

    private nonisolated func decodeMessageData(_ msg: URLSessionWebSocketTask.Message) -> Data? {
        return switch msg {
        case let .data(data): data
        case let .string(text): text.data(using: .utf8)
        @unknown default: nil
        }
    }

    private func startTickWatchdog(connectionGeneration: UInt64) {
        self.tickTask?.cancel()
        self.tickTask = Task { [weak self] in
            guard let self else { return }
            await self.watchTicks(connectionGeneration: connectionGeneration)
        }
    }

    private func watchTicks(connectionGeneration: UInt64) async {
        let tolerance = self.tickIntervalMs * 2
        while self.isConnected(connectionGeneration: connectionGeneration) {
            guard await self.sleepUnlessCancelled(nanoseconds: UInt64(tolerance * 1_000_000)) else { return }
            guard self.isConnected(connectionGeneration: connectionGeneration) else { return }
            if let last = self.lastTick {
                let delta = Date().timeIntervalSince(last) * 1000
                if delta > tolerance {
                    self.logger.error("gateway tick missed; reconnecting")
                    let error = NSError(
                        domain: "Gateway",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "gateway tick missed; reconnecting"])
                    await self.transitionToDisconnected(
                        reason: error.localizedDescription,
                        error: error,
                        connectionGeneration: connectionGeneration,
                        shouldReconnect: true)
                    return
                }
            }
        }
    }

    private func scheduleReconnect(after connectionGeneration: UInt64) async {
        guard self.shouldReconnect else { return }
        guard !self.reconnectPausedForAuthFailure else { return }
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration == connectionGeneration
        else { return }
        let delay = self.backoffMs / 1000
        self.backoffMs = min(self.backoffMs * 2, 30000)
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .reconnect,
            state: "scheduled",
            connectionRole: self.diagnosticConnectionRole,
            socketGeneration: connectionGeneration))
        self.logger.info(
            "gateway.trace event=reconnect_scheduled delay_ms=\(Int(delay * 1000), privacy: .public)")
        guard await self.sleepUnlessCancelled(nanoseconds: UInt64(delay * 1_000_000_000)) else { return }
        guard self.shouldReconnect else { return }
        guard !self.reconnectPausedForAuthFailure else { return }
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration == connectionGeneration
        else { return }
        do {
            try await self.connect()
        } catch {
            if self.shouldPauseReconnectAfterAuthFailure(error) {
                self.reconnectPausedForAuthFailure = true
                self.logger.error(
                    "gateway reconnect paused for non-recoverable auth failure \(error.localizedDescription, privacy: .public)")
                return
            }
            let wrapped = self.wrap(error, context: "gateway reconnect")
            self.logger.error("gateway reconnect failed \(wrapped.localizedDescription, privacy: .public)")
            let failedGeneration = self.connectionGeneration
            if self.disconnectedConnectionGeneration == failedGeneration {
                await self.scheduleReconnect(after: failedGeneration)
            }
        }
    }

    private func shouldRetryWithStoredDeviceToken(
        error: Error,
        explicitGatewayToken: String?,
        storedToken: String?,
        attemptedDeviceTokenRetry: Bool) -> Bool
    {
        if self.deviceTokenRetryBudgetUsed {
            return false
        }
        if attemptedDeviceTokenRetry {
            return false
        }
        guard explicitGatewayToken != nil, storedToken != nil else {
            return false
        }
        guard self.isTrustedDeviceRetryEndpoint() else {
            return false
        }
        guard let authError = error as? GatewayConnectAuthError else {
            return false
        }
        return authError.canRetryWithDeviceToken ||
            authError.detail == .authTokenMismatch
    }

    private func shouldPauseReconnectAfterAuthFailure(_ error: Error) -> Bool {
        guard let authError = error as? GatewayConnectAuthError else {
            return false
        }
        if authError.isNonRecoverable {
            return true
        }
        if authError.detail == .authTokenMismatch,
           self.deviceTokenRetryBudgetUsed, !self.pendingDeviceTokenRetry
        {
            return true
        }
        return false
    }

    private func shouldClearStoredDeviceTokenAfterRetry(_ error: Error) -> Bool {
        guard let authError = error as? GatewayConnectAuthError else {
            return false
        }
        return authError.detail == .authDeviceTokenMismatch
    }

    private func isTrustedDeviceRetryEndpoint() -> Bool {
        guard let host = self.url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty
        else {
            return false
        }
        if host == "localhost" || host == "::1" || host == "127.0.0.1" || host.hasPrefix("127.") {
            return true
        }
        if self.url.scheme?.lowercased() == "wss",
           let trust = self.session as? GatewayDeviceTokenRetryTrustProviding
        {
            return trust.allowsDeviceTokenRetryAuth
        }
        return false
    }

    private nonisolated func sleepUnlessCancelled(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    public func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double? = nil,
        diagnosticRouteGeneration: UInt64? = nil) async throws -> Data
    {
        try await self.connectOrThrow(context: "gateway connect")
        let connectionGeneration = self.connectionGeneration
        guard self.isConnected(connectionGeneration: connectionGeneration),
              let task = self.task,
              task.state == .running
        else {
            throw NSError(
                domain: "Gateway",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "gateway socket unavailable"])
        }
        return try await self.request(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            task: task,
            connectionGeneration: connectionGeneration,
            routeGeneration: diagnosticRouteGeneration)
    }

    /// Dispatches only through the already-connected physical socket generation.
    public func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double? = nil,
        ifCurrentConnectionGeneration expectedGeneration: UInt64,
        diagnosticRouteGeneration: UInt64? = nil) async throws -> Data
    {
        guard self.isConnected(connectionGeneration: expectedGeneration),
              let task = self.task,
              task.state == .running
        else { throw CancellationError() }
        return try await self.request(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            task: task,
            connectionGeneration: expectedGeneration,
            routeGeneration: diagnosticRouteGeneration)
    }

    /// Classifies one route-bound request by whether physical dispatch began.
    /// Once `task.send` starts, transport loss is ambiguous and callers must
    /// reconcile against canonical history before replaying the same identity.
    public func requestTrackingDispatch(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double? = nil,
        ifCurrentConnectionGeneration expectedGeneration: UInt64,
        diagnosticRouteGeneration: UInt64? = nil) async -> GatewayRequestDispatchResult
    {
        guard self.isConnected(connectionGeneration: expectedGeneration),
              let task = self.task,
              task.state == .running
        else { return .notDispatched }

        let probe = GatewayRequestDispatchProbe()
        do {
            let data = try await self.request(
                method: method,
                params: params,
                timeoutMs: timeoutMs,
                task: task,
                connectionGeneration: expectedGeneration,
                routeGeneration: diagnosticRouteGeneration,
                dispatchProbe: probe)
            return .response(data)
        } catch let error as GatewayResponseError {
            return .rejected(code: error.code, reason: error.detailsReason)
        } catch {
            guard probe.didStartDispatch() else { return .notDispatched }
            return .ambiguous(code: Self.dispatchFailureCode(error))
        }
    }

    public func currentConnectionGeneration() -> UInt64? {
        let generation = self.connectionGeneration
        guard self.isConnected(connectionGeneration: generation),
              self.task?.state == .running
        else { return nil }
        return generation
    }

    private func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double?,
        task: WebSocketTaskBox,
        connectionGeneration: UInt64,
        routeGeneration: UInt64?,
        dispatchProbe: GatewayRequestDispatchProbe? = nil) async throws -> Data
    {
        let effectiveTimeout = timeoutMs ?? self.defaultRequestTimeoutMs
        let payload = try self.encodeRequest(method: method, params: params, kind: "request")
        let parameterShape = GatewayRPCDiagnosticParameterShape.inspect(method: method, params: params)
        let admittedAt = Date()
        let admittedUptime = ProcessInfo.processInfo.systemUptime
        let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GatewayFrame, Error>) in
            self.pending[payload.id] = PendingRequest(
                connectionGeneration: connectionGeneration,
                routeGeneration: routeGeneration,
                rpcMethod: method,
                parameterShape: parameterShape,
                admittedAt: admittedAt,
                admittedUptime: admittedUptime,
                continuation: cont)
            self.recordRPCDiagnostic(
                state: "request_admitted",
                operationIdentifier: payload.id,
                connectionGeneration: connectionGeneration,
                routeGeneration: routeGeneration,
                method: method,
                shape: parameterShape,
                admittedAt: admittedAt,
                elapsedMilliseconds: 0,
                resultClass: "requested")
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000))
                await self.timeoutRequest(
                    id: payload.id,
                    timeoutMs: effectiveTimeout,
                    connectionGeneration: connectionGeneration)
            }
            Task {
                guard self.isConnected(connectionGeneration: connectionGeneration) else {
                    self.cancelRequest(id: payload.id, connectionGeneration: connectionGeneration)
                    return
                }
                do {
                    dispatchProbe?.markDispatchStarted()
                    try await task.send(.data(payload.data))
                    guard self.isConnected(connectionGeneration: connectionGeneration) else {
                        self.cancelRequest(id: payload.id, connectionGeneration: connectionGeneration)
                        return
                    }
                } catch {
                    let wrapped = self.wrap(error, context: "gateway send \(method)")
                    await self.transitionToDisconnected(
                        reason: "send failed: \(wrapped.localizedDescription)",
                        error: wrapped,
                        connectionGeneration: connectionGeneration,
                        shouldReconnect: true)
                }
            }
        }
        guard self.isConnected(connectionGeneration: connectionGeneration) else {
            throw CancellationError()
        }
        guard case let .res(res) = response else {
            throw NSError(domain: "Gateway", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected frame"])
        }
        if res.ok == false {
            let code = res.error?.code
            let msg = res.error?.message
            let details = gatewayErrorDetails(res.error)
            throw GatewayResponseError(method: method, code: code, message: msg, details: details)
        }
        if let payload = res.payload {
            // Encode back to JSON with Swift's encoder to preserve types and avoid ObjC bridging exceptions.
            return try self.encoder.encode(payload)
        }
        return Data() // Should not happen, but tolerate empty payloads.
    }

    public func send(
        method: String,
        params: [String: AnyCodable]?,
        diagnosticRouteGeneration: UInt64? = nil) async throws
    {
        try await self.connectOrThrow(context: "gateway connect")
        try await self.send(
            method: method,
            params: params,
            connectionGeneration: self.connectionGeneration,
            routeGeneration: diagnosticRouteGeneration)
    }

    /// Dispatches only through the socket that admitted the owning operation.
    public func send(
        method: String,
        params: [String: AnyCodable]?,
        ifCurrentConnectionGeneration expectedGeneration: UInt64,
        diagnosticRouteGeneration: UInt64? = nil) async throws
    {
        guard self.isConnected(connectionGeneration: expectedGeneration) else {
            throw CancellationError()
        }
        try await self.send(
            method: method,
            params: params,
            connectionGeneration: expectedGeneration,
            routeGeneration: diagnosticRouteGeneration)
    }

    private func send(
        method: String,
        params: [String: AnyCodable]?,
        connectionGeneration: UInt64,
        routeGeneration: UInt64?) async throws
    {
        let payload = try self.encodeRequest(method: method, params: params, kind: "send")
        let shape = GatewayRPCDiagnosticParameterShape.inspect(method: method, params: params)
        let admittedAt = Date()
        let admittedUptime = ProcessInfo.processInfo.systemUptime
        guard self.isConnected(connectionGeneration: connectionGeneration),
              let task = self.task
        else {
            throw NSError(
                domain: "Gateway",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "gateway socket unavailable"])
        }
        self.recordRPCDiagnostic(
            state: "request_admitted",
            operationIdentifier: payload.id,
            connectionGeneration: connectionGeneration,
            routeGeneration: routeGeneration,
            method: method,
            shape: shape,
            admittedAt: admittedAt,
            elapsedMilliseconds: 0,
            resultClass: "requested")
        do {
            try await task.send(.data(payload.data))
            guard self.isConnected(connectionGeneration: connectionGeneration) else {
                throw CancellationError()
            }
            self.recordRPCDiagnostic(
                state: "request_completed",
                operationIdentifier: payload.id,
                connectionGeneration: connectionGeneration,
                routeGeneration: routeGeneration,
                method: method,
                shape: shape,
                admittedAt: admittedAt,
                elapsedMilliseconds: max(
                    0,
                    Int((ProcessInfo.processInfo.systemUptime - admittedUptime) * 1000)),
                resultClass: "transport_write_accepted_unacknowledged")
        } catch is CancellationError {
            self.recordRPCDiagnostic(
                state: "request_cancelled",
                operationIdentifier: payload.id,
                connectionGeneration: connectionGeneration,
                routeGeneration: routeGeneration,
                method: method,
                shape: shape,
                admittedAt: admittedAt,
                elapsedMilliseconds: max(
                    0,
                    Int((ProcessInfo.processInfo.systemUptime - admittedUptime) * 1000)),
                resultClass: "cancelled")
            throw CancellationError()
        } catch {
            self.recordRPCDiagnostic(
                state: "request_failed",
                operationIdentifier: payload.id,
                connectionGeneration: connectionGeneration,
                routeGeneration: routeGeneration,
                method: method,
                shape: shape,
                admittedAt: admittedAt,
                elapsedMilliseconds: max(
                    0,
                    Int((ProcessInfo.processInfo.systemUptime - admittedUptime) * 1000)),
                resultClass: "transport_error")
            let wrapped = self.wrap(error, context: "gateway send \(method)")
            await self.transitionToDisconnected(
                reason: "send failed: \(wrapped.localizedDescription)",
                error: wrapped,
                connectionGeneration: connectionGeneration,
                shouldReconnect: true)
            throw wrapped
        }
    }

    /// Wrap low-level URLSession/WebSocket errors with context so UI can surface them.
    private func wrap(_ error: Error, context: String) -> Error {
        if error is CancellationError ||
            error is GatewayConnectAuthError ||
            error is GatewayResponseError ||
            error is GatewayDecodingError ||
            error is GatewayTLSValidationError
        {
            return error
        }
        if let urlError = error as? URLError {
            if let failure = (self.session as? GatewayTLSFailureProviding)?.consumeLastTLSFailure() {
                return GatewayTLSValidationError(failure: failure, context: context)
            }
            let desc = urlError.localizedDescription.isEmpty ? "cancelled" : urlError.localizedDescription
            return NSError(
                domain: URLError.errorDomain,
                code: urlError.errorCode,
                userInfo: [NSLocalizedDescriptionKey: "\(context): \(desc)"])
        }
        let ns = error as NSError
        let desc = ns.localizedDescription.isEmpty ? "unknown" : ns.localizedDescription
        return NSError(domain: ns.domain, code: ns.code, userInfo: [NSLocalizedDescriptionKey: "\(context): \(desc)"])
    }

    private nonisolated static func dispatchFailureCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError {
            return "url:\(urlError.errorCode)"
        }
        return "transport:\((error as NSError).code)"
    }

    private func connectOrThrow(context: String) async throws {
        do {
            try await self.connect()
        } catch {
            throw self.wrap(error, context: context)
        }
    }

    private func encodeRequest(
        method: String,
        params: [String: AnyCodable]?,
        kind: String) throws -> (id: String, data: Data)
    {
        let id = UUID().uuidString
        // Encode request using the generated models to avoid JSONSerialization/ObjC bridging pitfalls.
        let paramsObject: ProtoAnyCodable? = params.map { entries in
            let dict = entries.reduce(into: [String: ProtoAnyCodable]()) { dict, entry in
                dict[entry.key] = ProtoAnyCodable(entry.value.value)
            }
            return ProtoAnyCodable(dict)
        }
        let frame = RequestFrame(
            type: "req",
            id: id,
            method: method,
            params: paramsObject)
        do {
            let data = try self.encoder.encode(frame)
            return (id: id, data: data)
        } catch {
            self.logger.error(
                "gateway \(kind) encode failed \(method, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func failPending(
        _ error: Error,
        connectionGeneration: UInt64?,
        resultClass: String? = nil) async
    {
        let requestIDs: [String] = self.pending.compactMap { id, pending -> String? in
            if let connectionGeneration, pending.connectionGeneration != connectionGeneration {
                return nil
            }
            return id
        }
        for id in requestIDs {
            guard let pending = self.pending.removeValue(forKey: id) else { continue }
            let resolvedResultClass = resultClass ??
                (error is CancellationError ? "cancelled" : "transport_error")
            self.recordRPCDiagnostic(
                state: resolvedResultClass == "cancelled" ? "request_cancelled" : "request_failed",
                operationIdentifier: id,
                pending: pending,
                resultClass: resolvedResultClass)
            pending.continuation.resume(throwing: error)
        }
    }

    private func timeoutRequest(
        id: String,
        timeoutMs: Double,
        connectionGeneration: UInt64) async
    {
        guard let pending = self.pending[id],
              pending.connectionGeneration == connectionGeneration
        else { return }
        self.pending.removeValue(forKey: id)
        self.recordRPCDiagnostic(
            state: "request_timed_out",
            operationIdentifier: id,
            pending: pending,
            resultClass: "timeout")
        let err = NSError(
            domain: "Gateway",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "gateway request timed out after \(Int(timeoutMs))ms"])
        pending.continuation.resume(throwing: err)
    }

    private func cancelRequest(id: String, connectionGeneration: UInt64) {
        guard let pending = self.pending[id],
              pending.connectionGeneration == connectionGeneration
        else { return }
        self.pending.removeValue(forKey: id)
        self.recordRPCDiagnostic(
            state: "request_cancelled",
            operationIdentifier: id,
            pending: pending,
            resultClass: "cancelled")
        pending.continuation.resume(throwing: CancellationError())
    }

    private func recordRPCDiagnostic(
        state: String,
        operationIdentifier: String,
        pending: PendingRequest,
        resultClass: String,
        gatewayErrorCode: String? = nil,
        gatewayErrorMessage: String? = nil)
    {
        let elapsed = max(
            0,
            Int((ProcessInfo.processInfo.systemUptime - pending.admittedUptime) * 1000))
        self.recordRPCDiagnostic(
            state: state,
            operationIdentifier: operationIdentifier,
            connectionGeneration: pending.connectionGeneration,
            routeGeneration: pending.routeGeneration,
            method: pending.rpcMethod,
            shape: pending.parameterShape,
            admittedAt: pending.admittedAt,
            elapsedMilliseconds: elapsed,
            resultClass: resultClass,
            gatewayErrorCode: gatewayErrorCode,
            gatewayErrorMessage: gatewayErrorMessage)
    }

    private func recordRPCDiagnostic(
        state: String,
        operationIdentifier: String,
        connectionGeneration: UInt64,
        routeGeneration: UInt64?,
        method: String,
        shape: GatewayRPCDiagnosticParameterShape,
        admittedAt: Date,
        elapsedMilliseconds: Int?,
        resultClass: String,
        gatewayErrorCode: String? = nil,
        gatewayErrorMessage: String? = nil)
    {
        let validation = GatewayRPCDiagnosticParameterShape.classifyGatewayValidation(
            errorCode: gatewayErrorCode,
            message: gatewayErrorMessage)
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .socket,
            state: state,
            connectionRole: self.diagnosticConnectionRole,
            socketGeneration: connectionGeneration,
            routeGeneration: routeGeneration,
            sessionIdentifier: shape.sessionIdentifier,
            operationIdentifier: operationIdentifier,
            rpcMethod: method,
            admittedAt: admittedAt,
            gatewayErrorCode: gatewayErrorCode,
            offsetPresent: shape.offsetPresent,
            offsetType: shape.offsetType,
            offsetValue: shape.offsetValue,
            limitPresent: shape.limitPresent,
            limitValue: shape.limitValue,
            maxCharsPresent: shape.maxCharsPresent,
            maxCharsValue: shape.maxCharsValue,
            encodedPropertyNames: shape.encodedPropertyNames,
            gatewayValidationPath: validation.path,
            gatewayErrorMessageClass: validation.messageClass,
            gatewayValidatorIdentity: shape.gatewayValidatorIdentity,
            protocolSchemaVersion: shape.protocolSchemaVersion,
            requestEnvelopeVersion: shape.requestEnvelopeVersion,
            elapsedMilliseconds: elapsedMilliseconds,
            resultClass: resultClass))
    }
}

// Intentionally no `GatewayChannel` wrapper: the app should use the single shared `GatewayConnection`.
