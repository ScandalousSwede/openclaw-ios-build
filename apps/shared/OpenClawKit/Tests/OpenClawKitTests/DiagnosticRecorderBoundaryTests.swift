import Darwin
import Foundation
import os
import Testing
@testable import OpenClawKit

/// Run only this suite in a fresh process. Other suites also own the global sink.
/// This is a bounded diagnostic experiment, not a portable absolute-depth gate.
@Suite(.serialized)
struct DiagnosticRecorderBoundaryTests {
    private static let checkpoints: Set<Int> = [1, 16, 64, 256, 1024]
    private static let capacity = 512

    private struct Sample: Codable, Sendable {
        let ordinal: Int
        let thread: UInt64
        let threadOrdinal: Int
        let addresses: [UInt]
        let possiblyCensored: Bool
    }

    /// Synchronizes bookkeeping only; no callback or decode work runs under this lock.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var deliveries = 0
        private var invalid = 0
        private var ordinals: [Int] = []
        private var threads: [UInt64: Int] = [:]
        private var samples: [Sample] = []
        private var active = 0
        private var maximumOverlap = 0
        private var overlapTimeouts = 0
        let expected: OpenClawDiagnosticEvent
        let requiresOverlap: Bool

        init(expected: OpenClawDiagnosticEvent, overlap: Bool = false) {
            self.expected = expected
            self.requiresOverlap = overlap
        }

