import Foundation
import OpenClawProtocol
import OSLog

private struct NodeInvokeRequestPayload: Codable {
    var id: String
    var nodeId: String
    var command: String
    var paramsJSON: String?
    var timeoutMs: Int?
    var idempotencyKey: String?
}

/// Lease for one installed gateway channel, lifecycle admission, and physical socket.
/// Suspended work keeps this route so it cannot retarget itself to a replacement gateway.
public struct GatewayNodeSessionRoute: Sendable, Equatable {
    fileprivate let channelGeneration: UInt64
    fileprivate let admissionGeneration: UInt64
    fileprivate let socketGeneration: UInt64
}

func canonicalizeCanvasHostUrl(raw: String?, activeURL: URL?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    guard var parsed = URLComponents(string: trimmed) else { return trimmed }

    let parsedHost = parsed.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let parsedIsLoopback = !parsedHost.isEmpty && LoopbackHost.isLoopback(parsedHost)

    if !parsedHost.isEmpty, !parsedIsLoopback {
        guard let activeURL else { return trimmed }
        let isTLS = activeURL.scheme?.lowercased() == "wss"
        guard isTLS else { return trimmed }
        parsed.scheme = "https"
        if parsed.port == nil {
            let tlsPort = activeURL.port ?? 443
            parsed.port = (tlsPort == 443) ? nil : tlsPort
        }
        return parsed.string ?? trimmed
    }

    guard let activeURL, let fallbackHost = activeURL.host, !LoopbackHost.isLoopback(fallbackHost) else {
        return trimmed
    }
    let isTLS = activeURL.scheme?.lowercased() == "wss"
    parsed.scheme = isTLS ? "https" : "http"
    parsed.host = fallbackHost
    let fallbackPort = activeURL.port ?? (isTLS ? 443 : 80)
    parsed.port = ((isTLS && fallbackPort == 443) || (!isTLS && fallbackPort == 80)) ? nil : fallbackPort
    return parsed.string ?? trimmed
}

