import Foundation
import Network
import OpenClawKit
import os
import Testing
@testable import OpenClaw

private actor SuspendedGatewayTLSProbe {
    private var nextCallID = 0
    private var pending: [Int: CheckedContinuation<GatewayTLSFingerprintProbeResult, Never>] = [:]

    var callCount: Int { self.nextCallID }

    func run() async -> GatewayTLSFingerprintProbeResult {
        self.nextCallID += 1
        let callID = self.nextCallID
        return await withCheckedContinuation { continuation in
            self.pending[callID] = continuation
        }
    }

    func complete(callID: Int, result: GatewayTLSFingerprintProbeResult) {
        self.pending.removeValue(forKey: callID)?.resume(returning: result)
    }
}

private actor SuspendedGatewayBootstrapPreparation {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func run() async {
        self.callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

private actor SuspendedGatewayAutoConnectPreparation {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var callCount = 0
    private(set) var completedCount = 0

    func run() async {
        self.callCount += 1
        let call = self.callCount
        await withCheckedContinuation { continuation in
            self.continuations[call] = continuation
        }
        self.completedCount += 1
    }

    func release(_ call: Int) {
        self.continuations.removeValue(forKey: call)?.resume()
    }
}

@Suite(.serialized) struct GatewayConnectionSecurityTests {
    @MainActor
    private func makeController() -> GatewayConnectionController {
        GatewayConnectionController(appModel: NodeAppModel(), startDiscovery: false)
    }

    @Test func bootstrapManualInputRetainsTheTypedSetupResultInsteadOfLegacyFields() {
        let pending = GatewayConnectionController.ManualAuthOverride.explicit(
            token: nil,
            bootstrapToken: "fresh-bootstrap",
            password: nil)
        let resolved = GatewayConnectionController.ManualAuthOverride.currentManualInput(
            token: "legacy-token",
            pendingOverride: pending,
            password: "legacy-password")

        #expect(resolved?.token == nil)
        #expect(resolved?.bootstrapToken == "fresh-bootstrap")
        #expect(resolved?.password == nil)
    }

    private func makeDiscoveredGateway(
        stableID: String,
        lanHost: String?,
        tailnetDns: String?,
        gatewayPort: Int?,
        fingerprint: String?) -> GatewayDiscoveryModel.DiscoveredGateway
    {
        let endpoint: NWEndpoint = .service(name: "Test", type: "_openclaw-gw._tcp", domain: "local.", interface: nil)
        return GatewayDiscoveryModel.DiscoveredGateway(
            name: "Test",
            endpoint: endpoint,
            stableID: stableID,
            debugID: "debug",
            lanHost: lanHost,
            tailnetDns: tailnetDns,
            gatewayPort: gatewayPort,
            canvasPort: nil,
            tlsEnabled: true,
            tlsFingerprintSha256: fingerprint,
            cliPath: nil)
    }

    private func clearTLSFingerprint(stableID: String) {
        GatewayTLSStore.clearFingerprint(stableID: stableID)
    }

    private func waitForProbeCallCount(
        _ expected: Int,
        probe: SuspendedGatewayTLSProbe,
        timeout: Duration = .seconds(3)) async throws
    {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: timeout)
        while await probe.callCount < expected {
            try Task.checkCancellation()
            let now = clock.now
            guard now < deadline else {
                throw NSError(domain: "GatewayConnectionSecurityTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Timed out waiting for TLS probe call \(expected) after \(startedAt.duration(to: now))",
                ])
            }
            await Task.yield()
            let nextPoll = min(clock.now.advanced(by: .milliseconds(1)), deadline)
            try await clock.sleep(until: nextPoll, tolerance: .zero)
        }
    }

    private func waitForPreparationCallCount(
        _ expected: Int,
        preparation: SuspendedGatewayBootstrapPreparation,
        timeout: Duration = .seconds(3)) async throws
    {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: timeout)
        while await preparation.callCount < expected {
            try Task.checkCancellation()
            let now = clock.now
            guard now < deadline else {
                throw NSError(domain: "GatewayConnectionSecurityTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Timed out waiting for bootstrap preparation call \(expected) after \(startedAt.duration(to: now))",
                ])
            }
            await Task.yield()
            let nextPoll = min(clock.now.advanced(by: .milliseconds(1)), deadline)
            try await clock.sleep(until: nextPoll, tolerance: .zero)
        }
    }

    private func waitForAutoConnectPreparationCallCount(
        _ expected: Int,
        preparation: SuspendedGatewayAutoConnectPreparation,
        timeout: Duration = .seconds(3)) async throws
    {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: timeout)
        while await preparation.callCount < expected {
            try Task.checkCancellation()
            let now = clock.now
            guard now < deadline else {
                throw NSError(domain: "GatewayConnectionSecurityTests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Timed out waiting for auto-connect preparation call \(expected) after \(startedAt.duration(to: now))",
                ])
            }
            await Task.yield()
            let nextPoll = min(clock.now.advanced(by: .milliseconds(1)), deadline)
            try await clock.sleep(until: nextPoll, tolerance: .zero)
        }
    }

    @MainActor
    private func waitForActiveGateway(
        _ stableID: String,
        appModel: NodeAppModel,
        timeout: Duration = .seconds(3)) async throws
    {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: timeout)
        while appModel.activeGatewayConnectConfig?.stableID != stableID {
            try Task.checkCancellation()
            let now = clock.now
            guard now < deadline else {
                throw NSError(domain: "GatewayConnectionSecurityTests", code: 4, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Timed out waiting for active gateway \(stableID) after \(startedAt.duration(to: now))",
                ])
            }
            await Task.yield()
            let nextPoll = min(clock.now.advanced(by: .milliseconds(1)), deadline)
            try await clock.sleep(until: nextPoll, tolerance: .zero)
        }
    }

    private func waitForAutoConnectPreparationCompletionCount(
        _ expected: Int,
        preparation: SuspendedGatewayAutoConnectPreparation,
        timeout: Duration = .seconds(3)) async throws
    {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: timeout)
        while await preparation.completedCount < expected {
            try Task.checkCancellation()
            let now = clock.now
            guard now < deadline else {
                throw NSError(domain: "GatewayConnectionSecurityTests", code: 5, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Timed out waiting for auto-connect completion \(expected) after \(startedAt.duration(to: now))",
                ])
            }
            await Task.yield()
            let nextPoll = min(clock.now.advanced(by: .milliseconds(1)), deadline)
            try await clock.sleep(until: nextPoll, tolerance: .zero)
        }
    }

    @Test @MainActor func discoveredTLSParams_prefersStoredPinOverAdvertisedTXT() async {
        let stableID = "test|\(UUID().uuidString)"
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        GatewayTLSStore.saveFingerprint("11", stableID: stableID)

        let gateway = makeDiscoveredGateway(
            stableID: stableID,
            lanHost: "evil.example.com",
            tailnetDns: "evil.example.com",
            gatewayPort: 12345,
            fingerprint: "22")
        let controller = makeController()

        let params = controller._test_resolveDiscoveredTLSParams(gateway: gateway, allowTOFU: true)
        #expect(params?.expectedFingerprint == "11")
        #expect(params?.allowTOFU == false)
    }

    @Test @MainActor func discoveredTLSParams_doesNotTrustAdvertisedFingerprint() async {
        let stableID = "test|\(UUID().uuidString)"
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let gateway = makeDiscoveredGateway(
            stableID: stableID,
            lanHost: nil,
            tailnetDns: nil,
            gatewayPort: nil,
            fingerprint: "22")
        let controller = makeController()

        let params = controller._test_resolveDiscoveredTLSParams(gateway: gateway, allowTOFU: true)
        #expect(params?.expectedFingerprint == nil)
        #expect(params?.allowTOFU == false)
    }

    @Test @MainActor func autoconnectRequiresStoredPinForDiscoveredGateways() async {
        let stableID = "test|\(UUID().uuidString)"
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "gateway.autoconnect")
        defaults.set(false, forKey: "gateway.manual.enabled")
        defaults.removeObject(forKey: "gateway.last.host")
        defaults.removeObject(forKey: "gateway.last.port")
        defaults.removeObject(forKey: "gateway.last.tls")
        defaults.removeObject(forKey: "gateway.last.stableID")
        defaults.removeObject(forKey: "gateway.last.kind")
        defaults.removeObject(forKey: "gateway.preferredStableID")
        defaults.set(stableID, forKey: "gateway.lastDiscoveredStableID")

        let gateway = makeDiscoveredGateway(
            stableID: stableID,
            lanHost: "test.local",
            tailnetDns: nil,
            gatewayPort: 18789,
            fingerprint: nil)
        let controller = makeController()
        controller._test_setGateways([gateway])
        controller._test_triggerAutoConnect()

        #expect(controller._test_didAutoConnect() == false)
    }

    @Test @MainActor func manualConnectionsForceTLSForNonLoopbackHosts() async {
        let controller = makeController()

        #expect(controller._test_resolveManualUseTLS(host: "gateway.example.com", useTLS: false) == true)
        #expect(controller._test_resolveManualUseTLS(host: "127.attacker.example", useTLS: false) == true)
        #expect(controller._test_resolveManualUseTLS(host: "gateway.ts.net", useTLS: false) == true)
        #expect(controller._test_resolveManualUseTLS(host: "100.64.0.9", useTLS: false) == true)

        #expect(controller._test_resolveManualUseTLS(host: "localhost", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "127.0.0.1", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "::1", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "[::1]", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "::ffff:127.0.0.1", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "0.0.0.0", useTLS: false) == false)
    }

    @Test @MainActor func manualConnectionsAllowPrivateLanPlaintext() async {
        let controller = makeController()

        #expect(controller._test_resolveManualUseTLS(host: "openclaw.local", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "192.168.1.20", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "10.0.0.5", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "172.16.1.5", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "169.254.1.5", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "fd00::1", useTLS: false) == false)
    }

    @Test @MainActor func manualDefaultPortUses443OnlyForTailnetTLSHosts() async {
        let controller = makeController()

        #expect(controller._test_resolveManualPort(host: "gateway.example.com", port: 0, useTLS: true) == 18789)
        #expect(controller._test_resolveManualPort(host: "device.sample.ts.net", port: 0, useTLS: true) == 443)
        #expect(controller._test_resolveManualPort(host: "device.sample.ts.net.", port: 0, useTLS: true) == 443)
        #expect(controller._test_resolveManualPort(host: "device.sample.ts.net", port: 18789, useTLS: true) == 18789)
    }

    @Test @MainActor func setupRouteSelectionFallsBackToReachableTailnetEndpoint() async {
        let probes = OSAllocatedUnfairLock(initialState: [(String, Int)]())
        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { host, port, _, _ in
                probes.withLock { $0.append((host, port)) }
                return host.hasSuffix(".ts.net")
            })
        let link = GatewayConnectDeepLink(
            host: "192.168.139.3",
            port: 18789,
            tls: false,
            bootstrapToken: "boot",
            token: nil,
            password: nil,
            fallbackEndpoints: [
                .init(host: "clawmac.tail.ts.net", port: 8443, tls: true),
            ])

        let selected = await controller.selectReachableSetupLink(link)

        #expect(selected.host == "clawmac.tail.ts.net")
        #expect(selected.port == 8443)
        #expect(selected.tls)
        #expect(selected.bootstrapToken == "boot")
        #expect(probes.withLock { $0.map(\.0) } == ["192.168.139.3", "clawmac.tail.ts.net"])
    }

    @Test @MainActor func setupRouteSelectionKeepsPrimaryWhenEveryProbeFails() async {
        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in false })
        let link = GatewayConnectDeepLink(
            host: "192.168.139.3",
            port: 18789,
            tls: false,
            bootstrapToken: "boot",
            token: nil,
            password: nil,
            fallbackEndpoints: [
                .init(host: "clawmac.tail.ts.net", port: 8443, tls: true),
            ])

        #expect(await controller.selectReachableSetupLink(link) == link)
    }

    @Test @MainActor func manualFirstUseTLSProbeShowsTrustPromptAfterFingerprintCapture() async {
        let host = "gateway-\(UUID().uuidString).example.com"
        let port = 18789
        let stableID = "manual|\(host.lowercased())|\(port)"
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let appModel = NodeAppModel()
        let priorProblem = GatewayConnectionProblem(
            kind: .reachabilityFailed,
            owner: .gateway,
            title: "Previous failure",
            message: "Previous failure",
            requestId: nil,
            retryable: true,
            pauseReconnect: false)
        appModel._test_applyOperatorGatewayConnectionProblem(priorProblem)
        #expect(appModel.lastGatewayProblem == priorProblem)
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { _ in .fingerprint("abc123") })

        await controller.connectManual(host: host, port: port, useTLS: true)

        #expect(controller.pendingTrustPrompt?.fingerprintSha256 == "abc123")
        #expect(controller.pendingTrustPrompt?.host == host)
        #expect(controller.pendingTrustPrompt?.port == port)
        #expect(appModel.gatewayStatusText == "Verify gateway TLS fingerprint")
        #expect(appModel.lastGatewayProblem == nil)
    }

    @Test @MainActor func firstUseTLSProbeBeginsPreconnectVerificationBeforeBothProbePaths() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Gateway/GatewayConnectionController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let preconnect = "beginGatewayPreconnectVerification(statusText: \"Verifying gateway TLS fingerprint…\")"

        let discoveredStart = try #require(source.range(of: "private func connectDiscoveredGateway"))
        let manualStart = try #require(source.range(of: "func connectManual", range: discoveredStart.upperBound..<source.endIndex))
        let discoveredBody = source[discoveredStart.lowerBound..<manualStart.lowerBound]
        let discoveredPreconnect = try #require(discoveredBody.range(of: preconnect))
        let discoveredProbe = try #require(discoveredBody.range(of: "await self.probeTLSFingerprint"))
        #expect(discoveredPreconnect.lowerBound < discoveredProbe.lowerBound)

        let manualEnd = try #require(source.range(of: "func connectLastKnown", range: manualStart.upperBound..<source.endIndex))
        let manualBody = source[manualStart.lowerBound..<manualEnd.lowerBound]
        let manualPreconnect = try #require(manualBody.range(of: preconnect))
        let manualProbe = try #require(manualBody.range(of: "await self.probeTLSFingerprint"))
        #expect(manualPreconnect.lowerBound < manualProbe.lowerBound)

        #expect(source.components(separatedBy: preconnect).count - 1 == 2)
    }

    @Test @MainActor func manualFirstUseTLSProbeSkipsTLSWhenTCPIsUnreachable() async {
        let host = "gateway-\(UUID().uuidString).example.com"
        let port = 18789
        let stableID = "manual|\(host.lowercased())|\(port)"
        let tlsProbeCalls = OSAllocatedUnfairLock(initialState: 0)
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in false },
            tlsFingerprintProbe: { _ in
                tlsProbeCalls.withLock { $0 += 1 }
                return .fingerprint("abc123")
            })

        await controller.connectManual(host: host, port: port, useTLS: true)

        #expect(tlsProbeCalls.withLock { $0 } == 0)
        #expect(controller.pendingTrustPrompt == nil)
        #expect(appModel.gatewayStatusText == "Can't reach gateway at \(host):\(port). Check Tailscale or LAN.")
    }

    @Test @MainActor func manualFirstUseTLSProbeReportsHandshakeTimeoutWithoutTrustPrompt() async {
        let host = "gateway-\(UUID().uuidString).example.com"
        let port = 18789
        let stableID = "manual|\(host.lowercased())|\(port)"
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { _ in .failure(.tlsHandshakeTimeout) })

        await controller.connectManual(host: host, port: port, useTLS: true)

        #expect(controller.pendingTrustPrompt == nil)
        #expect(appModel.gatewayStatusText.contains("TLS fingerprint verification timed out"))
        #expect(appModel.gatewayStatusText.contains("\(host):\(port)"))
    }

    @Test @MainActor func abandonedTrustProbeCannotPresentOverReplacementSetup() async throws {
        let firstHost = "first-\(UUID().uuidString).example.com"
        let secondHost = "second-\(UUID().uuidString).example.com"
        let port = 18789
        let firstStableID = "manual|\(firstHost.lowercased())|\(port)"
        let secondStableID = "manual|\(secondHost.lowercased())|\(port)"
        defer {
            clearTLSFingerprint(stableID: firstStableID)
            clearTLSFingerprint(stableID: secondStableID)
        }
        clearTLSFingerprint(stableID: firstStableID)
        clearTLSFingerprint(stableID: secondStableID)

        let probe = SuspendedGatewayTLSProbe()
        let controller = GatewayConnectionController(
            appModel: NodeAppModel(),
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { _ in await probe.run() })

        let firstAttempt = Task { @MainActor in
            await controller.connectManual(host: firstHost, port: port, useTLS: true)
        }
        try await self.waitForProbeCallCount(1, probe: probe)
        controller.clearPendingTrustPrompt()
        await probe.complete(callID: 1, result: .fingerprint("stale"))
        await firstAttempt.value
        #expect(controller.pendingTrustPrompt == nil)

        let replacementAttempt = Task { @MainActor in
            await controller.connectManual(host: secondHost, port: port, useTLS: true)
        }
        try await self.waitForProbeCallCount(2, probe: probe)
        await probe.complete(callID: 2, result: .fingerprint("current"))
        await replacementAttempt.value

        #expect(controller.pendingTrustPrompt?.host == secondHost)
        #expect(controller.pendingTrustPrompt?.fingerprintSha256 == "current")
    }

    @Test @MainActor func staleVisibleTrustPromptCannotAcceptOrCancelReplacement() async throws {
        let firstHost = "first-\(UUID().uuidString).example.com"
        let secondHost = "second-\(UUID().uuidString).example.com"
        let port = 18789
        let firstStableID = "manual|\(firstHost.lowercased())|\(port)"
        let secondStableID = "manual|\(secondHost.lowercased())|\(port)"
        defer {
            clearTLSFingerprint(stableID: firstStableID)
            clearTLSFingerprint(stableID: secondStableID)
        }
        clearTLSFingerprint(stableID: firstStableID)
        clearTLSFingerprint(stableID: secondStableID)

        let appModel = NodeAppModel()
        appModel._test_setGatewayRoleStates(node: .online, operator: .online)
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { url in .fingerprint("fp-\(url.host ?? "unknown")") })

        await controller.connectManual(host: firstHost, port: port, useTLS: true)
        let firstPrompt = try #require(controller.pendingTrustPrompt)
        await controller.connectManual(host: secondHost, port: port, useTLS: true)
        let secondPrompt = try #require(controller.pendingTrustPrompt)
        #expect(firstPrompt.generation != secondPrompt.generation)

        await controller.acceptPendingTrustPrompt(firstPrompt)
        #expect(controller.pendingTrustPrompt == secondPrompt)
        #expect(GatewayTLSStore.loadFingerprint(stableID: firstStableID) == nil)
        #expect(GatewayTLSStore.loadFingerprint(stableID: secondStableID) == nil)

        controller.declinePendingTrustPrompt(firstPrompt)
        #expect(controller.pendingTrustPrompt == secondPrompt)

        controller.declinePendingTrustPrompt(secondPrompt)
        #expect(controller.pendingTrustPrompt == nil)
        #expect(appModel.gatewayStatusText == "Connected")
    }

    @Test @MainActor func trustPromptPersistenceFailureIsFailClosedAndRetryable() async throws {
        let host = "gateway-\(UUID().uuidString).example.com"
        let port = 18789
        let stableID = "manual|\(host.lowercased())|\(port)"
        let persistenceCalls = OSAllocatedUnfairLock(initialState: [(String, String)]())
        let preparationCalls = OSAllocatedUnfairLock(initialState: 0)
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { _ in .fingerprint("fail-closed-fingerprint") },
            persistTLSFingerprint: { fingerprint, persistedStableID in
                persistenceCalls.withLock { $0.append((fingerprint, persistedStableID)) }
                return false
            },
            prepareBootstrapReplacement: {
                preparationCalls.withLock { $0 += 1 }
            })

        await controller.connectManual(
            host: host,
            port: port,
            useTLS: true,
            authOverride: .explicit(token: nil, bootstrapToken: "one-shot", password: nil))
        let prompt = try #require(controller.pendingTrustPrompt)
        await controller.acceptPendingTrustPrompt(prompt)

        #expect(persistenceCalls.withLock { $0.count } == 1)
        #expect(persistenceCalls.withLock { $0.first?.0 } == "fail-closed-fingerprint")
        #expect(persistenceCalls.withLock { $0.first?.1 } == stableID)
        #expect(preparationCalls.withLock { $0 } == 0)
        #expect(controller.pendingTrustPrompt == prompt)
        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID) == nil)
        #expect(controller._test_didAutoConnect() == false)
        #expect(appModel.activeGatewayConnectConfig == nil)
        #expect(appModel.gatewayStatusText == "Could not save gateway certificate")
    }

    @Test @MainActor func acceptedTrustPersistsPinBeforeDestructiveBootstrapReplacement() async throws {
        let host = "gateway-\(UUID().uuidString).example.com"
        let port = 443
        let stableID = "manual|\(host.lowercased())|\(port)"
        let order = OSAllocatedUnfairLock(initialState: [String]())
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { _ in .fingerprint("accepted-fingerprint") },
            persistTLSFingerprint: { _, _ in
                order.withLock { $0.append("persist-pin") }
                return true
            },
            prepareBootstrapReplacement: {
                order.withLock { $0.append("prepare-bootstrap") }
            })

        await controller.connectManual(
            host: host,
            port: port,
            useTLS: true,
            authOverride: .explicit(token: nil, bootstrapToken: "one-shot", password: nil))
        let prompt = try #require(controller.pendingTrustPrompt)
        #expect(order.withLock { $0 }.isEmpty)

        await controller.acceptPendingTrustPrompt(prompt)

        #expect(order.withLock { $0 } == ["persist-pin", "prepare-bootstrap"])
        #expect(controller.pendingTrustPrompt == nil)
        #expect(appModel.activeGatewayConnectConfig?.bootstrapToken == "one-shot")
        #expect(appModel.activeGatewayConnectConfig?.tls?.expectedFingerprint == "accepted-fingerprint")
    }

    @Test @MainActor func duplicateTrustAcceptanceClaimsThePromptExactlyOnce() async throws {
        let host = "duplicate-accept-\(UUID().uuidString).example.com"
        let port = 443
        let stableID = "manual|\(host.lowercased())|\(port)"
        let preparation = SuspendedGatewayBootstrapPreparation()
        let persistenceCalls = OSAllocatedUnfairLock(initialState: 0)
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { _ in .fingerprint("accepted-fingerprint") },
            persistTLSFingerprint: { _, _ in
                persistenceCalls.withLock { $0 += 1 }
                return true
            },
            prepareBootstrapReplacement: {
                await preparation.run()
            })

        await controller.connectManual(
            host: host,
            port: port,
            useTLS: true,
            authOverride: .explicit(token: nil, bootstrapToken: "one-shot", password: nil))
        let prompt = try #require(controller.pendingTrustPrompt)

        let firstAccept = Task { @MainActor in
            await controller.acceptPendingTrustPrompt(prompt)
        }
        try await self.waitForPreparationCallCount(1, preparation: preparation)
        await controller.acceptPendingTrustPrompt(prompt)

        #expect(persistenceCalls.withLock { $0 } == 1)
        #expect(await preparation.callCount == 1)
        #expect(controller.pendingTrustPrompt == prompt)

        await preparation.release()
        await firstAccept.value

        #expect(persistenceCalls.withLock { $0 } == 1)
        #expect(await preparation.callCount == 1)
        #expect(controller.pendingTrustPrompt == nil)
        #expect(appModel.activeGatewayConnectConfig?.stableID == stableID)
    }

    @Test @MainActor func failedFingerprintPersistenceCanBeRetriedOnTheSamePrompt() async throws {
        let host = "persist-retry-\(UUID().uuidString).example.com"
        let port = 443
        let stableID = "manual|\(host.lowercased())|\(port)"
        let persistenceCalls = OSAllocatedUnfairLock(initialState: 0)
        let preparationCalls = OSAllocatedUnfairLock(initialState: 0)
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { _ in .fingerprint("retry-fingerprint") },
            persistTLSFingerprint: { _, _ in
                persistenceCalls.withLock {
                    $0 += 1
                    return $0 == 2
                }
            },
            prepareBootstrapReplacement: {
                preparationCalls.withLock { $0 += 1 }
            })

        await controller.connectManual(
            host: host,
            port: port,
            useTLS: true,
            authOverride: .explicit(token: nil, bootstrapToken: "one-shot", password: nil))
        let prompt = try #require(controller.pendingTrustPrompt)

        await controller.acceptPendingTrustPrompt(prompt)
        #expect(controller.pendingTrustPrompt == prompt)
        #expect(persistenceCalls.withLock { $0 } == 1)
        #expect(preparationCalls.withLock { $0 } == 0)

        await controller.acceptPendingTrustPrompt(prompt)
        #expect(controller.pendingTrustPrompt == nil)
        #expect(persistenceCalls.withLock { $0 } == 2)
        #expect(preparationCalls.withLock { $0 } == 1)
        #expect(appModel.activeGatewayConnectConfig?.stableID == stableID)
    }

    @Test @MainActor func acceptedTrustOwnsConfigApplicationWhileOptionPreparationSuspends() async throws {
        let firstHost = "accepted-options-\(UUID().uuidString).example.com"
        let secondHost = "blocked-options-\(UUID().uuidString).example.com"
        let port = 443
        let firstStableID = "manual|\(firstHost.lowercased())|\(port)"
        let secondStableID = "manual|\(secondHost.lowercased())|\(port)"
        let autoConnectPreparation = SuspendedGatewayAutoConnectPreparation()
        defer {
            clearTLSFingerprint(stableID: firstStableID)
            clearTLSFingerprint(stableID: secondStableID)
        }
        clearTLSFingerprint(stableID: firstStableID)
        clearTLSFingerprint(stableID: secondStableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in true },
            tlsFingerprintProbe: { _ in .fingerprint("accepted-fingerprint") },
            persistTLSFingerprint: { _, _ in true },
            prepareBootstrapReplacement: {},
            prepareAutoConnect: {
                await autoConnectPreparation.run()
            })

        await controller.connectManual(
            host: firstHost,
            port: port,
            useTLS: true,
            authOverride: .explicit(token: nil, bootstrapToken: "first-bootstrap", password: nil))
        let prompt = try #require(controller.pendingTrustPrompt)
        let accepted = Task { @MainActor in
            await controller.acceptPendingTrustPrompt(prompt)
        }
        try await self.waitForAutoConnectPreparationCallCount(1, preparation: autoConnectPreparation)

        controller.refreshActiveGatewayRegistrationFromSettings()
        await Task.yield()
        await controller.connectManual(
            host: secondHost,
            port: port,
            useTLS: true,
            authOverride: .explicit(token: nil, bootstrapToken: "second-bootstrap", password: nil))

        #expect(await autoConnectPreparation.callCount == 1)
        #expect(appModel.activeGatewayConnectConfig == nil)
        #expect(appModel.gatewayStatusText == "Finishing the accepted gateway setup…")

        await autoConnectPreparation.release(1)
        await accepted.value

        #expect(appModel.activeGatewayConnectConfig?.stableID == firstStableID)
        #expect(appModel.activeGatewayConnectConfig?.stableID != secondStableID)
        #expect(appModel.activeGatewayConnectConfig?.bootstrapToken == "first-bootstrap")
    }

    @Test @MainActor func supersededConfigTaskCannotOverwriteNewerManualAdmission() async throws {
        let firstHost = "stale-config-\(UUID().uuidString).example.com"
        let secondHost = "current-config-\(UUID().uuidString).example.com"
        let port = 443
        let firstStableID = "manual|\(firstHost.lowercased())|\(port)"
        let secondStableID = "manual|\(secondHost.lowercased())|\(port)"
        let autoConnectPreparation = SuspendedGatewayAutoConnectPreparation()
        defer {
            clearTLSFingerprint(stableID: firstStableID)
            clearTLSFingerprint(stableID: secondStableID)
        }
        GatewayTLSStore.saveFingerprint("first-pin", stableID: firstStableID)
        GatewayTLSStore.saveFingerprint("second-pin", stableID: secondStableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            prepareAutoConnect: {
                await autoConnectPreparation.run()
            })

        await controller.connectManual(host: firstHost, port: port, useTLS: true)
        try await self.waitForAutoConnectPreparationCallCount(1, preparation: autoConnectPreparation)
        await controller.connectManual(host: secondHost, port: port, useTLS: true)
        try await self.waitForAutoConnectPreparationCallCount(2, preparation: autoConnectPreparation)

        await autoConnectPreparation.release(2)
        try await self.waitForActiveGateway(secondStableID, appModel: appModel)
        await autoConnectPreparation.release(1)
        try await self.waitForAutoConnectPreparationCompletionCount(2, preparation: autoConnectPreparation)

        #expect(appModel.activeGatewayConnectConfig?.stableID == secondStableID)
        #expect(appModel.activeGatewayConnectConfig?.stableID != firstStableID)
    }

    @Test @MainActor func refreshBeforeFirstConfigPublicationDoesNotCancelTheConnect() async throws {
        let host = "refresh-before-publish-\(UUID().uuidString).example.com"
        let port = 443
        let stableID = "manual|\(host.lowercased())|\(port)"
        let autoConnectPreparation = SuspendedGatewayAutoConnectPreparation()
        defer { clearTLSFingerprint(stableID: stableID) }
        GatewayTLSStore.saveFingerprint("stored-pin", stableID: stableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            prepareAutoConnect: {
                await autoConnectPreparation.run()
            })

        await controller.connectManual(host: host, port: port, useTLS: true)
        try await self.waitForAutoConnectPreparationCallCount(1, preparation: autoConnectPreparation)
        #expect(appModel.activeGatewayConnectConfig == nil)

        controller.refreshActiveGatewayRegistrationFromSettings()
        await Task.yield()
        await autoConnectPreparation.release(1)
        try await self.waitForActiveGateway(stableID, appModel: appModel)

        #expect(appModel.activeGatewayConnectConfig?.stableID == stableID)
        #expect(await autoConnectPreparation.callCount == 1)
    }

    @Test @MainActor func acceptedTrustCommitCannotBeSupersededWhileBootstrapReplacementSuspends() async throws {
        let firstHost = "first-\(UUID().uuidString).example.com"
        let secondHost = "second-\(UUID().uuidString).example.com"
        let port = 443
        let firstStableID = "manual|\(firstHost.lowercased())|\(port)"
        let secondStableID = "manual|\(secondHost.lowercased())|\(port)"
        let preparation = SuspendedGatewayBootstrapPreparation()
        let probeHosts = OSAllocatedUnfairLock(initialState: [String]())
        let defaults = UserDefaults.standard
        let manualKeys = [
            "gateway.manual.enabled",
            "gateway.manual.host",
            "gateway.manual.port",
            "gateway.manual.tls",
        ]
        var savedDefaults: [String: Any?] = [:]
        for key in manualKeys {
            savedDefaults.updateValue(defaults.object(forKey: key), forKey: key)
        }
        let instanceID = GatewaySettingsStore.currentInstanceID()
        let savedToken = GatewaySettingsStore.loadGatewayToken(instanceId: instanceID)
        let savedPassword = GatewaySettingsStore.loadGatewayPassword(instanceId: instanceID)
        let savedBootstrap = GatewaySettingsStore.loadGatewayBootstrapToken(instanceId: instanceID)
        defer {
            clearTLSFingerprint(stableID: firstStableID)
            clearTLSFingerprint(stableID: secondStableID)
            for (key, value) in savedDefaults {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            GatewaySettingsStore.saveGatewayToken(savedToken ?? "", instanceId: instanceID)
            GatewaySettingsStore.saveGatewayPassword(savedPassword ?? "", instanceId: instanceID)
            GatewaySettingsStore.saveGatewayBootstrapToken(savedBootstrap ?? "", instanceId: instanceID)
        }
        clearTLSFingerprint(stableID: firstStableID)
        clearTLSFingerprint(stableID: secondStableID)
        defaults.set(true, forKey: "gateway.manual.enabled")
        defaults.set("existing.example.com", forKey: "gateway.manual.host")
        defaults.set(8443, forKey: "gateway.manual.port")
        defaults.set(true, forKey: "gateway.manual.tls")
        GatewaySettingsStore.saveGatewayToken("existing-token", instanceId: instanceID)
        GatewaySettingsStore.saveGatewayPassword("existing-password", instanceId: instanceID)
        GatewaySettingsStore.saveGatewayBootstrapToken("existing-bootstrap", instanceId: instanceID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { host, _, _, _ in
                probeHosts.withLock { $0.append(host) }
                return true
            },
            tlsFingerprintProbe: { _ in .fingerprint("accepted-fingerprint") },
            persistTLSFingerprint: { _, _ in true },
            prepareBootstrapReplacement: {
                await preparation.run()
            })

        await controller.connectManual(
            host: firstHost,
            port: port,
            useTLS: true,
            authOverride: .explicit(token: nil, bootstrapToken: "first-bootstrap", password: nil))
        let firstPrompt = try #require(controller.pendingTrustPrompt)

        let accepted = Task { @MainActor in
            await controller.acceptPendingTrustPrompt(firstPrompt)
        }
        try await self.waitForPreparationCallCount(1, preparation: preparation)

        await controller.connectManual(
            host: secondHost,
            port: port,
            useTLS: true,
            authOverride: .explicit(token: nil, bootstrapToken: "second-bootstrap", password: nil))

        #expect(controller.pendingTrustPrompt == firstPrompt)
        #expect(probeHosts.withLock { $0 } == [firstHost])
        #expect(await preparation.callCount == 1)
        #expect(appModel.gatewayStatusText == "Finishing the accepted gateway setup…")
        #expect(defaults.string(forKey: "gateway.manual.host") == "existing.example.com")
        #expect(defaults.integer(forKey: "gateway.manual.port") == 8443)
        #expect(GatewaySettingsStore.loadGatewayToken(instanceId: instanceID) == "existing-token")
        #expect(GatewaySettingsStore.loadGatewayPassword(instanceId: instanceID) == "existing-password")
        #expect(GatewaySettingsStore.loadGatewayBootstrapToken(instanceId: instanceID) == "existing-bootstrap")

        await preparation.release()
        await accepted.value

        #expect(controller.pendingTrustPrompt == nil)
        #expect(controller._test_didAutoConnect())
        #expect(appModel.activeGatewayConnectConfig?.stableID != secondStableID)
        #expect(appModel.activeGatewayConnectConfig?.bootstrapToken != "second-bootstrap")
        #expect(defaults.string(forKey: "gateway.manual.host") == firstHost)
        #expect(defaults.integer(forKey: "gateway.manual.port") == port)
    }

    @Test @MainActor func storedPinBootstrapCommitCannotBeSupersededWhileReplacementSuspends() async throws {
        let firstHost = "trusted-\(UUID().uuidString).example.com"
        let secondHost = "replacement-\(UUID().uuidString).example.com"
        let port = 443
        let firstStableID = "manual|\(firstHost.lowercased())|\(port)"
        let secondStableID = "manual|\(secondHost.lowercased())|\(port)"
        let preparation = SuspendedGatewayBootstrapPreparation()
        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        defer {
            clearTLSFingerprint(stableID: firstStableID)
            clearTLSFingerprint(stableID: secondStableID)
        }
        GatewayTLSStore.saveFingerprint("stored-fingerprint", stableID: firstStableID)
        clearTLSFingerprint(stableID: secondStableID)

        let appModel = NodeAppModel()
        let controller = GatewayConnectionController(
            appModel: appModel,
            startDiscovery: false,
            tcpReachabilityProbe: { _, _, _, _ in
                probeCount.withLock { $0 += 1 }
                return true
            },
            tlsFingerprintProbe: { _ in .fingerprint("replacement-fingerprint") },
            prepareBootstrapReplacement: {
                await preparation.run()
            })

        let accepted = Task { @MainActor in
            await controller.connectManual(
                host: firstHost,
                port: port,
                useTLS: true,
                authOverride: .explicit(token: nil, bootstrapToken: "first-bootstrap", password: nil))
        }
        try await self.waitForPreparationCallCount(1, preparation: preparation)

        await controller.connectManual(
            host: secondHost,
            port: port,
            useTLS: true,
            authOverride: .explicit(token: nil, bootstrapToken: "second-bootstrap", password: nil))

        #expect(await preparation.callCount == 1)
        #expect(probeCount.withLock { $0 } == 0)
        #expect(controller.pendingTrustPrompt == nil)
        #expect(!controller._test_didAutoConnect())
        #expect(appModel.gatewayStatusText == "Finishing the accepted gateway setup…")

        await preparation.release()
        await accepted.value

        #expect(controller._test_didAutoConnect())
        #expect(appModel.activeGatewayConnectConfig?.stableID != secondStableID)
        #expect(appModel.activeGatewayConnectConfig?.bootstrapToken != "second-bootstrap")
    }

    @Test @MainActor func clearAllTLSFingerprints_removesStoredPins() async {
        let stableID1 = "test|\(UUID().uuidString)"
        let stableID2 = "test|\(UUID().uuidString)"
        defer { GatewayTLSStore.clearAllFingerprints() }

        GatewayTLSStore.saveFingerprint("11", stableID: stableID1)
        GatewayTLSStore.saveFingerprint("22", stableID: stableID2)

        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID1) == "11")
        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID2) == "22")

        GatewayTLSStore.clearAllFingerprints()

        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID1) == nil)
        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID2) == nil)
    }

    @Test func trustedPinMismatchCanBeRecoveredByReplacingStoredPin() {
        let stableID = "test|\(UUID().uuidString)"
        defer { GatewayTLSStore.clearFingerprint(stableID: stableID) }
        GatewayTLSStore.saveFingerprint("old", stableID: stableID)

        let error = GatewayTLSValidationError(
            failure: GatewayTLSValidationFailure(
                kind: .pinMismatch,
                host: "gateway.tailnet.ts.net",
                storeKey: stableID,
                expectedFingerprint: "old",
                observedFingerprint: "new",
                systemTrustOk: true),
            context: "connect to gateway")

        let problem = GatewayConnectionProblemMapper.map(error: error)

        #expect(problem?.kind == .tlsPinMismatch)
        #expect(problem?.canTrustRotatedCertificate == true)
        #expect(problem?.tlsStoreKey == stableID)
        #expect(problem?.tlsExpectedFingerprint == "old")
        #expect(problem?.tlsObservedFingerprint == "new")

        #expect(GatewayTLSStore.replaceFingerprint(problem?.tlsObservedFingerprint ?? "", stableID: stableID))
        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID) == "new")
    }

    @Test func untrustedPinMismatchCannotBeRecoveredInApp() {
        let error = GatewayTLSValidationError(
            failure: GatewayTLSValidationFailure(
                kind: .pinMismatch,
                host: "gateway.tailnet.ts.net",
                storeKey: "gateway",
                expectedFingerprint: "old",
                observedFingerprint: "new",
                systemTrustOk: false),
            context: "connect to gateway")

        let problem = GatewayConnectionProblemMapper.map(error: error)

        #expect(problem?.kind == .tlsPinMismatch)
        #expect(problem?.canTrustRotatedCertificate == false)
    }
}
