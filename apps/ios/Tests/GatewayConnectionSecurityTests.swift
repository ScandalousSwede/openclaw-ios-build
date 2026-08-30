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

@Suite(.serialized) struct GatewayConnectionSecurityTests {
    @MainActor
    private func makeController() -> GatewayConnectionController {
        GatewayConnectionController(appModel: NodeAppModel(), startDiscovery: false)
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
            })

        await controller.connectManual(host: host, port: port, useTLS: true)
        let prompt = try #require(controller.pendingTrustPrompt)
        await controller.acceptPendingTrustPrompt(prompt)

        #expect(persistenceCalls.withLock { $0.count } == 1)
        #expect(persistenceCalls.withLock { $0.first?.0 } == "fail-closed-fingerprint")
        #expect(persistenceCalls.withLock { $0.first?.1 } == stableID)
        #expect(controller.pendingTrustPrompt == prompt)
        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID) == nil)
        #expect(controller._test_didAutoConnect() == false)
        #expect(appModel.activeGatewayConnectConfig == nil)
        #expect(appModel.gatewayStatusText == "Could not save gateway certificate")
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