public actor GatewayNodeSession {
    @TaskLocal private static var executingLifecycleCallbackID: UUID?

    private struct LifecycleCallbackBarrier {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum SnapshotWaitResult: Sendable {
        case ready
        case invalidated
        case timedOut
    }

    private struct SnapshotWaiter {
        let channel: GatewayChannelActor
        let channelGeneration: UInt64
        let admissionGeneration: UInt64
        let socketGeneration: UInt64
        let continuation: CheckedContinuation<SnapshotWaitResult, Never>
    }

    private struct RouteBoundBootstrapHandoffReceipt {
        let route: GatewayNodeSessionRoute
        let receipt: GatewayBootstrapHandoffReceipt
    }

    private let logger = Logger(subsystem: "ai.openclaw", category: "node.gateway")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private static let defaultInvokeTimeoutMs = 30000
    private var channel: GatewayChannelActor?
    private var activeURL: URL?
    private var activeToken: String?
    private var activeBootstrapToken: String?
    private var activePassword: String?
    private var activeConnectOptionsKey: String?
    private var activeSessionIdentity: ObjectIdentifier?
    private var channelGeneration: UInt64 = 0
    private var admissionGeneration: UInt64 = 0
    private var activeSocketGeneration: UInt64?
    private var lastRetiredSocketGeneration: UInt64?
    private var lifecycleCallbackBarrier: LifecycleCallbackBarrier?
    private var executingLifecycleCallbackIDs: Set<UUID> = []
    private var connectOptions: GatewayConnectOptions?
    private var onConnected: (@Sendable () async -> Void)?
    private var onConnectedRoute: (@Sendable (GatewayNodeSessionRoute) async -> Void)?
    private var onDisconnected: (@Sendable (String) async -> Void)?
    private var onInvoke: (@Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse)?
    private var hasEverConnected = false
    private var hasNotifiedConnected = false
    private var snapshotReceived = false
    private var serverCapabilities: Set<GatewayServerCapability>?
    private var serverCapabilityNames: Set<String>?
    private var authenticatedOperatorScopes: Set<String>?
    private var routeBoundBootstrapHandoffReceipt: RouteBoundBootstrapHandoffReceipt?
    private var snapshotWaiters: [UUID: SnapshotWaiter] = [:]
    #if DEBUG
    private var testBeforePushAdmission: (@Sendable () async -> Void)?
    #endif

    static func invokeWithTimeout(
        request: BridgeInvokeRequest,
        timeoutMs: Int?,
        onInvoke: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse) async -> BridgeInvokeResponse
    {
        let timeoutLogger = Logger(subsystem: "ai.openclaw", category: "node.gateway")
        let timeout: Int = {
            if let timeoutMs { return max(0, timeoutMs) }
            return Self.defaultInvokeTimeoutMs
        }()
        guard timeout > 0 else {
            return await onInvoke(request)
        }

        // Use an explicit latch so timeouts win even if onInvoke blocks (e.g., permission prompts).
        final class InvokeLatch: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<BridgeInvokeResponse, Never>?
            private var resumed = false

            func setContinuation(_ continuation: CheckedContinuation<BridgeInvokeResponse, Never>) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.continuation = continuation
            }

            func resume(_ response: BridgeInvokeResponse) {
                let cont: CheckedContinuation<BridgeInvokeResponse, Never>?
                self.lock.lock()
                if self.resumed {
                    self.lock.unlock()
                    return
                }
                self.resumed = true
                cont = self.continuation
                self.continuation = nil
                self.lock.unlock()
                cont?.resume(returning: response)
            }
        }

        let latch = InvokeLatch()
        var onInvokeTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        defer {
            onInvokeTask?.cancel()
            timeoutTask?.cancel()
        }
        let response = await withCheckedContinuation { (cont: CheckedContinuation<BridgeInvokeResponse, Never>) in
            latch.setContinuation(cont)
            onInvokeTask = Task.detached {
                let result = await onInvoke(request)
                latch.resume(result)
            }
            timeoutTask = Task.detached {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                } catch {
                    // Expected when invoke finishes first and cancels the timeout task.
                    return
                }
                guard !Task.isCancelled else { return }
                timeoutLogger.info("node invoke timeout fired id=\(request.id, privacy: .public)")
                latch.resume(BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(
                        code: .unavailable,
                        message: "node invoke timed out")))
            }
        }
        timeoutLogger
            .info("node invoke race resolved id=\(request.id, privacy: .public) ok=\(response.ok, privacy: .public)")
        return response
    }

    private var serverEventSubscribers: [UUID: AsyncStream<EventFrame>.Continuation] = [:]
    private var pluginSurfaceUrls: [String: String] = [:]

    private struct PluginSurfaceRefreshResponse: Decodable {
        let pluginSurfaceUrls: [String: AnyCodable]?
    }

    public init() {}

    private func connectOptionsKey(_ options: GatewayConnectOptions) -> String {
        func sorted(_ values: [String]) -> String {
            values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
                .joined(separator: ",")
        }
        let role = options.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = sorted(options.scopes)
        let caps = sorted(options.caps)
        let commands = sorted(options.commands)
        let clientId = options.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientMode = options.clientMode.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientDisplayName = (options.clientDisplayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stableGatewayID = (options.stableGatewayID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let includeDeviceIdentity = options.includeDeviceIdentity ? "1" : "0"
        let permissions = options.permissions
            .map { key, value in
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(trimmed)=\(value ? "1" : "0")"
            }
            .sorted()
            .joined(separator: ",")

        return [
            role,
            scopes,
            caps,
            commands,
            clientId,
            clientMode,
            clientDisplayName,
            stableGatewayID,
            includeDeviceIdentity,
            permissions,
        ].joined(separator: "|")
    }

    public func connect(
        url: URL,
        token: String?,
        bootstrapToken: String?,
        password: String?,
        connectOptions: GatewayConnectOptions,
        sessionBox: WebSocketSessionBox?,
        onConnected: @escaping @Sendable () async -> Void,
        onConnectedRoute: (@Sendable (GatewayNodeSessionRoute) async -> Void)? = nil,
        onDisconnected: @escaping @Sendable (String) async -> Void,
        onInvoke: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse) async throws
    {
        let nextOptionsKey = self.connectOptionsKey(connectOptions)
        let nextSessionIdentity = sessionBox.map { ObjectIdentifier($0.session) }
        let shouldReconnect = self.activeURL != url ||
            self.activeToken != token ||
            self.activeBootstrapToken != bootstrapToken ||
            self.activePassword != password ||
            self.activeConnectOptionsKey != nextOptionsKey ||
            self.activeSessionIdentity != nextSessionIdentity ||
            self.channel == nil

        // Lifecycle callbacks cannot initiate even a same-config physical connect:
        // doing so can wait on their own barrier or admit a successor before cleanup.
        guard !self.isExecutingLifecycleCallback()
        else { throw CancellationError() }

        let installedChannelGeneration: UInt64
        if shouldReconnect {
            if let activeSocketGeneration = self.activeSocketGeneration {
                OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                    kind: .route,
                    state: "retired",
                    socketGeneration: activeSocketGeneration,
                    routeGeneration: self.admissionGeneration))
            }
            self.channelGeneration &+= 1
            self.admissionGeneration &+= 1
            installedChannelGeneration = self.channelGeneration
            self.resetConnectionState()
            let existing = self.channel
            // Detach synchronously so callbacks from the retiring channel fail their
            // owner-generation check even while shutdown is suspended.
            self.channel = nil
            self.activeSocketGeneration = nil
            self.lastRetiredSocketGeneration = nil
            await existing?.shutdown()
            await self.waitForLifecycleCallbacksIfNeeded()
            guard self.channelGeneration == installedChannelGeneration else {
                throw CancellationError()
            }
            let channel = GatewayChannelActor(
                url: url,
                token: token,
                bootstrapToken: bootstrapToken,
                password: password,
                session: sessionBox,
                generationAwarePushHandler: { [weak self] push, socketGeneration in
                    await self?.handlePush(
                        push,
                        channelGeneration: installedChannelGeneration,
                        socketGeneration: socketGeneration)
                },
                connectOptions: connectOptions,
                generationAwareDisconnectHandler: { [weak self] reason, socketGeneration in
                    await self?.handleChannelDisconnected(
                        reason,
                        channelGeneration: installedChannelGeneration,
                        socketGeneration: socketGeneration)
                })
            self.channel = channel
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .route,
                state: "installed",
                routeGeneration: self.admissionGeneration))
            self.connectOptions = connectOptions
            self.onConnected = onConnected
            self.onConnectedRoute = onConnectedRoute
            self.onDisconnected = onDisconnected
            self.onInvoke = onInvoke
            self.activeURL = url
            self.activeToken = token
            self.activeBootstrapToken = bootstrapToken
            self.activePassword = password
            self.activeConnectOptionsKey = nextOptionsKey
            self.activeSessionIdentity = nextSessionIdentity
        } else {
            installedChannelGeneration = self.channelGeneration
            self.connectOptions = connectOptions
            self.onConnected = onConnected
            self.onConnectedRoute = onConnectedRoute
            self.onDisconnected = onDisconnected
            self.onInvoke = onInvoke
        }

        guard let channel = self.channel else {
            throw NSError(domain: "Gateway", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "gateway channel unavailable",
            ])
        }

        let expectedAdmissionGeneration = self.admissionGeneration
        try await channel.connect()
        guard self.channelGeneration == installedChannelGeneration,
              self.admissionGeneration == expectedAdmissionGeneration,
              self.channel === channel
        else { throw CancellationError() }
        guard let expectedSocketGeneration = await channel.currentConnectionGeneration() else {
            throw CancellationError()
        }
        guard self.channelGeneration == installedChannelGeneration,
              self.admissionGeneration == expectedAdmissionGeneration,
              self.channel === channel
        else { throw CancellationError() }
        let snapshotResult = await self.waitForSnapshot(
            timeoutMs: 500,
            channel: channel,
            channelGeneration: installedChannelGeneration,
            admissionGeneration: expectedAdmissionGeneration,
            socketGeneration: expectedSocketGeneration)
        switch snapshotResult {
        case .invalidated:
            throw CancellationError()
        case .timedOut:
            // timeoutSnapshotWaiter atomically detached this exact route before
            // waking connect(), so shutdown cannot affect a successor channel.
            await channel.shutdown()
            throw NSError(domain: "Gateway", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "gateway snapshot timed out",
            ])
        case .ready:
            break
        }
        guard self.channelGeneration == installedChannelGeneration,
              self.admissionGeneration == expectedAdmissionGeneration,
              self.channel === channel,
              self.activeSocketGeneration == expectedSocketGeneration
        else { throw CancellationError() }
        await self.notifyConnectedIfNeeded(admissionGeneration: expectedAdmissionGeneration)
        guard self.channelGeneration == installedChannelGeneration,
              self.admissionGeneration == expectedAdmissionGeneration,
              self.channel === channel
        else { throw CancellationError() }
    }

    public func disconnect() async {
        let isLifecycleReentry = self.isExecutingLifecycleCallback()
        if let activeSocketGeneration = self.activeSocketGeneration {
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .route,
                state: "retired",
                socketGeneration: activeSocketGeneration,
                routeGeneration: self.admissionGeneration))
        }
        self.channelGeneration &+= 1
        self.admissionGeneration &+= 1
        let channel = self.channel
        self.channel = nil
        self.activeURL = nil
        self.activeToken = nil
        self.activeBootstrapToken = nil
        self.activePassword = nil
        self.activeConnectOptionsKey = nil
        self.activeSessionIdentity = nil
        self.connectOptions = nil
        self.onConnected = nil
        self.onConnectedRoute = nil
        self.onDisconnected = nil
        self.onInvoke = nil
        self.activeSocketGeneration = nil
        self.lastRetiredSocketGeneration = nil
        self.hasEverConnected = false
        self.resetConnectionState()
        await channel?.shutdown()
        if !isLifecycleReentry {
            await self.waitForLifecycleCallbacksIfNeeded()
        }
    }

    /// Retires only the exact admitted route. A stale health or lifecycle task
    /// cannot disconnect a successor connection installed in the same session.
    @discardableResult
    public func disconnect(ifCurrentRoute expectedRoute: GatewayNodeSessionRoute) async -> Bool {
        guard self.isCurrentRoute(expectedRoute) else { return false }
        await self.disconnect()
        return true
    }

    public func currentCanvasHostUrl() -> String? {
        self.pluginSurfaceUrls["canvas"]
    }

    @discardableResult
    public func refreshPluginSurfaceUrl(surface: String, timeoutSeconds: Int = 8) async -> String? {
        guard let (channel, route) = self.activeRoute() else { return nil }
        let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSurface.isEmpty else { return nil }

        return await self.requestPluginSurfaceRefresh(
            channel: channel,
            method: "node.pluginSurface.refresh",
            params: ["surface": AnyCodable(trimmedSurface)],
            surface: trimmedSurface,
            timeoutSeconds: timeoutSeconds,
            route: route)
    }

    @discardableResult
    public func refreshCanvasHostUrl(timeoutSeconds: Int = 8) async -> String? {
        await self.refreshPluginSurfaceUrl(surface: "canvas", timeoutSeconds: timeoutSeconds)
    }

    public func currentRemoteAddress() -> String? {
        guard let url = self.activeURL else { return nil }
        guard let host = url.host else { return url.absoluteString }
        let port = url.port ?? (url.scheme == "wss" ? 443 : 80)
        if host.contains(":") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    public func currentRemoteAddress(ifCurrentRoute route: GatewayNodeSessionRoute) -> String? {
        guard self.isCurrentRoute(route) else { return nil }
        return self.currentRemoteAddress()
    }

    /// Captures the current route after both the session and physical socket have admitted it.
    public func currentRoute(ifGatewayID expectedGatewayID: String? = nil) async -> GatewayNodeSessionRoute? {
        guard let (channel, route) = self.activeRoute() else { return nil }
        if let expectedGatewayID {
            let expected = expectedGatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = self.connectOptions?.stableGatewayID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expected.isEmpty, current == expected else { return nil }
        }
        guard let socketGeneration = await channel.currentConnectionGeneration(),
              socketGeneration == route.socketGeneration,
              self.isCurrentRoute(route),
              self.channel === channel,
              self.activeSocketGeneration == socketGeneration
        else { return nil }
        return route
    }

    public func currentGatewayID(ifCurrentRoute route: GatewayNodeSessionRoute) -> String? {
        guard self.isCurrentRoute(route), self.channel != nil else { return nil }
        let value = self.connectOptions?.stableGatewayID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    public func supportsServerCapability(
        _ capability: GatewayServerCapability,
        ifCurrentRoute route: GatewayNodeSessionRoute) -> Bool?
    {
        guard self.isCurrentRoute(route),
              self.channel != nil,
              let serverCapabilities
        else { return nil }
        return serverCapabilities.contains(capability)
    }

    public func serverCapabilities(ifCurrentRoute route: GatewayNodeSessionRoute) -> Set<String>? {
        guard self.isCurrentRoute(route), self.channel != nil else { return nil }
        return self.serverCapabilityNames
    }

    public func operatorScopes(ifCurrentRoute route: GatewayNodeSessionRoute) -> Set<String>? {
        guard self.isCurrentRoute(route), self.channel != nil else { return nil }
        return self.authenticatedOperatorScopes
    }

    /// Returns setup-code issuance evidence only while its exact admitted route is current.
    /// Stored credentials are deliberately not consulted, so a stale operator token cannot
    /// make a fresh node-only issuance appear complete.
    public func bootstrapHandoffReceipt(
        ifCurrentRoute route: GatewayNodeSessionRoute) async -> GatewayBootstrapHandoffReceipt?
    {
        switch await self.bootstrapHandoffRouteState(ifCurrentRoute: route) {
        case let .receipt(receipt): receipt
        case .retired, .missing: nil
        }
    }

    /// Distinguishes a current route with missing issuance evidence from a route
    /// that retired while its admission callback was awaiting validation.
    public func bootstrapHandoffRouteState(
        ifCurrentRoute route: GatewayNodeSessionRoute) async -> GatewayBootstrapHandoffRouteState
    {
        guard self.isCurrentRoute(route), let channel = self.channel else { return .retired }
        guard let bound = self.routeBoundBootstrapHandoffReceipt,
              bound.route == route
        else { return .missing }

        // The channel clears its receipt synchronously at the start of every real
        // physical connection attempt. Recheck every owner after the actor hop so
        // route retirement is never reported as a malformed current receipt.
        let connectionReceipt = await channel.bootstrapHandoffConnectionReceipt(
            ifCurrentConnectionGeneration: route.socketGeneration)
        guard self.isCurrentRoute(route), self.channel === channel else { return .retired }
        guard connectionReceipt != nil,
              self.routeBoundBootstrapHandoffReceipt?.route == route
        else { return .missing }
        return .receipt(bound.receipt)
    }

    public func sendEvent(event: String, payloadJSON: String?) async {
        guard let (channel, route) = self.activeRoute() else { return }
        let params: [String: AnyCodable] = [
            "event": AnyCodable(event),
            "payloadJSON": AnyCodable(payloadJSON ?? NSNull()),
        ]
        do {
            try await channel.send(
                method: "node.event",
                params: params,
                ifCurrentConnectionGeneration: route.socketGeneration)
            guard self.isCurrentRoute(route), self.channel === channel
            else { return }
        } catch {
            self.logger.error("node event failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends a node event only through the exact admitted route captured by the
    /// caller. A replacement connection can never inherit the side effect.
    @discardableResult
    public func sendEvent(
        event: String,
        payloadJSON: String?,
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute) async -> Bool
    {
        guard self.isCurrentRoute(expectedRoute), let channel = self.channel else {
            return false
        }
        let params: [String: AnyCodable] = [
            "event": AnyCodable(event),
            "payloadJSON": AnyCodable(payloadJSON ?? NSNull()),
        ]
        do {
            try await channel.send(
                method: "node.event",
                params: params,
                ifCurrentConnectionGeneration: expectedRoute.socketGeneration)
            return self.isCurrentRoute(expectedRoute) && self.channel === channel
        } catch {
            self.logger.error("node event failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func send(method: String, paramsJSON: String?) async throws {
        guard let (channel, route) = self.activeRoute() else {
            throw NSError(domain: "Gateway", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "not connected",
            ])
        }

        let params = try self.decodeParamsJSON(paramsJSON)
        try await channel.send(
            method: method,
            params: params,
            ifCurrentConnectionGeneration: route.socketGeneration)
        guard self.isCurrentRoute(route), self.channel === channel
        else { throw CancellationError() }
    }

    public func send(
        method: String,
        paramsJSON: String?,
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute) async throws
    {
        guard self.isCurrentRoute(expectedRoute), let channel = self.channel else {
            throw CancellationError()
        }
        let params = try self.decodeParamsJSON(paramsJSON)
        try await channel.send(
            method: method,
            params: params,
            ifCurrentConnectionGeneration: expectedRoute.socketGeneration)
        guard self.isCurrentRoute(expectedRoute), self.channel === channel else {
            throw CancellationError()
        }
    }

    public func request(method: String, paramsJSON: String?, timeoutSeconds: Int = 15) async throws -> Data {
        guard let (channel, route) = self.activeRoute() else {
            throw NSError(domain: "Gateway", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "not connected",
            ])
        }

        let params = try self.decodeParamsJSON(paramsJSON)
        let data = try await channel.request(
            method: method,
            params: params,
            timeoutMs: Double(timeoutSeconds * 1000),
            ifCurrentConnectionGeneration: route.socketGeneration)
        guard self.isCurrentRoute(route), self.channel === channel
        else { throw CancellationError() }
        return data
    }

    public func request(
        method: String,
        paramsJSON: String?,
        timeoutSeconds: Int = 15,
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute) async throws -> Data
    {
        guard self.isCurrentRoute(expectedRoute), let channel = self.channel else {
            throw CancellationError()
        }
        let params = try self.decodeParamsJSON(paramsJSON)
        let data = try await channel.request(
            method: method,
            params: params,
            timeoutMs: Double(timeoutSeconds * 1000),
            ifCurrentConnectionGeneration: expectedRoute.socketGeneration)
        guard self.isCurrentRoute(expectedRoute), self.channel === channel else {
            throw CancellationError()
        }
        return data
    }

    public func requestTrackingDispatch(
        method: String,
        paramsJSON: String?,
        timeoutSeconds: Int = 15,
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute) async -> GatewayRequestDispatchResult
    {
        guard self.isCurrentRoute(expectedRoute), let channel = self.channel else {
            return .notDispatched
        }
        let params: [String: AnyCodable]?
        do {
            params = try self.decodeParamsJSON(paramsJSON)
        } catch {
            return .notDispatched
        }
        return await channel.requestTrackingDispatch(
            method: method,
            params: params,
            timeoutMs: Double(timeoutSeconds * 1000),
            ifCurrentConnectionGeneration: expectedRoute.socketGeneration)
    }

    public func subscribeServerEvents(bufferingNewest: Int = 200) -> AsyncStream<EventFrame> {
        let id = UUID()
        let session = self
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferingNewest)) { continuation in
            self.serverEventSubscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await session.removeServerEventSubscriber(id) }
            }
        }
    }

    private func handlePush(
        _ push: GatewayPush,
        channelGeneration: UInt64,
        socketGeneration: UInt64) async
    {
        #if DEBUG
        await self.testBeforePushAdmission?()
        #endif
        // Existing-route events remain live while owner setup runs. A replacement
        // socket, however, cannot be admitted until all older lifecycle work settles.
        if self.activeSocketGeneration != socketGeneration {
            await self.waitForLifecycleCallbacksIfNeeded()
        }
        let isNewSocketAdmission = self.activeSocketGeneration == nil
        guard self.channelGeneration == channelGeneration,
              self.admitSocketGeneration(socketGeneration)
        else { return }
        if isNewSocketAdmission {
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .route,
                state: "admitted",
                socketGeneration: socketGeneration,
                routeGeneration: self.admissionGeneration))
        }
        switch push {
        case let .snapshot(ok):
            let admissionGeneration = self.admissionGeneration
            guard let channel = self.channel else { return }
            let route = GatewayNodeSessionRoute(
                channelGeneration: channelGeneration,
                admissionGeneration: admissionGeneration,
                socketGeneration: socketGeneration)
            let connectionReceipt = await channel.bootstrapHandoffConnectionReceipt(
                ifCurrentConnectionGeneration: socketGeneration)
            guard self.channelGeneration == channelGeneration,
                  self.admissionGeneration == admissionGeneration,
                  self.channel === channel,
                  self.isCurrentRoute(route)
            else { return }
            if let connectionReceipt {
                self.activeBootstrapToken = nil
                self.routeBoundBootstrapHandoffReceipt = RouteBoundBootstrapHandoffReceipt(
                    route: route,
                    receipt: GatewayBootstrapHandoffReceipt(
                        channelGeneration: route.channelGeneration,
                        routeGeneration: route.admissionGeneration,
                        physicalConnectionGeneration: route.socketGeneration,
                        issuedRoles: connectionReceipt.issuedRoles,
                        issues: connectionReceipt.issues,
                        persistence: connectionReceipt.persistence))
            }
            self.pluginSurfaceUrls = self.normalizePluginSurfaceUrls(ok.pluginsurfaceurls)
            self.serverCapabilities = ok.advertisedServerCapabilities
            self.serverCapabilityNames = ok.advertisedServerCapabilityNames
            self.authenticatedOperatorScopes = ok.authenticatedOperatorScopes
            let supportsRoutingGuard = self.serverCapabilities?.contains(.chatSendRoutingContract) == true
            let hasOperatorRead = self.authenticatedOperatorScopes?.contains("operator.read") == true
            let hasOperatorWrite = self.authenticatedOperatorScopes?.contains("operator.write") == true
            let gatewayVersion = Self.diagnosticGatewayVersion(ok.server["version"]?.value as? String)
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .route,
                state: Self.diagnosticHelloState(
                    supportsRoutingGuard: supportsRoutingGuard,
                    hasRequiredOperatorScopes: hasOperatorRead && hasOperatorWrite),
                socketGeneration: socketGeneration,
                routeGeneration: admissionGeneration,
                sequence: ok._protocol,
                stream: gatewayVersion))
            if self.hasEverConnected {
                self.broadcastServerEvent(
                    EventFrame(type: "event", event: "seqGap", payload: nil, seq: nil, stateversion: nil))
            }
            self.hasEverConnected = true
            self.markSnapshotReceived()
            await self.notifyConnectedIfNeeded(admissionGeneration: admissionGeneration)
        case let .event(evt):
            guard let channel = self.channel else { return }
            let route = GatewayNodeSessionRoute(
                channelGeneration: channelGeneration,
                admissionGeneration: self.admissionGeneration,
                socketGeneration: socketGeneration)
            await self.handleEvent(evt, channel: channel, route: route)
        default:
            break
        }
    }

    private nonisolated static func diagnosticGatewayVersion(_ value: String?) -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty, normalized.count <= 64 else { return "redacted" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_+"))
        return normalized.unicodeScalars.allSatisfy { allowed.contains($0) } ? normalized : "redacted"
    }

    nonisolated static func diagnosticHelloState(
        supportsRoutingGuard: Bool,
        hasRequiredOperatorScopes: Bool) -> String
    {
        switch (supportsRoutingGuard, hasRequiredOperatorScopes) {
        case (true, true): "hello_s3_ready"
        case (false, true): "hello_s3_capability_missing"
        case (true, false): "hello_s3_scope_missing"
        case (false, false): "hello_s3_capability_scope_missing"
        }
    }

    private func resetConnectionState() {
        self.hasNotifiedConnected = false
        self.snapshotReceived = false
        self.serverCapabilities = nil
        self.serverCapabilityNames = nil
        self.authenticatedOperatorScopes = nil
        self.routeBoundBootstrapHandoffReceipt = nil
        self.drainSnapshotWaiters(returning: .invalidated)
    }

    private func handleChannelDisconnected(
        _ reason: String,
        channelGeneration: UInt64,
        socketGeneration: UInt64) async
    {
        guard self.channelGeneration == channelGeneration,
              self.retireSocketGeneration(socketGeneration)
        else { return }
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .route,
            state: "retired",
            socketGeneration: socketGeneration,
            routeGeneration: self.admissionGeneration))
        self.admissionGeneration &+= 1
        let onDisconnected = self.onDisconnected
        // The underlying channel can auto-reconnect; resetting state here ensures we surface a fresh
        // onConnected callback once a new snapshot arrives after reconnect.
        self.resetConnectionState()
        if let onDisconnected {
            _ = self.enqueueLifecycleCallback {
                await onDisconnected(reason)
            }
        }
    }

    private func markSnapshotReceived() {
        self.snapshotReceived = true
        self.drainSnapshotWaiters(returning: .ready)
    }

    private func waitForSnapshot(
        timeoutMs: Int,
        channel: GatewayChannelActor,
        channelGeneration: UInt64,
        admissionGeneration: UInt64,
        socketGeneration: UInt64) async -> SnapshotWaitResult
    {
        if self.snapshotReceived { return .ready }
        let clamped = max(0, timeoutMs)
        let waiterID = UUID()
        return await withCheckedContinuation { cont in
            self.snapshotWaiters[waiterID] = SnapshotWaiter(
                channel: channel,
                channelGeneration: channelGeneration,
                admissionGeneration: admissionGeneration,
                socketGeneration: socketGeneration,
                continuation: cont)
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
                await self.timeoutSnapshotWaiter(id: waiterID)
            }
        }
    }

    private func timeoutSnapshotWaiter(id: UUID) {
        guard !self.snapshotReceived,
              let waiter = self.snapshotWaiters.removeValue(forKey: id)
        else { return }

        guard self.channelGeneration == waiter.channelGeneration,
              self.admissionGeneration == waiter.admissionGeneration,
              self.channel === waiter.channel
        else {
            waiter.continuation.resume(returning: .invalidated)
            return
        }

        // Close the snapshot admission and detach its route in this actor turn
        // before resuming connect(). A snapshot already queued behind this turn
        // carries the retired channel generation and is rejected by handlePush.
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .route,
            state: "retired",
            socketGeneration: waiter.socketGeneration,
            routeGeneration: waiter.admissionGeneration))
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .reconnect,
            state: "snapshot_timeout",
            socketGeneration: waiter.socketGeneration,
            routeGeneration: waiter.admissionGeneration))
        self.channelGeneration &+= 1
        self.admissionGeneration &+= 1
        self.channel = nil
        self.activeURL = nil
        self.activeToken = nil
        self.activeBootstrapToken = nil
        self.activePassword = nil
        self.activeConnectOptionsKey = nil
        self.activeSessionIdentity = nil
        self.connectOptions = nil
        self.onConnected = nil
        self.onConnectedRoute = nil
        self.onDisconnected = nil
        self.onInvoke = nil
        self.activeSocketGeneration = nil
        self.lastRetiredSocketGeneration = nil
        self.hasEverConnected = false
        self.hasNotifiedConnected = false
        self.snapshotReceived = false
        self.drainSnapshotWaiters(returning: .invalidated)
        waiter.continuation.resume(returning: .timedOut)
    }

    private func drainSnapshotWaiters(returning value: SnapshotWaitResult) {
        if !self.snapshotWaiters.isEmpty {
            let waiters = self.snapshotWaiters.values
            self.snapshotWaiters.removeAll()
            for waiter in waiters {
                waiter.continuation.resume(returning: value)
            }
        }
    }

    private func notifyConnectedIfNeeded(admissionGeneration: UInt64) async {
        guard admissionGeneration == self.admissionGeneration else { return }
        if self.hasNotifiedConnected {
            // Snapshot delivery and connect() can race to this method. Join the one
            // serialized callback unless this call originated from that callback.
            await self.waitForLifecycleCallbacksIfNeeded()
            return
        }
        self.hasNotifiedConnected = true
        guard let (_, route) = self.activeRoute(),
              route.admissionGeneration == admissionGeneration
        else { return }
        let onConnected = self.onConnected
        let onConnectedRoute = self.onConnectedRoute
        guard onConnected != nil || onConnectedRoute != nil else { return }
        let callback = self.enqueueLifecycleCallback {
            if let onConnectedRoute {
                await onConnectedRoute(route)
            } else if let onConnected {
                await onConnected()
            }
        }
        if !self.isExecutingLifecycleCallback() {
            await callback.task.value
        }
    }

    private func enqueueLifecycleCallback(
        final: @escaping @Sendable () async -> Void) -> LifecycleCallbackBarrier
    {
        let previous = self.lifecycleCallbackBarrier?.task
        let id = UUID()
        self.executingLifecycleCallbackIDs.insert(id)
        let task = Task { [weak self] in
            await Self.$executingLifecycleCallbackID.withValue(id) {
                await previous?.value
                await final()
            }
            await self?.finishLifecycleCallback(id)
        }
        let barrier = LifecycleCallbackBarrier(id: id, task: task)
        self.lifecycleCallbackBarrier = barrier
        return barrier
    }

    private func finishLifecycleCallback(_ id: UUID) {
        self.executingLifecycleCallbackIDs.remove(id)
        guard self.lifecycleCallbackBarrier?.id == id else { return }
        self.lifecycleCallbackBarrier = nil
    }

    private func isExecutingLifecycleCallback() -> Bool {
        guard let id = Self.executingLifecycleCallbackID else { return false }
        return self.executingLifecycleCallbackIDs.contains(id)
    }

    private func waitForLifecycleCallbacksIfNeeded() async {
        guard !self.isExecutingLifecycleCallback() else { return }
        while let callback = self.lifecycleCallbackBarrier {
            await callback.task.value
        }
    }

    private func normalizeCanvasHostUrl(_ raw: String?) -> String? {
        canonicalizeCanvasHostUrl(raw: raw, activeURL: self.activeURL)
    }

    private func normalizePluginSurfaceUrls(_ raw: [String: AnyCodable]?) -> [String: String] {
        var normalized: [String: String] = [:]
        if let raw {
            normalized = raw.compactMapValues { value in
                self.normalizeCanvasHostUrl(value.value as? String)
            }
        }
        return normalized
    }

    private func requestPluginSurfaceRefresh(
        channel: GatewayChannelActor,
        method: String,
        params: [String: AnyCodable]?,
        surface: String,
        timeoutSeconds: Int,
        route: GatewayNodeSessionRoute) async -> String?
    {
        do {
            let data = try await channel.request(
                method: method,
                params: params,
                timeoutMs: Double(timeoutSeconds * 1000),
                ifCurrentConnectionGeneration: route.socketGeneration)
            guard self.isCurrentRoute(route), self.channel === channel
            else { return nil }
            let decoded = try self.decoder.decode(PluginSurfaceRefreshResponse.self, from: data)
            let urls = self.normalizePluginSurfaceUrls(decoded.pluginSurfaceUrls)
            guard let refreshed = urls[surface] else { return nil }
            self.pluginSurfaceUrls[surface] = refreshed
            return refreshed
        } catch {
            self.logger.debug("\(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func handleEvent(
        _ evt: EventFrame,
        channel: GatewayChannelActor,
        route: GatewayNodeSessionRoute) async
    {
        guard self.isCurrentRoute(route), self.channel === channel else { return }
        self.broadcastServerEvent(evt)
        guard evt.event == "node.invoke.request" else { return }
        self.logger.info("node invoke request received")
        guard let payload = evt.payload else { return }
        do {
            let request = try self.decodeInvokeRequest(from: payload)
            let timeoutLabel = request.timeoutMs.map(String.init) ?? "none"
            self.logger.info(
                "node invoke request decoded id=\(request.id, privacy: .public) command=\(request.command, privacy: .public) timeoutMs=\(timeoutLabel, privacy: .public)")
            guard let onInvoke else { return }
            let req = BridgeInvokeRequest(
                id: request.id,
                command: request.command,
                paramsJSON: request.paramsJSON,
                nodeId: request.nodeId)
            self.logger.info("node invoke executing id=\(request.id, privacy: .public)")
            let response = await Self.invokeWithTimeout(
                request: req,
                timeoutMs: request.timeoutMs,
                onInvoke: onInvoke)
            // Native work belongs to the socket that requested it. A replacement route
            // discards the result instead of sending it through the new gateway.
            guard self.isCurrentRoute(route), self.channel === channel else { return }
            self.logger.info(
                "node invoke completed id=\(request.id, privacy: .public) ok=\(response.ok, privacy: .public)")
            await self.sendInvokeResult(
                request: request,
                response: response,
                channel: channel,
                socketGeneration: route.socketGeneration)
        } catch {
            self.logger.error("node invoke decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decodeInvokeRequest(from payload: OpenClawProtocol.AnyCodable) throws -> NodeInvokeRequestPayload {
        do {
            let data = try self.encoder.encode(payload)
            return try self.decoder.decode(NodeInvokeRequestPayload.self, from: data)
        } catch {
            if let raw = payload.value as? String, let data = raw.data(using: .utf8) {
                return try self.decoder.decode(NodeInvokeRequestPayload.self, from: data)
            }
            throw error
        }
    }

    private func sendInvokeResult(
        request: NodeInvokeRequestPayload,
        response: BridgeInvokeResponse,
        channel: GatewayChannelActor,
        socketGeneration: UInt64) async
    {
        self.logger.info(
            "node invoke result sending id=\(request.id, privacy: .public) ok=\(response.ok, privacy: .public)")
        var params: [String: AnyCodable] = [
            "id": AnyCodable(request.id),
            "nodeId": AnyCodable(request.nodeId),
            "ok": AnyCodable(response.ok),
        ]
        if let payloadJSON = response.payloadJSON {
            params["payloadJSON"] = AnyCodable(payloadJSON)
        }
        if let error = response.error {
            params["error"] = AnyCodable([
                "code": error.code.rawValue,
                "message": error.message,
            ])
        }
        do {
            try await channel.send(
                method: "node.invoke.result",
                params: params,
                ifCurrentConnectionGeneration: socketGeneration)
        } catch {
            self.logger.error(
                "node invoke result failed id=\(request.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func activeRoute() -> (GatewayChannelActor, GatewayNodeSessionRoute)? {
        guard let channel = self.channel,
              let socketGeneration = self.activeSocketGeneration
        else { return nil }
        return (
            channel,
            GatewayNodeSessionRoute(
                channelGeneration: self.channelGeneration,
                admissionGeneration: self.admissionGeneration,
                socketGeneration: socketGeneration))
    }

    public func isCurrentRoute(_ route: GatewayNodeSessionRoute) -> Bool {
        route.channelGeneration == self.channelGeneration &&
            route.admissionGeneration == self.admissionGeneration &&
            route.socketGeneration == self.activeSocketGeneration
    }

    private func admitSocketGeneration(_ socketGeneration: UInt64) -> Bool {
        if let lastRetiredSocketGeneration,
           socketGeneration <= lastRetiredSocketGeneration
        {
            return false
        }
        if let activeSocketGeneration {
            return socketGeneration == activeSocketGeneration
        }
        self.activeSocketGeneration = socketGeneration
        return true
    }

    private func retireSocketGeneration(_ socketGeneration: UInt64) -> Bool {
        if let lastRetiredSocketGeneration,
           socketGeneration <= lastRetiredSocketGeneration
        {
            return false
        }
        if let activeSocketGeneration,
           socketGeneration != activeSocketGeneration
        {
            return false
        }
        self.activeSocketGeneration = nil
        self.lastRetiredSocketGeneration = socketGeneration
        return true
    }

    private func decodeParamsJSON(
        _ paramsJSON: String?) throws -> [String: AnyCodable]?
    {
        guard let paramsJSON, !paramsJSON.isEmpty else { return nil }
        guard let data = paramsJSON.data(using: .utf8) else {
            throw NSError(domain: "Gateway", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "paramsJSON not UTF-8",
            ])
        }
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let dict = raw as? [String: Any] else {
            return nil
        }
        return dict.reduce(into: [:]) { acc, entry in
            acc[entry.key] = AnyCodable(entry.value)
        }
    }

    private func broadcastServerEvent(_ evt: EventFrame) {
        for (id, continuation) in self.serverEventSubscribers {
            if case .terminated = continuation.yield(evt) {
                self.serverEventSubscribers.removeValue(forKey: id)
            }
        }
    }

    private func removeServerEventSubscriber(_ id: UUID) {
        self.serverEventSubscribers.removeValue(forKey: id)
    }

    #if DEBUG
    // Package tests suspend a queued snapshot before admission to make its
    // timeout ordering deterministic. This hook is absent from release builds.
    func _test_setBeforePushAdmission(
        _ callback: (@Sendable () async -> Void)?)
    {
        self.testBeforePushAdmission = callback
    }
    #endif
}
