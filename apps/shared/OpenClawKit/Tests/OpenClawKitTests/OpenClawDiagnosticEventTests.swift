import Foundation
import os
import Testing
@testable import OpenClawKit

@Suite(.serialized)
struct OpenClawDiagnosticEventTests {
    @Test func hashesSessionAndRejectsUnsafeTokens() throws {
        let event = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "received",
            processIdentifier: 4242,
            launchIdentifier: "launch-epoch-one",
            socketGeneration: 7,
            routeGeneration: 9,
            activityGeneration: 11,
            sessionIdentifier: "private-session-key",
            runIdentifier: "run-ok",
            messageIdentifier: "private message body\n",
            eventIdentifier: String(repeating: "x", count: 129),
            operationIdentifier: "sk_live_credential",
            operationGeneration: 17,
            sequence: 42,
            stream: "assistant",
            byteCount: 8192,
            sampleRate: 44100,
            durationMilliseconds: 321,
            networkInterfaces: ["wifi", "cellular", "wifi", "bad interface"],
            observedAt: Date(timeIntervalSince1970: 0))

        #expect(event.schema == OpenClawDiagnosticEvent.schemaName)
        #expect(event.state == "received")
        #expect(event.processID == 4242)
        #expect(event.launchID?.count == 16)
        #expect(event.launchID != "launch-epoch-one")
        #expect(event.socketGeneration == 7)
        #expect(event.routeGeneration == 9)
        #expect(event.activityGeneration == 11)
        #expect(event.sessionHash?.count == 16)
        #expect(event.sessionHash != "private-session-key")
        #expect(event.runID?.count == 16)
        #expect(event.runID != "run-ok")
        #expect(event.messageID?.count == 16)
        #expect(event.messageID != "private message body\n")
        #expect(event.eventID?.count == 16)
        #expect(event.operationID?.count == 16)
        #expect(event.operationID != "sk_live_credential")
        #expect(event.operationGeneration == 17)
        #expect(event.sequence == 42)
        #expect(event.stream == "assistant")
        #expect(event.byteCount == 8192)
        #expect(event.sampleRate == 44100)
        #expect(event.durationMilliseconds == 321)
        #expect(event.networkInterfaces == ["cellular", "wifi"])
        #expect(event.observedAt == "1970-01-01T00:00:00.000Z")
    }

    @Test func recorderEmitsOnlyEncodedSanitizedEvent() throws {
        let captured = OSAllocatedUnfairLock(initialState: [String]())
        OpenClawDiagnosticRecorder.installSink { line in
            captured.withLock { lines in
                lines.append(line)
            }
        }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .route,
            state: "stale_rejected",
            routeGeneration: 12,
            sessionIdentifier: "do-not-export-this",
            observedAt: Date(timeIntervalSince1970: 0)))

        let line = try #require(captured.withLock { $0.first })
        #expect(line.hasPrefix("aies_diagnostic="))
        #expect(!line.contains("do-not-export-this"))
        let payload = String(line.dropFirst("aies_diagnostic=".count))
        let data = try #require(Data(base64Encoded: payload))
        let event = try JSONDecoder().decode(OpenClawDiagnosticEvent.self, from: data)
        #expect(event.kind == .route)
        #expect(event.state == "stale_rejected")
        #expect(event.routeGeneration == 12)
        #expect(event.sessionHash?.count == 16)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(line) == event)
        #expect(OpenClawDiagnosticRecorder.decodeRecord("private transcript") == nil)
    }

    @Test func decoderRejectsInjectedOrMalformedMetadata() throws {
        let valid = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "received",
            sessionIdentifier: "private-session",
            runIdentifier: "run-1",
            observedAt: Date(timeIntervalSince1970: 0))
        let validObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])

        let mutations: [[String: Any]] = [
            ["prompt": "private transcript"],
            ["run_id": "Bearer sk-private-credential"],
            ["session_hash": "private-session"],
            ["launch_id": "unhashed-launch-identifier"],
            ["process_id": -1],
            ["byte_count": -1],
            ["sample_rate": 0],
            ["duration_milliseconds": -1],
            ["observed_at": "not-a-timestamp"],
            ["network_interfaces": ["wifi", "cellular"]],
        ]
        for mutation in mutations {
            var object = validObject
            object.merge(mutation) { _, replacement in replacement }
            let data = try JSONSerialization.data(withJSONObject: object)
            let record = "aies_diagnostic=" + data.base64EncodedString()
            #expect(OpenClawDiagnosticRecorder.decodeRecord(record) == nil)
        }

        let oversized = "aies_diagnostic=" + String(repeating: "a", count: 8192)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(oversized) == nil)

        var unsafeObject = validObject
        unsafeObject["run_id"] = "Bearer sk-private-credential"
        let unsafeEvent = try JSONDecoder().decode(
            OpenClawDiagnosticEvent.self,
            from: JSONSerialization.data(withJSONObject: unsafeObject))
        let captured = OSAllocatedUnfairLock(initialState: [String]())
        OpenClawDiagnosticRecorder.installSink { line in
            captured.withLock { $0.append(line) }
        }
        defer { OpenClawDiagnosticRecorder.clearSink() }
        OpenClawDiagnosticRecorder.record(unsafeEvent)
        #expect(captured.withLock { $0.isEmpty })
    }

    @Test func newEventsCarryStablePerProcessLaunchMetadata() {
        let first = OpenClawDiagnosticEvent(kind: .appLifecycle, state: "first")
        let second = OpenClawDiagnosticEvent(kind: .tts, state: "second")

        #expect(first.processID == Int(ProcessInfo.processInfo.processIdentifier))
        #expect(second.processID == first.processID)
        #expect(first.launchID?.count == 16)
        #expect(second.launchID == first.launchID)
    }

    @Test func decoderRetainsLegacyV1RecordsWithoutNewMetadata() throws {
        let current = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "received",
            socketGeneration: 3,
            observedAt: Date(timeIntervalSince1970: 0))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["schema"] = "argus.openclaw-ios.diagnostic-event.v1"
        for key in [
            "process_id",
            "launch_id",
            "operation_generation",
            "byte_count",
            "sample_rate",
            "duration_milliseconds",
        ] {
            object.removeValue(forKey: key)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let record = "aies_diagnostic=" + data.base64EncodedString()
        let decoded = try #require(OpenClawDiagnosticRecorder.decodeRecord(record))

        #expect(decoded.schema == "argus.openclaw-ios.diagnostic-event.v1")
        #expect(decoded.kind == .chat)
        #expect(decoded.state == "received")
        #expect(decoded.socketGeneration == 3)
        #expect(decoded.processID == nil)
        #expect(decoded.launchID == nil)
    }
}
