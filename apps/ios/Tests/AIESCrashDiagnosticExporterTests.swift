import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

@Suite(.serialized)
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
            bundleIdentifier: "ai.openclaw.client",
            runtimeUUIDObservation: .init(
                source: AIESRuntimeMachOUUIDReader.source,
                status: .observed,
                slices: [
                    .init(
                        uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                        architecture: "arm64"),
                ]))

        #expect(manifest.schema == AIESBuildManifest.schemaName)
        #expect(manifest.schema == "argus.openclaw-ios.runtime-build-manifest.v1")
        #expect(manifest.gitSHA == String(repeating: "a", count: 40))
        #expect(manifest.mainBundleID == "ai.openclaw.client")
        #expect(manifest.extensionBundleIDs == ["activity", "share"])
        #expect(manifest.watchBundleIDsIfPresent == ["watch-app", "watch-extension"])
        #expect(manifest.archiveUUID == "12345678-1234-5678-1234-567812345678")
        #expect(manifest.mainBinaryUUIDs == [
            .init(uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", architecture: "arm64"),
        ])
        #expect(manifest.dsymUUIDs == ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
        #expect(manifest.runtimeUUIDSource == "runtime_main_executable_lc_uuid")
        #expect(manifest.runtimeUUIDStatus == .observed)

        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        #expect(object.keys.contains("aps_environment_if_signed"))
        #expect(object["aps_environment_if_signed"] is NSNull)
        #expect(object["runtime_uuid_source"] as? String == "runtime_main_executable_lc_uuid")
        #expect(object["runtime_uuid_status"] as? String == "observed")
        let binaryUUIDs = try #require(object["main_binary_uuids"] as? [[String: String]])
        #expect(binaryUUIDs == [[
            "architecture": "arm64",
            "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        ]])
        #expect(object["dsym_uuids"] as? [String] == ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
    }

    @Test func thinMachOReaderExportsLCUUID() throws {
        let uuidBytes: [UInt8] = [
            0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78,
            0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78,
        ]
        let slices = try AIESRuntimeMachOUUIDReader.parse(self.thinMachO(
            cpuType: 0x0100_000C,
            cpuSubtype: 0,
            uuidBytes: uuidBytes))

        #expect(slices == [
            .init(uuid: "12345678-1234-5678-1234-567812345678", architecture: "arm64"),
        ])
    }

    @Test func fatMachOReaderExportsEveryArchitectureLCUUID() throws {
        let armSlice = self.thinMachO(
            cpuType: 0x0100_000C,
            cpuSubtype: 0,
            uuidBytes: Array(0x00...0x0F))
        let x86Slice = self.thinMachO(
            cpuType: 0x0100_0007,
            cpuSubtype: 3,
            uuidBytes: Array(0x10...0x1F))
        let slices = try AIESRuntimeMachOUUIDReader.parse(self.fatMachO([
            (cpuType: 0x0100_000C, cpuSubtype: 0, data: armSlice),
            (cpuType: 0x0100_0007, cpuSubtype: 3, data: x86Slice),
        ]))

        #expect(slices == [
            .init(uuid: "00010203-0405-0607-0809-0a0b0c0d0e0f", architecture: "arm64"),
            .init(uuid: "10111213-1415-1617-1819-1a1b1c1d1e1f", architecture: "x86_64"),
        ])
    }

    @Test func fatMachOReaderAcceptsDescriptorCapabilityBits() throws {
        let armSlice = self.thinMachO(
            cpuType: 0x0100_000C,
            cpuSubtype: 0,
            uuidBytes: Array(0x00...0x0F))
        var fat = self.fatMachO([
            (cpuType: 0x0100_000C, cpuSubtype: 0, data: armSlice),
        ])
        // CPU_SUBTYPE_MASK capability bits can legitimately differ between the fat descriptor
        // and the embedded thin header; only the base subtype participates in identity matching.
        fat[12] = 0x80

        #expect(try AIESRuntimeMachOUUIDReader.parse(fat) == [
            .init(uuid: "00010203-0405-0607-0809-0a0b0c0d0e0f", architecture: "arm64"),
        ])
    }

    @Test func fatMachOReaderKeepsDistinctCapabilityVariants() throws {
        let first = self.thinMachO(
            cpuType: 0x0100_000C,
            cpuSubtype: 0,
            uuidBytes: Array(0x00...0x0F))
        let second = self.thinMachO(
            cpuType: 0x0100_000C,
            cpuSubtype: 0,
            uuidBytes: Array(0x10...0x1F))

        #expect(try AIESRuntimeMachOUUIDReader.parse(self.fatMachO([
            (cpuType: 0x0100_000C, cpuSubtype: 0x8000_0000, data: first),
            (cpuType: 0x0100_000C, cpuSubtype: 0x4000_0000, data: second),
        ])) == [
            .init(uuid: "00010203-0405-0607-0809-0a0b0c0d0e0f", architecture: "arm64"),
            .init(uuid: "10111213-1415-1617-1819-1a1b1c1d1e1f", architecture: "arm64"),
        ])
    }

    @Test func malformedMachOReaderFailsClosed() {
        var truncatedLoadCommand = self.thinMachO(
            cpuType: 0x0100_000C,
            cpuSubtype: 0,
            uuidBytes: Array(0x00...0x0F))
        truncatedLoadCommand.removeLast()

        #expect(throws: AIESRuntimeMachOUUIDReader.ParseError.self) {
            _ = try AIESRuntimeMachOUUIDReader.parse(truncatedLoadCommand)
        }
        #expect(AIESRuntimeMachOUUIDReader.observe(truncatedLoadCommand).status == .malformed)
        #expect(AIESRuntimeMachOUUIDReader.observe(truncatedLoadCommand).slices.isEmpty)
        #expect(throws: AIESRuntimeMachOUUIDReader.ParseError.self) {
            _ = try AIESRuntimeMachOUUIDReader.parse(Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 1]))
        }

        var missingUUID = self.thinMachO(
            cpuType: 0x0100_000C,
            cpuSubtype: 0,
            uuidBytes: Array(0x00...0x0F))
        missingUUID[32] = 0x1C
        #expect(AIESRuntimeMachOUUIDReader.observe(missingUUID).status == .uuidMissing)
        #expect(AIESRuntimeMachOUUIDReader.observe(missingUUID).slices.isEmpty)
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
        #expect(decoded.schema == "argus.openclaw-ios.crash-diagnostic.v2")
        #expect(decoded.diagnosticEvents.count < AIESCrashDiagnosticExporter.maximumEventCount)
        #expect(decoded.diagnosticEvents.last?.sequence == 999)
        #expect(decoded.diagnosticEvents.allSatisfy { $0.sessionHash != "private-session" })
        #expect(decoded.diagnosticLogFlushStatus == .completed)
        #expect(decoded.redactionPolicy == "metadata_allowlist_v2")
    }

    @Test func exportMakesIncompleteDiagnosticLogDrainExplicit() throws {
        let data = try AIESCrashDiagnosticExporter.makeData(
            buildManifest: self.fixtureManifest(),
            device: .init(model: "iPhone", osName: "iOS", osVersion: "26.0"),
            events: [],
            generatedAt: Date(timeIntervalSince1970: 0),
            maximumBytes: 16 * 1024,
            diagnosticLogFlushStatus: .timedOut)
        let decoded = try JSONDecoder().decode(AIESCrashDiagnosticExporter.Export.self, from: data)

        #expect(decoded.diagnosticLogFlushStatus == .timedOut)
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

    @Test func boundedFlushPersistsStructuredBoundaryBeforeSnapshot() throws {
        GatewayDiagnostics.reset()
        #expect(GatewayDiagnostics.flush(timeout: 1) == .completed)
        GatewayDiagnostics.bootstrap()
        defer {
            OpenClawDiagnosticRecorder.clearSink()
            GatewayDiagnostics.reset()
            _ = GatewayDiagnostics.flush(timeout: 1)
        }

        let boundary = OpenClawDiagnosticEvent(
            kind: .tts,
            state: "tts_player_call_entered",
            processIdentifier: 4242,
            launchIdentifier: "flush-persistence-test",
            operationIdentifier: "tts-generation-9",
            operationGeneration: 9,
            stream: "pcm",
            sampleRate: 44100,
            observedAt: Date(timeIntervalSince1970: 1))
        OpenClawDiagnosticRecorder.record(boundary)

        #expect(GatewayDiagnostics.flush(timeout: 1) == .completed)
        #expect(GatewayDiagnostics.recentSanitizedEvents(limit: 20).contains(boundary))
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
            mainBinaryUUIDs: [.init(uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", architecture: "arm64")],
            dsymUUIDs: ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],
            runtimeUUIDSource: AIESRuntimeMachOUUIDReader.source,
            runtimeUUIDStatus: .observed,
            configuration: "Debug",
            apsEnvironmentIfSigned: nil)
    }

    private func thinMachO(
        cpuType: UInt32,
        cpuSubtype: UInt32,
        uuidBytes: [UInt8]) -> Data
    {
        var data = Data([0xCF, 0xFA, 0xED, 0xFE])
        self.appendUInt32(cpuType, to: &data, byteOrder: .little)
        self.appendUInt32(cpuSubtype, to: &data, byteOrder: .little)
        self.appendUInt32(2, to: &data, byteOrder: .little)
        self.appendUInt32(1, to: &data, byteOrder: .little)
        self.appendUInt32(24, to: &data, byteOrder: .little)
        self.appendUInt32(0, to: &data, byteOrder: .little)
        self.appendUInt32(0, to: &data, byteOrder: .little)
        self.appendUInt32(0x1B, to: &data, byteOrder: .little)
        self.appendUInt32(24, to: &data, byteOrder: .little)
        data.append(contentsOf: uuidBytes)
        return data
    }

    private func fatMachO(_ slices: [(cpuType: UInt32, cpuSubtype: UInt32, data: Data)]) -> Data {
        var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
        self.appendUInt32(UInt32(slices.count), to: &data, byteOrder: .big)
        var sliceOffset = 8 + slices.count * 20
        for slice in slices {
            self.appendUInt32(slice.cpuType, to: &data, byteOrder: .big)
            self.appendUInt32(slice.cpuSubtype, to: &data, byteOrder: .big)
            self.appendUInt32(UInt32(sliceOffset), to: &data, byteOrder: .big)
            self.appendUInt32(UInt32(slice.data.count), to: &data, byteOrder: .big)
            self.appendUInt32(0, to: &data, byteOrder: .big)
            sliceOffset += slice.data.count
        }
        for slice in slices {
            data.append(slice.data)
        }
        return data
    }

    private enum TestByteOrder {
        case big
        case little
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data, byteOrder: TestByteOrder) {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        switch byteOrder {
        case .big:
            data.append(contentsOf: bytes)
        case .little:
            data.append(contentsOf: bytes.reversed())
        }
    }
}
