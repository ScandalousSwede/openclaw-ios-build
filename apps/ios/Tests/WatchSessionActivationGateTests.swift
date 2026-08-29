import Foundation
import Testing
@testable import OpenClaw

struct WatchSessionActivationGateTests {
    @Test func `iPhone observes watch pairing and install changes`() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Services/WatchConnectivityTransport.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("func sessionWatchStateDidChange(_ session: WCSession)"))
        #expect(source.contains("paired=\\(session.isPaired) installed=\\(session.isWatchAppInstalled)"))
    }

    @Test func `phone and Watch extension gate sends on activation`() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let phoneSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Services/WatchConnectivityTransport.swift"),
            encoding: .utf8)
        let watchSource = try String(
            contentsOf: iosRoot.appendingPathComponent("WatchExtension/Sources/WatchConnectivityReceiver.swift"),
            encoding: .utf8)
        let project = try String(contentsOf: iosRoot.appendingPathComponent("project.yml"), encoding: .utf8)

        #expect(phoneSource.contains("try await self.ensureActivated()"))
        #expect(phoneSource.contains("guard session.activationState == .activated else"))
        #expect(phoneSource.contains("paired: isActivated && session.isPaired"))
        #expect(phoneSource.contains("appInstalled: isActivated && session.isWatchAppInstalled"))
        #expect(phoneSource.contains("reachable: isActivated && session.isReachable"))
        #expect(phoneSource.contains("self.activationGate.reset()"))
        #expect(watchSource.contains("session = try await self.activatedSession()"))
        #expect(watchSource.contains("self.activationGate.complete("))
        #expect(project.contains("path: Sources/Services/WatchSessionActivationGate.swift"))
    }

    @Test func `concurrent waiters share one activation`() async throws {
        let gate = WatchSessionActivationGate(timeoutNanoseconds: 1_000_000_000)

        #expect(gate.beginActivation())
        #expect(!gate.beginActivation())
        let first = Task { try await gate.waitUntilActivated() }
        let second = Task { try await gate.waitUntilActivated() }

        gate.complete(activated: true, errorDescription: nil)

        try await first.value
        try await second.value
    }

    @Test func `activation timeout remains retryable`() async throws {
        let gate = WatchSessionActivationGate(timeoutNanoseconds: 1_000_000)

        #expect(gate.beginActivation())
        await #expect(throws: WatchSessionActivationError.self) {
            try await gate.waitUntilActivated()
        }

        #expect(gate.beginActivation())
        gate.complete(activated: true, errorDescription: nil)
        try await gate.waitUntilActivated()
    }

    @Test func `activation errors reach every waiter`() async {
        let gate = WatchSessionActivationGate(timeoutNanoseconds: 1_000_000_000)

        #expect(gate.beginActivation())
        let first = Task { try await gate.waitUntilActivated() }
        let second = Task { try await gate.waitUntilActivated() }
        gate.complete(activated: false, errorDescription: "not paired")

        await #expect(throws: WatchSessionActivationError.self) { try await first.value }
        await #expect(throws: WatchSessionActivationError.self) { try await second.value }
    }

    @Test func `deactivation reset releases waiters and permits reactivation`() async throws {
        let gate = WatchSessionActivationGate(timeoutNanoseconds: 1_000_000_000)

        #expect(gate.beginActivation())
        let waiter = Task { try await gate.waitUntilActivated() }
        gate.reset()
        await #expect(throws: WatchSessionActivationError.self) { try await waiter.value }

        #expect(gate.beginActivation())
        gate.complete(activated: true, errorDescription: nil)
        try await gate.waitUntilActivated()
    }

    @Test func `completed prior generation cannot overwrite a successful retry`() async throws {
        let gate = WatchSessionActivationGate(timeoutNanoseconds: 10_000_000)

        #expect(gate.beginActivation())
        gate.complete(activated: false, errorDescription: "first activation failed")
        #expect(gate.beginActivation())
        gate.complete(activated: true, errorDescription: nil)

        try await Task.sleep(nanoseconds: 20_000_000)
        try await gate.waitUntilActivated()
    }
}
