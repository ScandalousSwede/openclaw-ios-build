import Testing
@testable import OpenClaw

@Suite(.serialized) struct GatewayOnboardingResetTests {
    @Test @MainActor func purgeWaitsForGatewayRouteRetirement() async throws {
        let retirementGate = AsyncGate()
        var events: [String] = []

        let resetTask = Task { @MainActor in
            try await GatewayOnboardingReset.retireRoutesThenPurge(
                retireRoutes: {
                    events.append("retire_started")
                    await retirementGate.wait()
                    events.append("retire_finished")
                },
                purgeOutbox: {
                    events.append("purge_started")
                })
        }

        while events.isEmpty {
            await Task.yield()
        }
        #expect(events == ["retire_started"])

        await retirementGate.open()
        try await resetTask.value
        #expect(events == ["retire_started", "retire_finished", "purge_started"])
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func open() {
        self.isOpen = true
        let pending = self.continuations
        self.continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
