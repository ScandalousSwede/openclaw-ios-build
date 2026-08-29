import Foundation
import Testing
@testable import OpenClawKit
import OpenClawProtocol

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}

private final class DoubleCallbackPingWebSocketTask: WebSocketTasking, @unchecked Sendable {
    private let callbacks: [Error?]

    init(callbacks: [Error?]) {
        self.callbacks = callbacks
    }

    var state: URLSessionTask.State { .running }

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        _ = (closeCode, reason)
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        _ = message
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        for callback in self.callbacks {
            pongReceiveHandler(callback)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        throw URLError(.badServerResponse)
    }

    func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    {
        completionHandler(.failure(URLError(.badServerResponse)))
    }
}

private final class FakeGatewayWebSocketTask: WebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private let helloAuth: [String: Any]?
    private let helloCapabilities: [String]
    private let deliversReceiveFailureOnCancel: Bool
    private let requestSendGate: GatewayAsyncGate?
    private var _state: URLSessionTask.State = .suspended
    private var connectRequestId: String?
    private var connectAuth: [String: Any]?
    private var sentRequests: [[String: Any]] = []
    private var receivePhase = 0
    private var pendingReceiveHandler:
        (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

    init(
        helloAuth: [String: Any]? = nil,
        helloCapabilities: [String] = [],
        deliversReceiveFailureOnCancel: Bool = true,
        requestSendGate: GatewayAsyncGate? = nil)
    {
        self.helloAuth = helloAuth
        self.helloCapabilities = helloCapabilities
        self.deliversReceiveFailureOnCancel = deliversReceiveFailureOnCancel
        self.requestSendGate = requestSendGate
    }

    var state: URLSessionTask.State {
        get { self.lock.withLock { self._state } }
        set { self.lock.withLock { self._state = newValue } }
    }

    func resume() {
        self.state = .running
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        _ = (closeCode, reason)
        self.state = .canceling
        guard self.deliversReceiveFailureOnCancel else { return }
        let handler = self.lock.withLock { () -> (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? in
            defer { self.pendingReceiveHandler = nil }
            return self.pendingReceiveHandler
        }
        handler?(Result<URLSessionWebSocketTask.Message, Error>.failure(URLError(.cancelled)))
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data? = switch message {
        case let .data(d): d
        case let .string(s): s.data(using: .utf8)
        @unknown default: nil
        }
        guard let data else { return }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["type"] as? String == "req",
           let method = obj["method"] as? String,
           let id = obj["id"] as? String
        {
            self.lock.withLock {
                self.sentRequests.append(obj)
                if method == "connect" {
                    let auth = ((obj["params"] as? [String: Any])?["auth"] as? [String: Any]) ?? [:]
                    self.connectRequestId = id
                    self.connectAuth = auth
                }
            }
            if method != "connect" {
                await self.requestSendGate?.wait()
            }
        }
    }

    func latestConnectAuth() -> [String: Any]? {
        self.lock.withLock { self.connectAuth }
    }

    func latestConnectScopes() -> [String] {
        self.lock.withLock {
            guard let request = self.sentRequests.last(where: { $0["method"] as? String == "connect" }),
                  let params = request["params"] as? [String: Any]
            else { return [] }
            return params["scopes"] as? [String] ?? []
        }
    }

    func latestConnectDeviceID() -> String? {
        self.lock.withLock {
            guard let request = self.sentRequests.last(where: { $0["method"] as? String == "connect" }),
                  let params = request["params"] as? [String: Any],
                  let device = params["device"] as? [String: Any]
            else { return nil }
            return device["id"] as? String
        }
    }

    func sentRequestCount(method: String) -> Int {
        self.lock.withLock {
            self.sentRequests.filter { $0["method"] as? String == method }.count
        }
    }

    func latestRequestID(method: String) -> String? {
        self.lock.withLock {
            self.sentRequests.last(where: { $0["method"] as? String == method })?["id"] as? String
        }
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pongReceiveHandler(nil)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let phase = self.lock.withLock { () -> Int in
            let current = self.receivePhase
            self.receivePhase += 1
            return current
        }
        if phase == 0 {
            return .data(Self.connectChallengeData(nonce: "nonce-1"))
        }
        for _ in 0..<50 {
            let id = self.lock.withLock { self.connectRequestId }
            if let id {
                return .data(Self.connectOkData(
                    id: id,
                    auth: self.helloAuth,
                    capabilities: self.helloCapabilities))
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return .data(Self.connectOkData(
            id: "connect",
            auth: self.helloAuth,
            capabilities: self.helloCapabilities))
    }

    func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    {
        self.lock.withLock { self.pendingReceiveHandler = completionHandler }
    }

    func emitReceiveFailure() {
        let handler = self.lock.withLock { () -> (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? in
            self._state = .canceling
            defer { self.pendingReceiveHandler = nil }
            return self.pendingReceiveHandler
        }
        handler?(Result<URLSessionWebSocketTask.Message, Error>.failure(URLError(.networkConnectionLost)))
    }

    func hasPendingReceiveHandler() -> Bool {
        self.lock.withLock { self.pendingReceiveHandler != nil }
    }

    func emitEvent(name: String, seq: Int? = nil) throws {
        var frame: [String: Any] = [
            "type": "event",
            "event": name,
            "payload": [:],
        ]
        if let seq {
            frame["seq"] = seq
        }
        let data = try JSONSerialization.data(withJSONObject: frame)
        self.emit(.success(.data(data)))
    }

    func emitInvokeRequest(id: String, command: String) throws {
        let frame: [String: Any] = [
            "type": "event",
            "event": "node.invoke.request",
            "payload": [
                "id": id,
                "nodeId": "test-node",
                "command": command,
            ],
            "seq": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        self.emit(.success(.data(data)))
    }

    func emitResponse(id: String, payload: [String: Any] = [:]) throws {
        let frame: [String: Any] = [
            "type": "res",
            "id": id,
            "ok": true,
            "payload": payload,
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        self.emit(.success(.data(data)))
    }

    func emitErrorResponse(
        id: String,
        code: String,
        message: String,
        reason: String? = nil) throws
    {
        var error: [String: Any] = ["code": code, "message": message]
        if let reason {
            error["details"] = ["reason": reason]
        }
        let frame: [String: Any] = [
            "type": "res",
            "id": id,
            "ok": false,
            "error": error,
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        self.emit(.success(.data(data)))
    }

    private func emit(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        let handler = self.lock.withLock { () -> (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? in
            defer { self.pendingReceiveHandler = nil }
            return self.pendingReceiveHandler
        }
        handler?(result)
    }

    private static func connectChallengeData(nonce: String) -> Data {
        let frame: [String: Any] = [
            "type": "event",
            "event": "connect.challenge",
            "payload": ["nonce": nonce],
        ]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }

    private static func connectOkData(
        id: String,
        auth: [String: Any]? = nil,
        capabilities: [String] = []) -> Data
    {
        var payload: [String: Any] = [
            "type": "hello-ok",
            "protocol": 2,
            "server": [
                "version": "test",
                "connId": "test",
            ],
            "features": [
                "methods": [],
                "events": [],
                "capabilities": capabilities,
            ],
            "snapshot": [
                "presence": [["ts": 1]],
                "health": [:],
                "stateVersion": [
                    "presence": 0,
                    "health": 0,
                ],
                "uptimeMs": 0,
            ],
            "policy": [
                "maxPayload": 1,
                "maxBufferedBytes": 1,
                "tickIntervalMs": 30_000,
            ],
            "auth": [:],
        ]
        if let auth {
            payload["auth"] = auth
        }
        let frame: [String: Any] = [
            "type": "res",
            "id": id,
            "ok": true,
            "payload": payload,
        ]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }
}

private final class FakeGatewayWebSocketSession: WebSocketSessioning, @unchecked Sendable {
    private let lock = NSLock()
    private let helloAuth: [String: Any]?
    private let helloCapabilities: [String]
    private let deliversReceiveFailureOnCancel: Bool
    private let requestSendGate: GatewayAsyncGate?
    private var tasks: [FakeGatewayWebSocketTask] = []
    private var makeCount = 0

    init(
        helloAuth: [String: Any]? = nil,
        helloCapabilities: [String] = [],
        deliversReceiveFailureOnCancel: Bool = true,
        requestSendGate: GatewayAsyncGate? = nil)
    {
        self.helloAuth = helloAuth
        self.helloCapabilities = helloCapabilities
        self.deliversReceiveFailureOnCancel = deliversReceiveFailureOnCancel
        self.requestSendGate = requestSendGate
    }

    func snapshotMakeCount() -> Int {
        self.lock.withLock { self.makeCount }
    }

    func latestTask() -> FakeGatewayWebSocketTask? {
        self.lock.withLock { self.tasks.last }
    }

    func task(at index: Int) -> FakeGatewayWebSocketTask? {
        self.lock.withLock {
            guard self.tasks.indices.contains(index) else { return nil }
            return self.tasks[index]
        }
    }

    func makeWebSocketTask(url: URL) -> WebSocketTaskBox {
        _ = url
        return self.lock.withLock {
            self.makeCount += 1
            let task = FakeGatewayWebSocketTask(
                helloAuth: self.helloAuth,
                helloCapabilities: self.helloCapabilities,
                deliversReceiveFailureOnCancel: self.deliversReceiveFailureOnCancel,
                requestSendGate: self.requestSendGate)
            self.tasks.append(task)
            return WebSocketTaskBox(task: task)
        }
    }
}

private actor SeqGapProbe {
    private var saw = false
    func mark() { self.saw = true }
    func value() -> Bool { self.saw }
}

private actor GatewayEventProbe {
    private var names: [String] = []

    func append(_ name: String) {
        self.names.append(name)
    }

    func contains(_ name: String) -> Bool {
        self.names.contains(name)
    }
}

private actor StringProbe {
    private var values: [String] = []

    func append(_ value: String) {
        self.values.append(value)
    }

    func snapshot() -> [String] {
        self.values
    }
}

private final class DiagnosticLineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        self.lock.withLock { self.values.append(value) }
    }

    func snapshot() -> [String] {
        self.lock.withLock { self.values }
    }
}

private actor GatewayAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var started = false

    func wait() async {
        self.started = true
        if self.released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        self.started
    }

    func release() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}

private func generationTestOptions(
    scopes: [String] = ["operator.read"],
    stableGatewayID: String? = nil) -> GatewayConnectOptions
{
    GatewayConnectOptions(
        role: "operator",
        scopes: scopes,
        caps: [],
        commands: [],
        permissions: [:],
        clientId: "openclaw-ios-generation-test",
        clientMode: "ui",
        clientDisplayName: "iOS Generation Test",
        stableGatewayID: stableGatewayID,
        includeDeviceIdentity: false)
}

private func connectForGenerationTest(
    _ gateway: GatewayNodeSession,
    session: FakeGatewayWebSocketSession,
    endpoint: String,
    options: GatewayConnectOptions = generationTestOptions(),
    onConnected: @escaping @Sendable () async -> Void = {},
    onDisconnected: @escaping @Sendable (String) async -> Void = { _ in },
    onInvoke: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse = { request in
        BridgeInvokeResponse(id: request.id, ok: true, payloadJSON: nil, error: nil)
    }) async throws
{
    try await gateway.connect(
        url: URL(string: endpoint)!,
        token: nil,
        bootstrapToken: nil,
        password: nil,
        connectOptions: options,
        sessionBox: WebSocketSessionBox(session: session),
        onConnected: onConnected,
        onDisconnected: onDisconnected,
        onInvoke: onInvoke)
}

@Suite(.serialized)
struct GatewayNodeSessionTests {
    @Test
    func websocketPingIgnoresDuplicateSuccessCallbacks() async throws {
        let task = DoubleCallbackPingWebSocketTask(callbacks: [nil, nil])
        try await WebSocketTaskBox(task: task).sendPing()
    }

    @Test
    func websocketPingIgnoresDuplicateCallbacksAfterFirstError() async throws {
        let firstError = URLError(.networkConnectionLost)
        let task = DoubleCallbackPingWebSocketTask(callbacks: [firstError, nil])

        do {
            try await WebSocketTaskBox(task: task).sendPing()
            Issue.record("sendPing unexpectedly succeeded")
        } catch let error as URLError {
            #expect(error.code == firstError.code)
        }
    }

    @Test
    func legacyGatewayChannelCallbackInitializerRemainsSourceCompatible() async {
        let session = FakeGatewayWebSocketSession()
        let channel = GatewayChannelActor(
            url: URL(string: "ws://example.invalid")!,
            token: nil,
            session: WebSocketSessionBox(session: session),
            pushHandler: { _ in },
            connectOptions: generationTestOptions(),
            disconnectHandler: { _ in })

        await channel.shutdown()
    }

    @Test
    func scannedSetupCodePrefersBootstrapAuthOverStoredDeviceToken() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let previousStateDir = ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"]
        setenv("OPENCLAW_STATE_DIR", tempDir.path, 1)
        defer {
            if let previousStateDir {
                setenv("OPENCLAW_STATE_DIR", previousStateDir, 1)
            } else {
                unsetenv("OPENCLAW_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let identity = DeviceIdentityStore.loadOrCreate()
        _ = DeviceAuthStore.storeToken(
            deviceId: identity.deviceId,
            role: "operator",
            token: "stored-device-token")

        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let options = GatewayConnectOptions(
            role: "operator",
            scopes: ["operator.read"],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios-test",
            clientMode: "ui",
            clientDisplayName: "iOS Test",
            includeDeviceIdentity: true)

        try await gateway.connect(
            url: URL(string: "ws://example.invalid")!,
            token: nil,
            bootstrapToken: "fresh-bootstrap-token",
            password: nil,
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: session),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { req in
                BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: nil, error: nil)
            })

        let auth = try #require(session.latestTask()?.latestConnectAuth())
        #expect(auth["bootstrapToken"] as? String == "fresh-bootstrap-token")
        #expect(auth["token"] == nil)
        #expect(auth["deviceToken"] == nil)

        await gateway.disconnect()
    }

    @Test
    func historicalIdentityAndRoleTokenReconnectWithoutPairingOrRewrite() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let identityDirectory = tempDir.appendingPathComponent("identity", isDirectory: true)
        try FileManager.default.createDirectory(
            at: identityDirectory,
            withIntermediateDirectories: true)
        let previousStateDir = ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"]
        setenv("OPENCLAW_STATE_DIR", tempDir.path, 1)
        defer {
            if let previousStateDir {
                setenv("OPENCLAW_STATE_DIR", previousStateDir, 1)
            } else {
                unsetenv("OPENCLAW_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: tempDir)
        }

        // These version-1 fixture bytes use the original iOS identity/auth
        // schema introduced before the paired fork, not current store writers.
        let expectedDeviceID = "56475aa75463474c0285df5dbf2bcab73da651358839e9b77481b2eab107708c"
        let identityURL = identityDirectory.appendingPathComponent("device.json", isDirectory: false)
        let authURL = identityDirectory.appendingPathComponent("device-auth.json", isDirectory: false)
        let historicalIdentity = """
            {
              "createdAtMs": 1700000000000,
              "deviceId": "\(expectedDeviceID)",
              "privateKey": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
              "publicKey": "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
            }
            """
        let historicalAuth = """
            {
              "deviceId": "\(expectedDeviceID)",
              "tokens": {
                "node": {
                  "role": "node",
                  "scopes": [],
                  "token": "preserved-paired-node-token",
                  "updatedAtMs": 1700000000000
                }
              },
              "version": 1
            }
            """
        try Data(historicalIdentity.utf8).write(to: identityURL, options: .atomic)
        try Data(historicalAuth.utf8).write(to: authURL, options: .atomic)
        let identityBytes = try Data(contentsOf: identityURL)
        let authBytes = try Data(contentsOf: authURL)

        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let options = GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios-continuity-test",
            clientMode: "node",
            clientDisplayName: "iOS Continuity Test",
            includeDeviceIdentity: true)

        try await gateway.connect(
            url: URL(string: "wss://example.invalid")!,
            token: nil,
            bootstrapToken: nil,
            password: nil,
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: session),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { request in
                BridgeInvokeResponse(id: request.id, ok: true, payloadJSON: nil, error: nil)
            })

        let task = try #require(session.latestTask())
        let auth = try #require(task.latestConnectAuth())
        #expect(auth["token"] as? String == "preserved-paired-node-token")
        #expect(auth["bootstrapToken"] == nil)
        #expect(auth["password"] == nil)
        #expect(task.latestConnectDeviceID() == expectedDeviceID)
        #expect(try Data(contentsOf: identityURL) == identityBytes)
        #expect(try Data(contentsOf: authURL) == authBytes)

        await gateway.disconnect()
    }

    @Test
    func passwordTakesPrecedenceOverBootstrapToken() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let options = GatewayConnectOptions(
            role: "operator",
            scopes: ["operator.read"],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios-test",
            clientMode: "ui",
            clientDisplayName: "iOS Test",
            includeDeviceIdentity: false)

        try await gateway.connect(
            url: URL(string: "ws://example.invalid")!,
            token: nil,
            bootstrapToken: "stale-bootstrap-token",
            password: "shared-password",
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: session),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { req in
                BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: nil, error: nil)
            })

        let auth = try #require(session.latestTask()?.latestConnectAuth())
        #expect(auth["password"] as? String == "shared-password")
        #expect(auth["bootstrapToken"] == nil)
        #expect(auth["token"] == nil)

        await gateway.disconnect()
    }

    @Test
    func changedSessionBoxRebuildsExistingGatewayChannel() async throws {
        let firstSession = FakeGatewayWebSocketSession()
        let secondSession = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let options = GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios-test",
            clientMode: "node",
            clientDisplayName: "iOS Test",
            includeDeviceIdentity: false)

        try await gateway.connect(
            url: URL(string: "wss://example.invalid")!,
            token: "shared-token",
            bootstrapToken: nil,
            password: nil,
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: firstSession),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { req in
                BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: nil, error: nil)
            })

        try await gateway.connect(
            url: URL(string: "wss://example.invalid")!,
            token: "shared-token",
            bootstrapToken: nil,
            password: nil,
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: secondSession),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { req in
                BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: nil, error: nil)
            })

        #expect(firstSession.snapshotMakeCount() == 1)
        #expect(secondSession.snapshotMakeCount() == 1)

        await gateway.disconnect()
    }

    @Test
    func lateEventFromReplacedChannelIsIgnored() async throws {
        let firstSession = FakeGatewayWebSocketSession(deliversReceiveFailureOnCancel: false)
        let secondSession = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let probe = GatewayEventProbe()
        let events = await gateway.subscribeServerEvents(bufferingNewest: 32)
        let listener = Task {
            for await event in events {
                await probe.append(event.event)
            }
        }
        defer { listener.cancel() }

        try await connectForGenerationTest(
            gateway,
            session: firstSession,
            endpoint: "ws://first.example.invalid")
        let firstTask = try #require(firstSession.latestTask())
        try await connectForGenerationTest(
            gateway,
            session: secondSession,
            endpoint: "ws://second.example.invalid")
        let secondTask = try #require(secondSession.latestTask())

        try firstTask.emitEvent(name: "old.route.event", seq: 1)
        try secondTask.emitEvent(name: "current.route.event", seq: 1)
        try await waitUntil("current route event delivered") {
            await probe.contains("current.route.event")
        }
        #expect(await probe.contains("old.route.event") == false)

        await gateway.disconnect()
    }

    @Test
    func lateFailureFromReplacedChannelCannotDisconnectCurrentRoute() async throws {
        let firstSession = FakeGatewayWebSocketSession(deliversReceiveFailureOnCancel: false)
        let secondSession = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let disconnects = StringProbe()

        try await connectForGenerationTest(
            gateway,
            session: firstSession,
            endpoint: "ws://first.example.invalid",
            onDisconnected: { _ in await disconnects.append("first") })
        let firstTask = try #require(firstSession.latestTask())
        try await connectForGenerationTest(
            gateway,
            session: secondSession,
            endpoint: "ws://second.example.invalid",
            onDisconnected: { _ in await disconnects.append("second") })
        let secondTask = try #require(secondSession.latestTask())
        let currentRoute = try #require(await gateway.currentRoute())
        let currentRequest = Task {
            try await gateway.request(method: "health", paramsJSON: nil)
        }
        try await waitUntil("current route request admitted") {
            secondTask.latestRequestID(method: "health") != nil
        }
        let currentRequestID = try #require(secondTask.latestRequestID(method: "health"))

        firstTask.emitReceiveFailure()
        try secondTask.emitResponse(id: currentRequestID, payload: ["status": "ok"])
        _ = try await currentRequest.value

        #expect(await gateway.currentRoute() == currentRoute)
        #expect(await disconnects.snapshot().isEmpty)

        await gateway.disconnect()
    }

    @Test
    func ordinaryRequestSuspendedAcrossReplacementNeverDispatchesOnNewChannel() async throws {
        let sendGate = GatewayAsyncGate()
        let firstSession = FakeGatewayWebSocketSession(
            deliversReceiveFailureOnCancel: false,
            requestSendGate: sendGate)
        let secondSession = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()

        try await connectForGenerationTest(
            gateway,
            session: firstSession,
            endpoint: "ws://first.example.invalid")
        let request = Task {
            try await gateway.request(method: "sessions.list", paramsJSON: nil)
        }
        try await waitUntil("ordinary request suspended on first socket") {
            await sendGate.hasStarted()
        }

        try await connectForGenerationTest(
            gateway,
            session: secondSession,
            endpoint: "ws://second.example.invalid")
        let secondTask = try #require(secondSession.latestTask())
        await sendGate.release()

        do {
            _ = try await request.value
            Issue.record("ordinary request unexpectedly survived route replacement")
        } catch {
            // Expected: the ordinary operation retained its admitted socket lease.
        }
        #expect(secondTask.sentRequestCount(method: "sessions.list") == 0)

        await gateway.disconnect()
    }

    @Test
    func replacementWaitsForSuspendedConnectedCallbackBeforeAdmission() async throws {
        let firstSession = FakeGatewayWebSocketSession(deliversReceiveFailureOnCancel: false)
        let secondSession = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let connectedGate = GatewayAsyncGate()
        let lifecycle = StringProbe()

        let firstConnect = Task {
            try await connectForGenerationTest(
                gateway,
                session: firstSession,
                endpoint: "ws://first.example.invalid",
                onConnected: {
                    await lifecycle.append("first_connected_start")
                    await connectedGate.wait()
                    await lifecycle.append("first_connected_end")
                })
        }
        try await waitUntil("first connected callback suspended") {
            await connectedGate.hasStarted()
        }

        let secondConnect = Task {
            try await connectForGenerationTest(
                gateway,
                session: secondSession,
                endpoint: "ws://second.example.invalid",
                onConnected: {
                    await lifecycle.append("second_connected")
                })
        }
        try await waitUntil("first route invalidated by replacement") {
            await gateway.currentRoute() == nil
        }

        #expect(secondSession.snapshotMakeCount() == 0)
        #expect(await lifecycle.snapshot() == ["first_connected_start"])
        #expect(await gateway.currentRoute() == nil)

        await connectedGate.release()
        do {
            try await firstConnect.value
            Issue.record("superseded first connect unexpectedly succeeded")
        } catch {
            // Expected: the first connect lost its route while its callback was suspended.
        }
        try await secondConnect.value

        #expect(await lifecycle.snapshot() == [
            "first_connected_start",
            "first_connected_end",
            "second_connected",
        ])
        #expect(await gateway.currentRoute() != nil)

        await gateway.disconnect()
    }

    @Test
    func reconnectAdmissionWaitsForSuspendedDisconnectedCallback() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let disconnectedGate = GatewayAsyncGate()
        let lifecycle = StringProbe()

        try await connectForGenerationTest(
            gateway,
            session: session,
            endpoint: "ws://example.invalid",
            onConnected: {
                await lifecycle.append("connected")
            },
            onDisconnected: { _ in
                await lifecycle.append("disconnected_start")
                await disconnectedGate.wait()
                await lifecycle.append("disconnected_end")
            })
        let firstTask = try #require(session.latestTask())
        firstTask.emitReceiveFailure()

        try await waitUntil("disconnected callback suspended") {
            await disconnectedGate.hasStarted()
        }
        try await waitUntil("replacement physical socket created") {
            session.snapshotMakeCount() >= 2
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(await lifecycle.snapshot() == ["connected", "disconnected_start"])
        #expect(await gateway.currentRoute() == nil)

        await disconnectedGate.release()
        try await waitUntil("replacement lifecycle callback completed") {
            await lifecycle.snapshot() == [
                "connected",
                "disconnected_start",
                "disconnected_end",
                "connected",
            ]
        }
        #expect(await gateway.currentRoute() != nil)

        await gateway.disconnect()
    }

    #if DEBUG
    @Test
    func snapshotTimeoutClosesAdmissionBeforeQueuedSnapshot() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let snapshotGate = GatewayAsyncGate()
        let lifecycle = StringProbe()

        await gateway._test_setBeforePushAdmission {
            await snapshotGate.wait()
        }
        let connect = Task {
            do {
                try await connectForGenerationTest(
                    gateway,
                    session: session,
                    endpoint: "ws://example.invalid",
                    onConnected: {
                        await lifecycle.append("connected")
                    })
                await lifecycle.append("connect_succeeded")
            } catch let error as NSError where error.domain == "Gateway" && error.code == 13 {
                await lifecycle.append("snapshot_timed_out")
            } catch is CancellationError {
                await lifecycle.append("connect_cancelled")
            } catch {
                await lifecycle.append("connect_failed")
            }
        }

        try await waitUntil("snapshot queued before admission") {
            await snapshotGate.hasStarted()
        }
        try await waitUntil("snapshot timeout closed route") {
            await lifecycle.snapshot() == ["snapshot_timed_out"]
        }
        #expect(await gateway.currentRoute() == nil)

        await gateway._test_setBeforePushAdmission(nil)
        await snapshotGate.release()
        await connect.value
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(await lifecycle.snapshot() == ["snapshot_timed_out"])
        #expect(await gateway.currentRoute() == nil)
        #expect(session.snapshotMakeCount() == 1)

        await gateway.disconnect()
    }
    #endif

    @Test
    func connectedCallbackSameConfigConnectFailsBeforePhysicalDispatch() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let lifecycle = StringProbe()

        try await connectForGenerationTest(
            gateway,
            session: session,
            endpoint: "ws://example.invalid",
            onConnected: {
                do {
                    try await connectForGenerationTest(
                        gateway,
                        session: session,
                        endpoint: "ws://example.invalid",
                        onConnected: {
                            await lifecycle.append("nested_connected")
                        })
                    await lifecycle.append("reentry_succeeded")
                } catch is CancellationError {
                    await lifecycle.append("reentry_cancelled")
                } catch {
                    await lifecycle.append("reentry_failed")
                }
            })

        #expect(await lifecycle.snapshot() == ["reentry_cancelled"])
        #expect(session.snapshotMakeCount() == 1)
        #expect(await gateway.currentRoute() != nil)

        await gateway.disconnect()
    }

    @Test
    func connectedCallbackRouteChangingConnectFailsBeforePhysicalDispatch() async throws {
        let firstSession = FakeGatewayWebSocketSession()
        let secondSession = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let lifecycle = StringProbe()

        try await connectForGenerationTest(
            gateway,
            session: firstSession,
            endpoint: "ws://first.example.invalid",
            onConnected: {
                do {
                    try await connectForGenerationTest(
                        gateway,
                        session: secondSession,
                        endpoint: "ws://second.example.invalid")
                    await lifecycle.append("replacement_succeeded")
                } catch is CancellationError {
                    await lifecycle.append("replacement_cancelled")
                } catch {
                    await lifecycle.append("replacement_failed")
                }
            })

        #expect(await lifecycle.snapshot() == ["replacement_cancelled"])
        #expect(firstSession.snapshotMakeCount() == 1)
        #expect(secondSession.snapshotMakeCount() == 0)
        #expect(await gateway.currentRoute() != nil)

        await gateway.disconnect()
    }

    @Test
    func connectedCallbackDisconnectInvalidatesOuterConnect() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let lifecycle = StringProbe()

        do {
            try await connectForGenerationTest(
                gateway,
                session: session,
                endpoint: "ws://example.invalid",
                onConnected: {
                    await lifecycle.append("disconnecting")
                    await gateway.disconnect()
                    await lifecycle.append("disconnected")
                })
            Issue.record("connect unexpectedly survived callback disconnect")
        } catch is CancellationError {
            await lifecycle.append("outer_cancelled")
        } catch {
            Issue.record("connect failed with unexpected error: \(error)")
        }

        try await waitUntil("callback disconnect and outer connect settled") {
            let events = await lifecycle.snapshot()
            return events.count == 3
        }
        let lifecycleEvents = await lifecycle.snapshot()
        #expect(lifecycleEvents.first == "disconnecting")
        #expect(lifecycleEvents.count == 3)
        #expect(Set(lifecycleEvents.dropFirst()) == Set([
            "disconnected",
            "outer_cancelled",
        ]))
        #expect(session.snapshotMakeCount() == 1)
        #expect(await gateway.currentRoute() == nil)
    }

    @Test
    func disconnectedCallbackSameConfigConnectFailsBeforePhysicalDispatch() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let lifecycle = StringProbe()

        try await connectForGenerationTest(
            gateway,
            session: session,
            endpoint: "ws://example.invalid",
            onDisconnected: { _ in
                do {
                    try await connectForGenerationTest(
                        gateway,
                        session: session,
                        endpoint: "ws://example.invalid")
                    await lifecycle.append("reentry_succeeded")
                } catch is CancellationError {
                    await lifecycle.append("reentry_cancelled")
                } catch {
                    await lifecycle.append("reentry_failed")
                }
            })
        let firstTask = try #require(session.latestTask())
        firstTask.emitReceiveFailure()

        try await waitUntil("same-config disconnected reentry rejected") {
            !(await lifecycle.snapshot()).isEmpty
        }
        await gateway.disconnect()

        #expect(await lifecycle.snapshot() == ["reentry_cancelled"])
        #expect(session.snapshotMakeCount() == 1)
    }

    @Test
    func staleRequestSuccessCannotCrossToReplacementChannel() async throws {
        let firstSession = FakeGatewayWebSocketSession(deliversReceiveFailureOnCancel: false)
        let secondSession = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()

        try await connectForGenerationTest(
            gateway,
            session: firstSession,
            endpoint: "ws://first.example.invalid")
        let firstTask = try #require(firstSession.latestTask())
        let oldRoute = try #require(await gateway.currentRoute())
        let staleRequest = Task {
            try await gateway.request(method: "sessions.list", paramsJSON: nil)
        }
        try await waitUntil("request admitted on first route") {
            firstTask.latestRequestID(method: "sessions.list") != nil
        }
        let staleRequestID = try #require(firstTask.latestRequestID(method: "sessions.list"))

        try await connectForGenerationTest(
            gateway,
            session: secondSession,
            endpoint: "ws://second.example.invalid")
        let secondTask = try #require(secondSession.latestTask())
        try firstTask.emitResponse(id: staleRequestID, payload: ["owner": "first"])
        do {
            _ = try await staleRequest.value
            Issue.record("stale request unexpectedly succeeded")
        } catch {
            // Expected: replacing the route retires the pending request.
        }

        let replacementRequest = Task {
            try await gateway.request(method: "sessions.list", paramsJSON: nil)
        }
        try await waitUntil("request admitted on replacement route") {
            secondTask.latestRequestID(method: "sessions.list") != nil
        }
        let replacementRequestID = try #require(secondTask.latestRequestID(method: "sessions.list"))
        try secondTask.emitResponse(id: replacementRequestID, payload: ["owner": "second"])
        let replacementData = try await replacementRequest.value
        let replacementPayload = try #require(
            JSONSerialization.jsonObject(with: replacementData) as? [String: Any])
        #expect(replacementPayload["owner"] as? String == "second")

        let replacementRequestCount = secondTask.sentRequestCount(method: "sessions.list")
        do {
            _ = try await gateway.request(
                method: "sessions.list",
                paramsJSON: nil,
                ifCurrentRoute: oldRoute)
            Issue.record("stale route unexpectedly dispatched through replacement channel")
        } catch {
            // Expected: route leases never follow the session's mutable current channel.
        }
        #expect(secondTask.sentRequestCount(method: "sessions.list") == replacementRequestCount)

        await gateway.disconnect()
    }

    @Test
    func invokeResultCannotCrossToReplacementChannel() async throws {
        let firstSession = FakeGatewayWebSocketSession(deliversReceiveFailureOnCancel: false)
        let secondSession = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let invokeGate = GatewayAsyncGate()

        try await connectForGenerationTest(
            gateway,
            session: firstSession,
            endpoint: "ws://first.example.invalid",
            onInvoke: { request in
                await invokeGate.wait()
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: true,
                    payloadJSON: "{}",
                    error: nil)
            })
        let firstTask = try #require(firstSession.latestTask())
        try firstTask.emitInvokeRequest(id: "invoke-first", command: "camera.snap")
        try await waitUntil("native invoke started") {
            await invokeGate.hasStarted()
        }

        try await connectForGenerationTest(
            gateway,
            session: secondSession,
            endpoint: "ws://second.example.invalid")
        let secondTask = try #require(secondSession.latestTask())
        await invokeGate.release()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(firstTask.sentRequestCount(method: "node.invoke.result") == 0)
        #expect(secondTask.sentRequestCount(method: "node.invoke.result") == 0)

        await gateway.disconnect()
    }

    @Test
    func rapidRouteReplacementConvergesToLatestChannel() async throws {
        let firstSession = FakeGatewayWebSocketSession(deliversReceiveFailureOnCancel: false)
        let secondSession = FakeGatewayWebSocketSession(deliversReceiveFailureOnCancel: false)
        let thirdSession = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let disconnects = StringProbe()

        try await connectForGenerationTest(
            gateway,
            session: firstSession,
            endpoint: "ws://first.example.invalid",
            onDisconnected: { _ in await disconnects.append("first") })
        let firstTask = try #require(firstSession.latestTask())
        try await connectForGenerationTest(
            gateway,
            session: secondSession,
            endpoint: "ws://second.example.invalid",
            onDisconnected: { _ in await disconnects.append("second") })
        let secondTask = try #require(secondSession.latestTask())
        try await connectForGenerationTest(
            gateway,
            session: thirdSession,
            endpoint: "ws://third.example.invalid",
            onDisconnected: { _ in await disconnects.append("third") })
        let thirdRoute = try #require(await gateway.currentRoute())

        firstTask.emitReceiveFailure()
        secondTask.emitReceiveFailure()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(await gateway.currentRoute() == thirdRoute)
        #expect(await disconnects.snapshot().isEmpty)

        await gateway.disconnect()
    }

    @Test
    func reconnectRetiresCapturedRouteBeforeReplacementDispatch() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()

        try await connectForGenerationTest(
            gateway,
            session: session,
            endpoint: "ws://example.invalid")
        let firstTask = try #require(session.latestTask())
        let oldRoute = try #require(await gateway.currentRoute())
        firstTask.emitReceiveFailure()

        try await waitUntil("replacement socket created") {
            session.snapshotMakeCount() >= 2
        }
        let replacementTask = try #require(session.latestTask())
        try await waitUntil("replacement route admitted") {
            guard let route = await gateway.currentRoute() else { return false }
            return route != oldRoute
        }

        do {
            _ = try await gateway.request(
                method: "sessions.list",
                paramsJSON: nil,
                ifCurrentRoute: oldRoute)
            Issue.record("retired route unexpectedly dispatched after reconnect")
        } catch {
            // Expected: in-place channel reconnects still advance the admission/socket route.
        }
        #expect(replacementTask.sentRequestCount(method: "sessions.list") == 0)

        await gateway.disconnect()
    }

    @Test
    func routeBindsStableGatewayHelloCapabilityAndAuthenticatedScopeUnion() async throws {
        let diagnostics = DiagnosticLineProbe()
        OpenClawDiagnosticRecorder.installSink { diagnostics.append($0) }
        defer { OpenClawDiagnosticRecorder.clearSink() }
        let session = FakeGatewayWebSocketSession(
            helloAuth: [
                "role": "operator",
                "scopes": ["operator.read", "operator.write", "operator.talk.secrets"],
            ],
            helloCapabilities: [
                GatewayServerCapability.chatSendRoutingContract.rawValue,
                "future-capability",
            ])
        let gateway = GatewayNodeSession()
        let options = generationTestOptions(
            scopes: ["operator.talk.secrets", "operator.write", "operator.read"],
            stableGatewayID: "gateway-a")

        try await connectForGenerationTest(
            gateway,
            session: session,
            endpoint: "ws://example.invalid",
            options: options)

        let route = try #require(await gateway.currentRoute(ifGatewayID: "gateway-a"))
        #expect(await gateway.currentRoute(ifGatewayID: "gateway-b") == nil)
        #expect(await gateway.currentGatewayID(ifCurrentRoute: route) == "gateway-a")
        #expect(await gateway.supportsServerCapability(
            .chatSendRoutingContract,
            ifCurrentRoute: route) == true)
        #expect(await gateway.serverCapabilities(ifCurrentRoute: route) == [
            "chat-send-routing-contract",
            "future-capability",
        ])
        #expect(await gateway.operatorScopes(ifCurrentRoute: route) == [
            "operator.read",
            "operator.talk.secrets",
            "operator.write",
        ])
        #expect(Set(try #require(session.latestTask()).latestConnectScopes()) == [
            "operator.read",
            "operator.talk.secrets",
            "operator.write",
        ])
        let helloDiagnostic = try #require(diagnostics.snapshot()
            .compactMap(OpenClawDiagnosticRecorder.decodeRecord)
            .first { $0.state == "hello_s3_ready" })
        #expect(helloDiagnostic.kind == .route)
        #expect(helloDiagnostic.socketGeneration != nil)
        #expect(helloDiagnostic.routeGeneration != nil)
        #expect(helloDiagnostic.sequence == 2)
        #expect(helloDiagnostic.stream == "test")

        await gateway.disconnect()
        #expect(await gateway.supportsServerCapability(
            .chatSendRoutingContract,
            ifCurrentRoute: route) == nil)
        #expect(await gateway.operatorScopes(ifCurrentRoute: route) == nil)
    }

    @Test
    func helloDiagnosticStateDistinguishesCapabilityAndScopeReadiness() {
        #expect(GatewayNodeSession.diagnosticHelloState(
            supportsRoutingGuard: true,
            hasRequiredOperatorScopes: true) == "hello_s3_ready")
        #expect(GatewayNodeSession.diagnosticHelloState(
            supportsRoutingGuard: false,
            hasRequiredOperatorScopes: true) == "hello_s3_capability_missing")
        #expect(GatewayNodeSession.diagnosticHelloState(
            supportsRoutingGuard: true,
            hasRequiredOperatorScopes: false) == "hello_s3_scope_missing")
        #expect(GatewayNodeSession.diagnosticHelloState(
            supportsRoutingGuard: false,
            hasRequiredOperatorScopes: false) == "hello_s3_capability_scope_missing")
    }

    @Test
    func trackedRequestReturnsResponseFromExactRoute() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        try await connectForGenerationTest(
            gateway,
            session: session,
            endpoint: "ws://example.invalid")
        let route = try #require(await gateway.currentRoute())
        let task = try #require(session.latestTask())

        let request = Task {
            await gateway.requestTrackingDispatch(
                method: "chat.send",
                paramsJSON: #"{"idempotencyKey":"raw-1"}"#,
                ifCurrentRoute: route)
        }
        try await waitUntil("tracked request physically dispatched") {
            task.latestRequestID(method: "chat.send") != nil
        }
        try task.emitResponse(
            id: try #require(task.latestRequestID(method: "chat.send")),
            payload: ["runId": "raw-1", "status": "started"])

        guard case let .response(data) = await request.value else {
            Issue.record("expected a tracked response")
            await gateway.disconnect()
            return
        }
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["runId"] as? String == "raw-1")
        await gateway.disconnect()
    }

    @Test
    func trackedRequestPreservesExplicitGatewayRejection() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        try await connectForGenerationTest(
            gateway,
            session: session,
            endpoint: "ws://example.invalid")
        let route = try #require(await gateway.currentRoute())
        let task = try #require(session.latestTask())

        let request = Task {
            await gateway.requestTrackingDispatch(
                method: "chat.send",
                paramsJSON: #"{"idempotencyKey":"raw-2"}"#,
                ifCurrentRoute: route)
        }
        try await waitUntil("tracked request physically dispatched") {
            task.latestRequestID(method: "chat.send") != nil
        }
        try task.emitErrorResponse(
            id: try #require(task.latestRequestID(method: "chat.send")),
            code: "INVALID_REQUEST",
            message: "session routing changed; review and retry",
            reason: "session-routing-changed")

        #expect(await request.value == .rejected(
            code: "INVALID_REQUEST",
            reason: "session-routing-changed"))
        await gateway.disconnect()
    }

    @Test
    func trackedRequestMakesPostAdmissionTransportLossAmbiguous() async throws {
        let sendGate = GatewayAsyncGate()
        let session = FakeGatewayWebSocketSession(requestSendGate: sendGate)
        let gateway = GatewayNodeSession()
        try await connectForGenerationTest(
            gateway,
            session: session,
            endpoint: "ws://example.invalid")
        let route = try #require(await gateway.currentRoute())
        let task = try #require(session.latestTask())

        let request = Task {
            await gateway.requestTrackingDispatch(
                method: "chat.send",
                paramsJSON: #"{"idempotencyKey":"raw-3"}"#,
                ifCurrentRoute: route)
        }
        try await waitUntil("tracked request began physical dispatch") {
            await sendGate.hasStarted()
        }
        task.emitReceiveFailure()
        let outcome = await request.value
        await sendGate.release()

        guard case .ambiguous = outcome else {
            Issue.record("post-admission loss must be ambiguous, got \(outcome)")
            await gateway.disconnect()
            return
        }
        await gateway.disconnect()
    }

    @Test
    func retiredRouteBeforePhysicalDispatchIsNotDispatched() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        try await connectForGenerationTest(
            gateway,
            session: session,
            endpoint: "ws://example.invalid")
        let route = try #require(await gateway.currentRoute())
        await gateway.disconnect()

        let outcome = await gateway.requestTrackingDispatch(
            method: "chat.send",
            paramsJSON: #"{"idempotencyKey":"raw-4"}"#,
            ifCurrentRoute: route)
        #expect(outcome == .notDispatched)
    }

    @Test
    func bootstrapHelloStoresAdditionalDeviceTokens() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let previousStateDir = ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"]
        setenv("OPENCLAW_STATE_DIR", tempDir.path, 1)
        defer {
            if let previousStateDir {
                setenv("OPENCLAW_STATE_DIR", previousStateDir, 1)
            } else {
                unsetenv("OPENCLAW_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let identity = DeviceIdentityStore.loadOrCreate()
        let session = FakeGatewayWebSocketSession(helloAuth: [
            "deviceToken": "node-device-token",
            "role": "node",
            "scopes": [],
            "issuedAtMs": 1000,
            "deviceTokens": [
                [
                    "deviceToken": "operator-device-token",
                    "role": "operator",
                    "scopes": [
                        "node.exec",
                        "operator.admin",
                        "operator.approvals",
                        "operator.pairing",
                        "operator.read",
                        "operator.talk.secrets",
                        "operator.write",
                    ],
                    "issuedAtMs": 1001,
                ],
            ],
        ])
        let gateway = GatewayNodeSession()
        let options = GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios-test",
            clientMode: "node",
            clientDisplayName: "iOS Test",
            includeDeviceIdentity: true)

        try await gateway.connect(
            url: URL(string: "wss://example.invalid")!,
            token: nil,
            bootstrapToken: "fresh-bootstrap-token",
            password: nil,
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: session),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { req in
                BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: nil, error: nil)
            })

        let nodeEntry = try #require(DeviceAuthStore.loadToken(deviceId: identity.deviceId, role: "node"))
        let operatorEntry = try #require(DeviceAuthStore.loadToken(deviceId: identity.deviceId, role: "operator"))
        #expect(nodeEntry.token == "node-device-token")
        #expect(nodeEntry.scopes == [])
        #expect(operatorEntry.token == "operator-device-token")
        #expect(operatorEntry.scopes == [
            "operator.approvals",
            "operator.read",
            "operator.talk.secrets",
            "operator.write",
        ])

        await gateway.disconnect()
    }

    @Test
    func nonBootstrapHelloStoresPrimaryDeviceTokenButNotAdditionalBootstrapTokens() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let previousStateDir = ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"]
        setenv("OPENCLAW_STATE_DIR", tempDir.path, 1)
        defer {
            if let previousStateDir {
                setenv("OPENCLAW_STATE_DIR", previousStateDir, 1)
            } else {
                unsetenv("OPENCLAW_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let identity = DeviceIdentityStore.loadOrCreate()
        let session = FakeGatewayWebSocketSession(helloAuth: [
            "deviceToken": "server-node-token",
            "role": "node",
            "scopes": [],
            "deviceTokens": [
                [
                    "deviceToken": "server-operator-token",
                    "role": "operator",
                    "scopes": ["operator.admin"],
                ],
            ],
        ])
        let gateway = GatewayNodeSession()
        let options = GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios-test",
            clientMode: "node",
            clientDisplayName: "iOS Test",
            includeDeviceIdentity: true)

        try await gateway.connect(
            url: URL(string: "wss://example.invalid")!,
            token: "shared-token",
            bootstrapToken: nil,
            password: nil,
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: session),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { req in
                BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: nil, error: nil)
            })

        let nodeEntry = try #require(DeviceAuthStore.loadToken(deviceId: identity.deviceId, role: "node"))
        #expect(nodeEntry.token == "server-node-token")
        #expect(nodeEntry.scopes == [])
        #expect(DeviceAuthStore.loadToken(deviceId: identity.deviceId, role: "operator") == nil)

        await gateway.disconnect()
    }

    @Test
    func untrustedBootstrapHelloDoesNotPersistBootstrapHandoffTokens() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let previousStateDir = ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"]
        setenv("OPENCLAW_STATE_DIR", tempDir.path, 1)
        defer {
            if let previousStateDir {
                setenv("OPENCLAW_STATE_DIR", previousStateDir, 1)
            } else {
                unsetenv("OPENCLAW_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let identity = DeviceIdentityStore.loadOrCreate()
        let session = FakeGatewayWebSocketSession(helloAuth: [
            "deviceToken": "untrusted-node-token",
            "role": "node",
            "scopes": [],
            "deviceTokens": [
                [
                    "deviceToken": "untrusted-operator-token",
                    "role": "operator",
                    "scopes": [
                        "operator.approvals",
                        "operator.read",
                    ],
                ],
            ],
        ])
        let gateway = GatewayNodeSession()
        let options = GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios-test",
            clientMode: "node",
            clientDisplayName: "iOS Test",
            includeDeviceIdentity: true)

        try await gateway.connect(
            url: URL(string: "ws://example.invalid")!,
            token: nil,
            bootstrapToken: "fresh-bootstrap-token",
            password: nil,
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: session),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { req in
                BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: nil, error: nil)
            })

        #expect(DeviceAuthStore.loadToken(deviceId: identity.deviceId, role: "node") == nil)
        #expect(DeviceAuthStore.loadToken(deviceId: identity.deviceId, role: "operator") == nil)

        await gateway.disconnect()
    }

    @Test
    func normalizeCanvasHostUrlPreservesExplicitSecureCanvasPort() {
        let normalized = canonicalizeCanvasHostUrl(
            raw: "https://canvas.example.com:9443/__openclaw__/cap/token",
            activeURL: URL(string: "wss://gateway.example.com")!)

        #expect(normalized == "https://canvas.example.com:9443/__openclaw__/cap/token")
    }

    @Test
    func normalizeCanvasHostUrlBackfillsGatewayHostForLoopbackCanvas() {
        let normalized = canonicalizeCanvasHostUrl(
            raw: "http://127.0.0.1:18789/__openclaw__/cap/token",
            activeURL: URL(string: "wss://gateway.example.com:7443")!)

        #expect(normalized == "https://gateway.example.com:7443/__openclaw__/cap/token")
    }

    @Test
    func invokeWithTimeoutReturnsUnderlyingResponseBeforeTimeout() async {
        let request = BridgeInvokeRequest(id: "1", command: "x", paramsJSON: nil)
        let response = await GatewayNodeSession.invokeWithTimeout(
            request: request,
            timeoutMs: 50,
            onInvoke: { req in
                #expect(req.id == "1")
                return BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: "{}", error: nil)
            }
        )

        #expect(response.ok == true)
        #expect(response.error == nil)
        #expect(response.payloadJSON == "{}")
    }

    @Test
    func invokeWithTimeoutReturnsTimeoutError() async {
        let request = BridgeInvokeRequest(id: "abc", command: "x", paramsJSON: nil)
        let response = await GatewayNodeSession.invokeWithTimeout(
            request: request,
            timeoutMs: 10,
            onInvoke: { _ in
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                return BridgeInvokeResponse(id: "abc", ok: true, payloadJSON: "{}", error: nil)
            }
        )

        #expect(response.ok == false)
        #expect(response.error?.code == .unavailable)
        #expect(response.error?.message.contains("timed out") == true)
    }

    @Test
    func invokeWithTimeoutZeroDisablesTimeout() async {
        let request = BridgeInvokeRequest(id: "1", command: "x", paramsJSON: nil)
        let response = await GatewayNodeSession.invokeWithTimeout(
            request: request,
            timeoutMs: 0,
            onInvoke: { req in
                try? await Task.sleep(nanoseconds: 5_000_000)
                return BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: nil, error: nil)
            }
        )

        #expect(response.ok == true)
        #expect(response.error == nil)
    }

    @Test
    func emitsSyntheticSeqGapAfterReconnectSnapshot() async throws {
        let session = FakeGatewayWebSocketSession()
        let gateway = GatewayNodeSession()
        let options = GatewayConnectOptions(
            role: "operator",
            scopes: ["operator.read"],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios-test",
            clientMode: "ui",
            clientDisplayName: "iOS Test",
            includeDeviceIdentity: false)

        let stream = await gateway.subscribeServerEvents(bufferingNewest: 32)
        let probe = SeqGapProbe()
        let listenTask = Task {
            for await evt in stream {
                if evt.event == "seqGap" {
                    await probe.mark()
                    return
                }
            }
        }

        try await gateway.connect(
            url: URL(string: "ws://example.invalid")!,
            token: nil,
            bootstrapToken: nil,
            password: nil,
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: session),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { req in
                BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: nil, error: nil)
            })

        let firstTask = try #require(session.latestTask())
        firstTask.emitReceiveFailure()

        try await waitUntil("reconnect socket created") {
            session.snapshotMakeCount() >= 2
        }
        try await waitUntil("synthetic seqGap broadcast") {
            await probe.value()
        }

        listenTask.cancel()
        await gateway.disconnect()
    }
}
