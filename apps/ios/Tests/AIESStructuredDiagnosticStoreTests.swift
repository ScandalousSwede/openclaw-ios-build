import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

struct AIESStructuredDiagnosticStoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("structured-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ event: OpenClawDiagnosticEvent) throws -> String {
        "aies_diagnostic=" + (try JSONEncoder().encode(event)).base64EncodedString()
    }

    @Test func voiceAndConnectionBoundariesSurviveChatFloodAndReload() throws {
        let directory = try self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = OpenClawDiagnosticEvent(kind: .tts, state: "speech_recognition_started", observedAt: Date(timeIntervalSince1970: 1))
        let connection = OpenClawDiagnosticEvent(kind: .socket, state: "connected", observedAt: Date(timeIntervalSince1970: 2))
        try AIESStructuredDiagnosticStore.append(record: self.record(voice), directory: directory)
        try AIESStructuredDiagnosticStore.append(record: self.record(connection), directory: directory)
        for index in 0..<2000 {
            try AIESStructuredDiagnosticStore.append(record: self.record(OpenClawDiagnosticEvent(
                kind: .chat, state: "outbox_snapshot", sequence: index,
                observedAt: Date(timeIntervalSince1970: Double(index + 3)))), directory: directory)
        }
        // A raw log of any size/content is not a source for the dedicated metadata snapshot.
        try Data(String(repeating: "private transcript credential raw\n", count: 10000).utf8)
            .write(to: directory.appendingPathComponent(GatewayDiagnostics.logFileName))
        let restored = AIESStructuredDiagnosticStore.snapshot(directory: directory, limit: 250)
        #expect(restored.events.count == 250)
        #expect(restored.events.contains(voice))
        #expect(restored.events.contains(connection))
        #expect(restored.events.last?.sequence == 1999)
        #expect(restored.coverage.evictedFromStoreCount > 0)
        #expect(restored.coverage.truncated)
        #expect(restored.coverage.categories.first(where: { $0.category == "voice" })?.retainedOldestAt == voice.observedAt)
        for category in AIESStructuredDiagnosticStore.categories {
            let url = AIESStructuredDiagnosticStore.fileURL(directory: directory, category: category)
            #expect(try Data(contentsOf: url).count <= AIESStructuredDiagnosticStore.maximumFileBytes)
        }
        let exported = String(decoding: try JSONEncoder().encode(restored.events), as: UTF8.self)
        #expect(!exported.contains("private transcript"))
        #expect(!exported.contains("credential"))
    }

    @Test func reservationsAreBoundedAndLendUnusedSlots() {
        let events = (0..<1000).map { index in
            OpenClawDiagnosticEvent(kind: index < 200 ? .tts : .chat, state: "boundary", sequence: index,
                observedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let selected = AIESStructuredDiagnosticStore.select(events, limit: 250)
        #expect(selected.count == 250)
        #expect(selected.filter { $0.kind == .tts }.count == 100)
        #expect(selected.last?.sequence == 999)
        #expect(AIESStructuredDiagnosticStore.select(events, limit: 0).isEmpty)
        let chatOnly = Array(events.suffix(800))
        #expect(AIESStructuredDiagnosticStore.select(chatOnly, limit: 250).count == 250)
    }

    @Test func rawAndInvalidRecordsCannotEnterDedicatedStore() throws {
        let directory = try self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: AIESStructuredDiagnosticStore.StoreError.self) {
            try AIESStructuredDiagnosticStore.append(record: "raw=private transcript", directory: directory)
        }
        #expect(AIESStructuredDiagnosticStore.snapshot(directory: directory, limit: 250).events.isEmpty)
        #expect(AIESStructuredDiagnosticStore.snapshot(directory: directory, limit: 250).coverage.readStatus == "no_retained_history")
    }

    @Test func unreadableOrTruncatedStoreIsExplicitlyDegraded() throws {
        let directory = try self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = OpenClawDiagnosticEvent(kind: .tts, state: "speech_recognition_started")
        try AIESStructuredDiagnosticStore.append(record: self.record(voice), directory: directory)
        let url = AIESStructuredDiagnosticStore.fileURL(directory: directory, category: "voice")
        var damaged = try Data(contentsOf: url)
        damaged.removeLast()
        try damaged.write(to: url)
        let snapshot = AIESStructuredDiagnosticStore.snapshot(directory: directory, limit: 250, writeFailureCount: 2)
        #expect(snapshot.events.isEmpty)
        #expect(snapshot.coverage.readStatus == "degraded")
        #expect(snapshot.coverage.writeFailureCount == 2)
        #expect(snapshot.coverage.truncated)
        #expect(snapshot.coverage.categories.first(where: { $0.category == "voice" })?.readStatus == "read_failed")
    }
}
