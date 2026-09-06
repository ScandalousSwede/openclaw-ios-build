import Foundation
import OpenClawKit
import UIKit

enum AIESCrashDiagnosticExporter {
    static let schemaName = "argus.openclaw-ios.crash-diagnostic.v3"
    static let maximumExportBytes = 256 * 1024
    static let maximumEventCount = 250

    struct PreparedExport: Identifiable, Sendable {
        let id: UUID
        let url: URL
        let generatedAt: Date
    }

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
        let diagnosticLogFlushStatus: GatewayDiagnostics.FlushResult
        let diagnosticCoverage: AIESStructuredDiagnosticStore.Coverage
        let redactionPolicy: String

        private enum CodingKeys: String, CodingKey {
            case schema
            case generatedAt = "generated_at"
            case buildManifest = "build_manifest"
            case device
            case diagnosticEvents = "diagnostic_events"
            case diagnosticLogFlushStatus = "diagnostic_log_flush_status"
            case diagnosticCoverage = "diagnostic_coverage"
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
    static func writeExport() throws -> PreparedExport {
        let device = UIDevice.current
        let diagnosticSnapshot = GatewayDiagnostics.snapshotSanitizedEvents(
            limit: self.maximumEventCount,
            timeout: 1)
        let generatedAt = Date()
        let data = try self.makeData(
            buildManifest: .current(),
            device: Device(
                model: DeviceInfoHelper.modelIdentifier(),
                osName: device.systemName,
                osVersion: device.systemVersion),
            events: diagnosticSnapshot.events,
            generatedAt: generatedAt,
            maximumBytes: self.maximumExportBytes,
            diagnosticLogFlushStatus: diagnosticSnapshot.flushResult,
            coverage: diagnosticSnapshot.coverage)
        return try self.writePreparedExport(data: data, generatedAt: generatedAt)
    }

    static func writePreparedExport(
        data: Data,
        generatedAt: Date,
        directory: URL = FileManager.default.temporaryDirectory) throws -> PreparedExport
    {
        guard data.count <= self.maximumExportBytes else { throw ExportError.cannotFitBound }
        let id = UUID()
        let url = directory.appendingPathComponent("OpenClaw-Crash-Diagnostics-\(id.uuidString).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return PreparedExport(id: id, url: url, generatedAt: generatedAt)
    }

    static func makeData(
        buildManifest: AIESBuildManifest,
        device: Device,
        events: [OpenClawDiagnosticEvent],
        generatedAt: Date,
        maximumBytes: Int,
        diagnosticLogFlushStatus: GatewayDiagnostics.FlushResult = .completed,
        coverage: AIESStructuredDiagnosticStore.Coverage? = nil) throws -> Data
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var boundedEvents = AIESStructuredDiagnosticStore.select(events, limit: self.maximumEventCount)
        var baseCoverage = coverage ?? AIESStructuredDiagnosticStore.suppliedCoverage(events)
        if diagnosticLogFlushStatus != .completed {
            baseCoverage.readStatus = diagnosticLogFlushStatus.rawValue
            baseCoverage.truncated = true
        }
        while true {
            let value = Export(
                schema: self.schemaName,
                generatedAt: self.timestamp(generatedAt),
                buildManifest: buildManifest,
                device: device,
                diagnosticEvents: boundedEvents,
                diagnosticLogFlushStatus: diagnosticLogFlushStatus,
                diagnosticCoverage: baseCoverage.selecting(boundedEvents, additionallyOmitted: events.count - boundedEvents.count),
                redactionPolicy: "metadata_allowlist_v2")
            let data = try encoder.encode(value)
            if data.count <= maximumBytes { return data }
            guard !boundedEvents.isEmpty else { throw ExportError.cannotFitBound }
            // Under the byte ceiling, discard noisy non-voice metadata before voice boundaries.
            let discard = boundedEvents.firstIndex { AIESStructuredDiagnosticStore.category(for: $0) == "other" }
                ?? boundedEvents.firstIndex { AIESStructuredDiagnosticStore.category(for: $0) == "connection" }
                ?? boundedEvents.startIndex
            boundedEvents.remove(at: discard)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
