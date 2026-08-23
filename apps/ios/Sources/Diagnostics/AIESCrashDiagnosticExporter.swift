import Foundation
import OpenClawKit
import UIKit

enum AIESCrashDiagnosticExporter {
    static let schemaName = "argus.openclaw-ios.crash-diagnostic.v1"
    static let maximumExportBytes = 256 * 1024
    static let maximumEventCount = 250

    struct Device: Codable, Equatable, Sendable {
        let model: String
        let osName: String
        let osVersion: String

        private enum CodingKeys: String, CodingKey {
            case model
            case osName = "os_name"
            case osVersion = "os_version"
        }
    }

    struct Export: Codable, Equatable, Sendable {
        let schema: String
        let generatedAt: String
        let buildManifest: AIESBuildManifest
        let device: Device
        let diagnosticEvents: [OpenClawDiagnosticEvent]
        let redactionPolicy: String

        private enum CodingKeys: String, CodingKey {
            case schema
            case generatedAt = "generated_at"
            case buildManifest = "build_manifest"
            case device
            case diagnosticEvents = "diagnostic_events"
            case redactionPolicy = "redaction_policy"
        }
    }

    enum ExportError: LocalizedError {
        case cannotFitBound

        var errorDescription: String? {
            switch self {
            case .cannotFitBound:
                "The sanitized diagnostic export could not fit its size limit."
            }
        }
    }

    @MainActor
    static func writeExport() throws -> URL {
        let device = UIDevice.current
        let data = try self.makeData(
            buildManifest: .current(),
            device: Device(
                model: DeviceInfoHelper.modelIdentifier(),
                osName: device.systemName,
                osVersion: device.systemVersion),
            events: GatewayDiagnostics.recentSanitizedEvents(limit: self.maximumEventCount),
            generatedAt: Date(),
            maximumBytes: self.maximumExportBytes)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClaw-Crash-Diagnostics.json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func makeData(
        buildManifest: AIESBuildManifest,
        device: Device,
        events: [OpenClawDiagnosticEvent],
        generatedAt: Date,
        maximumBytes: Int) throws -> Data
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var boundedEvents = Array(events.suffix(self.maximumEventCount))
        while true {
            let value = Export(
                schema: self.schemaName,
                generatedAt: self.timestamp(generatedAt),
                buildManifest: buildManifest,
                device: device,
                diagnosticEvents: boundedEvents,
                redactionPolicy: "metadata_allowlist_v1")
            let data = try encoder.encode(value)
            if data.count <= maximumBytes { return data }
            guard !boundedEvents.isEmpty else { throw ExportError.cannotFitBound }
            boundedEvents.removeFirst()
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
