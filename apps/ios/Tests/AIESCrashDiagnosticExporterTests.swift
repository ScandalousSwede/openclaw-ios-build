import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

struct AIESCrashDiagnosticExporterTests {
    @Test func runtimeManifestUsesExactEmbeddedProvenance() throws {
        let manifest = AIESBuildManifest.from(
            infoDictionary: [
                "OpenClawBuildGitSHA": String(repeating: "a", count: 40),
                "OpenClawBuildGitBranch": "aies/ios-stability",
                "CFBundleShortVersionString": "2026.6.2",
                "CFBundleVersion": "17",
                "OpenClawBuildTimestamp": "2026-08-22T20:00:00Z",
                "OpenClawBuildXcodeVersion": "Xcode 26.2",
                "OpenClawBuildSwiftVersion": "Swift 6.2",
                "OpenClawBuildSDKVersion": "26.2",
                "OpenClawBuildConfiguration": "Debug",
                "OpenClawBuildArchiveUUID": "12345678-1234-5678-1234-567812345678",
                "OpenClawBuildExtensionBundleIDs": ["activity", "share", "share"],
                "OpenClawBuildWatchBundleIDs": ["watch-extension", "watch-app"],
            ],
            bundleIdentifier: "ai.openclaw.client")

        #expect(manifest.schema == AIESBuildManifest.schemaName)
        #expect(manifest.gitSHA == String(repeating: "a", count: 40))
        #expect(manifest.mainBundleID == "ai.openclaw.client")
        #expect(manifest.extensionBundleIDs == ["activity", "share"])
        #expect(manifest.watchBundleIDsIfPresent == ["watch-app", "watch-extension"])
        #expect(manifest.archiveUUID == "12345678-1234-5678-1234-567812345678")
        #expect(manifest.dsymUUIDs.isEmpty)

        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        #expect(object.keys.contains("aps_environment_if_signed"))
        #expect(object["aps_environment_if_signed"] is NSNull)
    }

    @Test func exportIsBoundedAndRetainsNewestMetadata() throws {
        let events = (0..<1000).map { sequence in
            OpenClawDiagnosticEvent(
                kind: .chat,
                state: "received",
                socketGeneration: 8,
                routeGeneration: 13,
                sessionIdentifier: "private-session",
                runIdentifier: "run-\(sequence)",
                messageIdentifier: "message-\(sequence)",
                sequence: sequence,
                stream: "assistant",
                observedAt: Date(timeIntervalSince1970: TimeInterval(sequence)))
        }
        let manifest = self.fixtureManifest()
        let data = try AIESCrashDiagnosticExporter.makeData(
            buildManifest: manifest,
            device: .init(model: "iPhone", osName: "iOS", osVersion: "26.0"),
            events: events,
            generatedAt: Date(timeIntervalSince1970: 1000),
            maximumBytes: 16 * 1024)
        let decoded = try JSONDecoder().decode(AIESCrashDiagnosticExporter.Export.self, from: data)

        #expect(data.count <= 16 * 1024)
        #expect(decoded.diagnosticEvents.count < AIESCrashDiagnosticExporter.maximumEventCount)
        #expect(decoded.diagnosticEvents.last?.sequence == 999)
        #expect(decoded.diagnosticEvents.allSatisfy { $0.sessionHash != "private-session" })
        #expect(decoded.redactionPolicy == "metadata_allowlist_v1")
    }

    @Test func rawLogContentCannotEnterSanitizedEventExport() throws {
        let event = OpenClawDiagnosticEvent(
            kind: .socket,
            state: "connected",
            socketGeneration: 4,
            observedAt: Date(timeIntervalSince1970: 0))
        let encoded = try JSONEncoder().encode(event).base64EncodedString()
        let raw = """
        [timestamp] prompt=private transcript=private token=secret
        [timestamp] aies_diagnostic=not-base64
        [timestamp] gateway_error aies_diagnostic=\(encoded) credential=private
        [timestamp] aies_diagnostic=\(encoded)
        [timestamp] \(GatewayDiagnostics.evidenceRecordMarker)aies_diagnostic=\(encoded)
        [timestamp] tool_result={private}
        """

        let events = GatewayDiagnostics.decodeSanitizedEvents(raw, limit: 10)
        #expect(events == [event])
        let injectedRawLine = GatewayDiagnostics.formatRawLogLine(
            "gateway failure\n[2026-08-22T20:00:00.000Z] aies_diagnostic=\(encoded)",
            timestamp: "2026-08-22T20:00:01.000Z")
        #expect(GatewayDiagnostics.decodeSanitizedEvents(injectedRawLine, limit: 10).isEmpty)
        #expect(!injectedRawLine.contains("\n"))
        let exported = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!exported.contains("private"))
        #expect(!exported.contains("credential"))
        #expect(!exported.contains("transcript"))
    }

    @Test func versionedTailDropsLegacyAndPartialUTF8Prefix() throws {
        #expect(GatewayDiagnostics.logFileName != "openclaw-gateway.log")
        let event = OpenClawDiagnosticEvent(
            kind: .route,
            state: "admitted",
            routeGeneration: 7,
            observedAt: Date(timeIntervalSince1970: 0))
        let encoded = try JSONEncoder().encode(event).base64EncodedString()
        let record = "aies_diagnostic=\(encoded)"
        let data = Data((
            String(repeating: "é", count: 300) + "\n"
                + "[timestamp] \(record)\n"
                + "[timestamp] \(GatewayDiagnostics.evidenceRecordMarker)\(record)\n").utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-diagnostic-tail-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let tail = try #require(GatewayDiagnostics.readLogTail(
            url: url,
            maximumBytes: UInt64(data.count - 1)))
        let text = try #require(String(data: tail, encoding: .utf8))
        #expect(GatewayDiagnostics.decodeSanitizedEvents(text, limit: 10) == [event])
    }

    @Test func exportFailsClosedWhenEnvelopeCannotFit() {
        #expect(throws: AIESCrashDiagnosticExporter.ExportError.self) {
            _ = try AIESCrashDiagnosticExporter.makeData(
                buildManifest: self.fixtureManifest(),
                device: .init(model: "iPhone", osName: "iOS", osVersion: "26.0"),
                events: [],
                generatedAt: Date(timeIntervalSince1970: 0),
                maximumBytes: 1)
        }
    }

    private func fixtureManifest() -> AIESBuildManifest {
        AIESBuildManifest(
            schema: AIESBuildManifest.schemaName,
            gitSHA: String(repeating: "a", count: 40),
            gitBranch: "aies/test",
            version: "2026.6.2",
            buildNumber: "17",
            buildTimestamp: "2026-08-22T20:00:00Z",
            xcodeVersion: "Xcode 26.2",
            swiftVersion: "Swift 6.2",
            sdkVersion: "26.2",
            mainBundleID: "ai.openclaw.client",
            extensionBundleIDs: ["ai.openclaw.client.share"],
            watchBundleIDsIfPresent: ["ai.openclaw.client.watchkitapp"],
            archiveUUID: "12345678-1234-5678-1234-567812345678",
            dsymUUIDs: [],
            configuration: "Debug",
            apsEnvironmentIfSigned: nil)
    }
}
