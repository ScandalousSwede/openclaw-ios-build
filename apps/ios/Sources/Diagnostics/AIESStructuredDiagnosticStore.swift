import Foundation
import OpenClawKit

/// Dedicated metadata-only files. All live access is serialized by GatewayDiagnostics.queue.
/// Raw diagnostics never enter these files, and chat volume cannot rotate the voice file.
enum AIESStructuredDiagnosticStore {
    static let maximumFileBytes = 256 * 1024
    static let categories = ["voice", "connection", "other"]

    struct CategoryCoverage: Codable, Equatable, Sendable {
        let category: String
        let readStatus: String
        let retainedCount: Int
        let evictedCount: Int
        let invalidRecordCount: Int
        let firstObservedAt: String?
        let retainedOldestAt: String?
        let retainedNewestAt: String?

        private enum CodingKeys: String, CodingKey {
            case category
            case readStatus = "read_status"
            case retainedCount = "retained_count"
            case evictedCount = "known_evicted_count"
            case invalidRecordCount = "invalid_record_count"
            case firstObservedAt = "first_observed_at"
            case retainedOldestAt = "retained_oldest_at"
            case retainedNewestAt = "retained_newest_at"
        }
    }

    struct Coverage: Codable, Equatable, Sendable {
        let source: String
        let categories: [CategoryCoverage]
        let retainedEventCount: Int
        let evictedFromStoreCount: Int
        let invalidRecordCount: Int
        var omittedFromExportCount: Int
        var exportedEventCount: Int
        var exportedOldestAt: String?
        var exportedNewestAt: String?
        var writeFailureCount: Int
        var readStatus: String
        var truncated: Bool

        private enum CodingKeys: String, CodingKey {
            case source, categories, truncated
            case retainedEventCount = "retained_event_count"
            case evictedFromStoreCount = "known_evicted_from_store_count"
            case invalidRecordCount = "invalid_record_count"
            case omittedFromExportCount = "omitted_from_export_count"
            case exportedEventCount = "exported_event_count"
            case exportedOldestAt = "exported_oldest_at"
            case exportedNewestAt = "exported_newest_at"
            case writeFailureCount = "write_failure_count_since_launch"
            case readStatus = "read_status"
        }

        func selecting(_ events: [OpenClawDiagnosticEvent], additionallyOmitted: Int = 0) -> Self {
            var result = self
            result.omittedFromExportCount += max(0, additionallyOmitted)
            result.exportedEventCount = events.count
            result.exportedOldestAt = events.map(\.observedAt).min()
            result.exportedNewestAt = events.map(\.observedAt).max()
            result.truncated = result.truncated || result.omittedFromExportCount > 0
            return result
        }
    }

    struct Snapshot: Sendable {
        let events: [OpenClawDiagnosticEvent]
        let coverage: Coverage
    }

    private struct Header: Codable {
        let schema: String
        var evictedCount: Int
        let firstObservedAt: String
    }

    private struct FileContents {
        var header: Header
        var records: [String]
        var events: [OpenClawDiagnosticEvent]
        var invalidRecordCount: Int
    }

    enum StoreError: Error { case invalidRecord, invalidStore, oversizedStore }

    static func category(for event: OpenClawDiagnosticEvent) -> String {
        if event.kind.rawValue == "tts" || event.state.hasPrefix("speech_") ||
            event.state.hasPrefix("talk_") || event.state.hasPrefix("voice_") {
            return "voice"
        }
        if ["network", "reconnect", "socket", "route", "app_lifecycle"].contains(event.kind.rawValue) {
            return "connection"
        }
        return "other"
    }

    static func fileURL(directory: URL, category: String) -> URL {
        directory.appendingPathComponent("openclaw-structured-\(category)-v1.log")
    }

    static func append(record: String, directory: URL) throws {
        guard let event = OpenClawDiagnosticRecorder.decodeRecord(record) else { throw StoreError.invalidRecord }
        let url = self.fileURL(directory: directory, category: self.category(for: event))
        let entry = Data((record + "\n").utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = Header(schema: "argus.ios.structured-diagnostic-store.v1", evictedCount: 0, firstObservedAt: event.observedAt)
            var data = try JSONEncoder().encode(header)
            data.append(10)
            data.append(entry)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? self.maximumFileBytes
        if size + entry.count > self.maximumFileBytes {
            var contents = try self.readFile(url)
            guard contents.invalidRecordCount == 0 else { throw StoreError.invalidStore }
            var retainedBytes = contents.records.reduce(0) { $0 + $1.utf8.count + 1 }
            while retainedBytes > self.maximumFileBytes / 2, !contents.records.isEmpty {
                retainedBytes -= contents.records.removeFirst().utf8.count + 1
                contents.header.evictedCount += 1
            }
            var data = try JSONEncoder().encode(contents.header)
            data.append(10)
            for retained in contents.records { data.append(contentsOf: (retained + "\n").utf8) }
            data.append(entry)
            guard data.count <= self.maximumFileBytes else { throw StoreError.oversizedStore }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: entry)
        }
    }