        func accept(_ line: String) {
            // First instrumented sink entry: collect addresses before decode/format.
            var buffer = [UnsafeMutableRawPointer?](repeating: nil, count: Self.capacity)
            let depth = Int(backtrace(&buffer, Int32(Self.capacity)))
            let addresses = buffer.prefix(max(0, depth)).map { UInt(bitPattern: $0) }
            var thread: UInt64 = 0
            pthread_threadid_np(nil, &thread)
            self.lock.lock()
            self.deliveries += 1
            let ordinal = self.deliveries
            let threadOrdinal = (self.threads[thread] ?? 0) + 1
            self.threads[thread] = threadOrdinal
            self.ordinals.append(ordinal)
            self.active += 1
            self.maximumOverlap = max(self.maximumOverlap, self.active)
            if DiagnosticRecorderBoundaryTests.checkpoints.contains(threadOrdinal) {
                self.samples.append(Sample(
                    ordinal: ordinal, thread: thread, threadOrdinal: threadOrdinal,
                    addresses: addresses, possiblyCensored: depth >= Self.capacity))
            }
            self.lock.unlock()
            // Only the concurrent arm rendezvous; never hold the bookkeeping lock here.
            if threadOrdinal == 1, self.requiresOverlap {
                // Wait only for observed overlap; the second caller can decode concurrently.
                let deadline = Date().addingTimeInterval(2)
                while self.overlap < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                if self.overlap < 2 {
                    self.lock.lock(); self.overlapTimeouts += 1; self.lock.unlock()
                }
            }
            let decoded = OpenClawDiagnosticRecorder.decodeRecord(line)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: Date(timeIntervalSince1970: 0))
            let valid = decoded == self.expected && timestamp == "1970-01-01T00:00:00.000Z"
            self.lock.lock()
            if !valid { self.invalid += 1 }
            self.active -= 1
            self.lock.unlock()
        }

        private static let capacity = DiagnosticRecorderBoundaryTests.capacity
        var count: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.deliveries }
        var overlap: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.maximumOverlap }
        var shouldStop: Bool {
            self.lock.lock(); defer { self.lock.unlock() }
            if self.samples.contains(where: { $0.possiblyCensored }) { return true }
            for thread in self.threads.keys {
                let depths = self.samples.filter { $0.thread == thread }.map { $0.addresses.count }
                if depths.count >= 3 {
                    let last = Array(depths.suffix(3))
                    // A conservative stop heuristic, not a pass/fail or universal frame limit.
                    if last[1] > last[0] + 4 && last[2] > last[1] + 4 { return true }
                }
            }
            return false
        }

        func report(arm: String, checks: [[Int]], completedWorkPerCaller: [Int] = []) throws {
            self.lock.lock()
            let count = self.deliveries
            let invalid = self.invalid
            let ordinals = self.ordinals
            let samples = self.samples
            let overlap = self.maximumOverlap
            let timeouts = self.overlapTimeouts
            self.lock.unlock()
            #expect(invalid == 0)
            #expect(ordinals == Array(1...max(1, count)))
            #expect(timeouts == 0)
            let encodedSamples = try JSONSerialization.jsonObject(with: JSONEncoder().encode(samples))
            // Symbolization happens after the measured calls, never inside the sampled callback.
            let symbols = samples.map { sample -> [String] in
                var pointers = sample.addresses.map { UnsafeMutableRawPointer(bitPattern: $0) }
                let pointerCount = pointers.count
                guard let names = backtrace_symbols(&pointers, Int32(pointerCount)) else { return [] }
                defer { free(names) }
                return (0..<pointers.count).map { String(cString: names[$0]!) }
            }
            let object: [String: Any] = [
                "arm": arm, "deliveries": count, "invalidPayloads": invalid,
                "invocationOrdinals": ordinals, "perCallBeforeAfter": checks,
                "samples": encodedSamples, "symbolsAfterRun": symbols,
                "bufferCapacity": Self.capacity, "stopHeuristicReached": self.shouldStop,
                "maximumOverlap": overlap, "overlapTimeouts": timeouts,
                "completedWorkPerCaller": completedWorkPerCaller,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "directMismatch": "D bypasses recorder validation/JSON encoding; no real persistence queue",
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            print("DIAGNOSTIC_PROBE_JSON=" + String(decoding: data, as: UTF8.self))
        }
    }

    private static func fixture() throws -> (OpenClawDiagnosticEvent, String) {
        let event = OpenClawDiagnosticEvent(
            kind: .chat, state: "received", sequence: 17,
            observedAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let line = "aies_diagnostic=" + (try encoder.encode(event)).base64EncodedString()
        #expect(OpenClawDiagnosticRecorder.decodeRecord(line) == event)
        return (event, line)
    }

    @Test func isolatedRealRecorderAndFreshDirectControl() throws {
        // A selected-suite process has no app bootstrap, network monitor or other test producers.
        let (event, line) = try Self.fixture()
        defer { OpenClawDiagnosticRecorder.clearSink() }
        for arm in ["R", "D"] {
            OpenClawDiagnosticRecorder.clearSink()
            let probe = Probe(expected: event)
            let fresh: OpenClawDiagnosticRecorder.Sink = { record in probe.accept(record) }
            if arm == "R" { OpenClawDiagnosticRecorder.installSink(fresh) }
            var checks: [[Int]] = []
            for ordinal in 1...64 {
                let before = probe.count
                if arm == "R" { OpenClawDiagnosticRecorder.record(event) } else { fresh(line) }
                let after = probe.count
                checks.append([ordinal, before, after])
                #expect(after == before + 1)
                #expect(after == ordinal)
                if probe.shouldStop { break }
            }
            try probe.report(arm: arm, checks: checks)
        }
    }

    @Test func quiescentFreshReplacementAndClear() throws {
        let (event, _) = try Self.fixture()
        defer { OpenClawDiagnosticRecorder.clearSink() }
        for installations in [1, 16, 64] {
            OpenClawDiagnosticRecorder.clearSink()
            var probes: [Probe] = []
            for _ in 0..<installations {
                let probe = Probe(expected: event)
                probes.append(probe)
                OpenClawDiagnosticRecorder.installSink { line in probe.accept(line) }
            }
            let selected = try #require(probes.last)
            let before = selected.count
            OpenClawDiagnosticRecorder.record(event)
            #expect(selected.count == before + 1)
            #expect(probes.dropLast().allSatisfy { $0.count == 0 })
            OpenClawDiagnosticRecorder.clearSink()
            OpenClawDiagnosticRecorder.record(event)
            #expect(selected.count == 1)
            try selected.report(arm: "replacement-\(installations)", checks: [[1, before, selected.count]])
        }
    }

    @Test func controlledOverlapWithFreshDirectComparison() throws {
        let (event, line) = try Self.fixture()
        defer { OpenClawDiagnosticRecorder.clearSink() }
        for arm in ["R-overlap", "D-overlap"] {
            OpenClawDiagnosticRecorder.clearSink()
            let probe = Probe(expected: event, overlap: true)
            let fresh: OpenClawDiagnosticRecorder.Sink = { record in probe.accept(record) }
            if arm == "R-overlap" { OpenClawDiagnosticRecorder.installSink(fresh) }
            let completed = OSAllocatedUnfairLock(initialState: [0, 0])
            DispatchQueue.concurrentPerform(iterations: 2) { worker in
                for _ in 0..<32 {
                    if probe.shouldStop { break }
                    if arm == "R-overlap" { OpenClawDiagnosticRecorder.record(event) } else { fresh(line) }
                    completed.withLock { $0[worker] += 1 }
                }
            }
            let completedCounts = completed.withLock { $0 }
            #expect(probe.count == completedCounts.reduce(0, +))
            if !probe.shouldStop { #expect(probe.count == 64) }
            #expect(probe.overlap == 2)
            try probe.report(arm: arm, checks: [], completedWorkPerCaller: completedCounts)
        }
    }
}
