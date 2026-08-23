import Foundation
import Network
import OpenClawKit
import os

final class AIESNetworkDiagnosticMonitor: @unchecked Sendable {
    static let shared = AIESNetworkDiagnosticMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.openclaw.aies.network-diagnostics")
    private let started = OSAllocatedUnfairLock(initialState: false)

    private init() {}

    func start() {
        let shouldStart = self.started.withLock { started in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        self.monitor.pathUpdateHandler = { path in
            OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
                kind: .network,
                state: Self.status(path.status),
                networkInterfaces: Self.interfaces(path)))
        }
        self.monitor.start(queue: self.queue)
    }

    private static func status(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied:
            "satisfied"
        case .unsatisfied:
            "unsatisfied"
        case .requiresConnection:
            "requires_connection"
        @unknown default:
            "unknown"
        }
    }

    private static func interfaces(_ path: NWPath) -> [String] {
        var interfaces: [String] = []
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wired") }
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
        if path.usesInterfaceType(.other) { interfaces.append("other") }
        return interfaces
    }
}
