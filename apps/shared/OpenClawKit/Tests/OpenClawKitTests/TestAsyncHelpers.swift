import Foundation

struct AsyncWaitTimeoutError: Error, CustomStringConvertible {
    let label: String
    let elapsed: Duration
    let timeout: Duration

    var description: String {
        "Timeout waiting for: \(self.label) after \(self.elapsed) (limit: \(self.timeout))"
    }
}

func waitUntil(
    _ label: String,
    timeoutSeconds: Double = 3.0,
    pollMs: UInt64 = 10,
    _ condition: @escaping @Sendable () async -> Bool) async throws
{
    let clock = ContinuousClock()
    let timeout = Duration.seconds(timeoutSeconds)
    let startedAt = clock.now
    let deadline = startedAt.advanced(by: timeout)
    let pollInterval = Duration.milliseconds(Int64(pollMs))

    while true {
        try Task.checkCancellation()
        if await condition() {
            return
        }

        let now = clock.now
        guard now < deadline else {
            throw AsyncWaitTimeoutError(
                label: label,
                elapsed: startedAt.duration(to: now),
                timeout: timeout)
        }

        await Task.yield()
        let nextPoll = min(clock.now.advanced(by: pollInterval), deadline)
        try await clock.sleep(until: nextPoll, tolerance: .zero)
    }
}