    private static func readFile(_ url: URL) throws -> FileContents {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: self.maximumFileBytes + 1) ?? Data()
        guard data.count <= self.maximumFileBytes else { throw StoreError.oversizedStore }
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else { throw StoreError.invalidStore }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        guard let first = lines.first, let header = try? JSONDecoder().decode(Header.self, from: Data(first.utf8)),
              header.schema == "argus.ios.structured-diagnostic-store.v1", (0...1_000_000_000).contains(header.evictedCount),
              header.firstObservedAt.utf8.count <= 40, self.validTimestamp(header.firstObservedAt)
        else { throw StoreError.invalidStore }
        var records: [String] = []
        var events: [OpenClawDiagnosticEvent] = []
        var invalid = 0
        for line in lines.dropFirst() {
            let record = String(line)
            if let event = OpenClawDiagnosticRecorder.decodeRecord(record) {
                records.append(record)
                events.append(event)
            } else { invalid += 1 }
        }
        return FileContents(header: header, records: records, events: events, invalidRecordCount: invalid)
    }

    private static func validTimestamp(_ timestamp: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp) != nil
    }

    static func snapshot(directory: URL, limit: Int, writeFailureCount: Int = 0) -> Snapshot {
        var all: [OpenClawDiagnosticEvent] = []
        var coverage: [CategoryCoverage] = []
        for category in self.categories {
            let url = self.fileURL(directory: directory, category: category)
            if !FileManager.default.fileExists(atPath: url.path) {
                coverage.append(CategoryCoverage(category: category, readStatus: "no_retained_file", retainedCount: 0,
                    evictedCount: 0, invalidRecordCount: 0, firstObservedAt: nil, retainedOldestAt: nil, retainedNewestAt: nil))
                continue
            }
            do {
                let file = try self.readFile(url)
                all.append(contentsOf: file.events)
                coverage.append(CategoryCoverage(category: category, readStatus: file.invalidRecordCount == 0 ? "observed" : "degraded",
                    retainedCount: file.events.count, evictedCount: file.header.evictedCount, invalidRecordCount: file.invalidRecordCount,
                    firstObservedAt: file.header.firstObservedAt, retainedOldestAt: file.events.map(\.observedAt).min(),
                    retainedNewestAt: file.events.map(\.observedAt).max()))
            } catch {
                coverage.append(CategoryCoverage(category: category, readStatus: "read_failed", retainedCount: 0,
                    evictedCount: 0, invalidRecordCount: 0, firstObservedAt: nil, retainedOldestAt: nil, retainedNewestAt: nil))
            }
        }
        let selected = self.select(all, limit: limit)
        let evicted = coverage.reduce(0) { $0 + $1.evictedCount }
        let invalid = coverage.reduce(0) { $0 + $1.invalidRecordCount }
        let degraded = coverage.contains { $0.readStatus == "read_failed" || $0.readStatus == "degraded" }
        let unavailable = coverage.allSatisfy { $0.readStatus == "no_retained_file" }
        let detail = Coverage(source: "separate_structured_metadata_files_v1", categories: coverage,
            retainedEventCount: all.count, evictedFromStoreCount: evicted, invalidRecordCount: invalid,
            omittedFromExportCount: all.count - selected.count, exportedEventCount: selected.count,
            exportedOldestAt: selected.map(\.observedAt).min(), exportedNewestAt: selected.map(\.observedAt).max(),
            writeFailureCount: writeFailureCount, readStatus: degraded ? "degraded" : unavailable ? "no_retained_history" : "bounded_snapshot",
            truncated: evicted > 0 || invalid > 0 || all.count > selected.count || degraded || unavailable || writeFailureCount > 0)
        return Snapshot(events: selected, coverage: detail)
    }

    /// Reserve 40% for voice and 30% for connection/lifecycle; lend unused slots to newest remaining metadata.
    static func select(_ events: [OpenClawDiagnosticEvent], limit: Int) -> [OpenClawDiagnosticEvent] {
        let boundedLimit = min(250, max(0, limit))
        guard boundedLimit > 0 else { return [] }
        let ordered = events.enumerated().sorted {
            $0.element.observedAt == $1.element.observedAt ? $0.offset < $1.offset : $0.element.observedAt < $1.element.observedAt
        }.map(\.element)
        var indices = Set<Int>()
        for (category, quota) in [("voice", boundedLimit * 40 / 100), ("connection", boundedLimit * 30 / 100)] {
            let matches = ordered.indices.filter { self.category(for: ordered[$0]) == category }
            indices.formUnion(matches.suffix(quota))
        }
        for index in ordered.indices.reversed() where indices.count < boundedLimit { indices.insert(index) }
        return indices.sorted().map { ordered[$0] }
    }

    static func suppliedCoverage(_ events: [OpenClawDiagnosticEvent], readStatus: String = "supplied_metadata") -> Coverage {
        Coverage(source: "supplied_sanitized_metadata", categories: [], retainedEventCount: events.count,
            evictedFromStoreCount: 0, invalidRecordCount: 0, omittedFromExportCount: 0,
            exportedEventCount: events.count, exportedOldestAt: events.map(\.observedAt).min(),
            exportedNewestAt: events.map(\.observedAt).max(), writeFailureCount: 0,
            readStatus: readStatus, truncated: readStatus != "supplied_metadata")
    }
}
