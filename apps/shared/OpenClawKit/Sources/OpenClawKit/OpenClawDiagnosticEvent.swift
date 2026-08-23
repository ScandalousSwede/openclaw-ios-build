import CryptoKit
import Foundation
import os

public struct OpenClawDiagnosticEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case appLifecycle = "app_lifecycle"
        case chat = "chat"
        case liveActivity = "live_activity"
        case network = "network"
        case reconnect = "reconnect"
        case route = "route"
        case socket = "socket"
    }

    public static let schemaName = "argus.openclaw-ios.diagnostic-event.v1"

    public let schema: String
    public let observedAt: String
    public let kind: Kind
    public let state: String
    public let socketGeneration: UInt64?
    public let routeGeneration: UInt64?
    public let activityGeneration: UInt64?
    public let sessionHash: String?
    public let runID: String?
    public let messageID: String?
    public let eventID: String?
    public let operationID: String?
    public let sequence: Int?
    public let stream: String?
    public let networkInterfaces: [String]

    public init(
        kind: Kind,
        state: String,
        socketGeneration: UInt64? = nil,
        routeGeneration: UInt64? = nil,
        activityGeneration: UInt64? = nil,
        sessionIdentifier: String? = nil,
        runIdentifier: String? = nil,
        messageIdentifier: String? = nil,
        eventIdentifier: String? = nil,
        operationIdentifier: String? = nil,
        sequence: Int? = nil,
        stream: String? = nil,
        networkInterfaces: [String] = [],
        observedAt: Date = Date())
    {
        self.schema = Self.schemaName
        self.observedAt = Self.timestamp(observedAt)
        self.kind = kind
        self.state = Self.sanitizedToken(state, maximumLength: 64) ?? "redacted"
        self.socketGeneration = socketGeneration
        self.routeGeneration = routeGeneration
        self.activityGeneration = activityGeneration
        self.sessionHash = Self.hashedIdentifier(sessionIdentifier)
        self.runID = Self.hashedIdentifier(runIdentifier)
        self.messageID = Self.hashedIdentifier(messageIdentifier)
        self.eventID = Self.hashedIdentifier(eventIdentifier)
        self.operationID = Self.hashedIdentifier(operationIdentifier)
        self.sequence = sequence.flatMap { $0 >= 0 ? $0 : nil }
        self.stream = Self.sanitizedToken(stream, maximumLength: 64)
        let sanitizedInterfaces = Array(Set(networkInterfaces.compactMap {
            Self.sanitizedToken($0, maximumLength: 32)
        })).sorted()
        self.networkInterfaces = Array(sanitizedInterfaces.prefix(8))
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case observedAt = "observed_at"
        case kind
        case state
        case socketGeneration = "socket_generation"
        case routeGeneration = "route_generation"
        case activityGeneration = "activity_generation"
        case sessionHash = "session_hash"
        case runID = "run_id"
        case messageID = "message_id"
        case eventID = "event_id"
        case operationID = "operation_id"
        case sequence
        case stream
        case networkInterfaces = "network_interfaces"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func hashedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096 else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedToken(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumLength else { return nil }
        let isSafe = trimmed.utf8.allSatisfy { byte in
            switch byte {
            case 45...46, 48...58, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
        return isSafe ? trimmed : nil
    }

    fileprivate var isValidDecodedRecord: Bool {
        guard self.schema == Self.schemaName,
              Self.isValidTimestamp(self.observedAt),
              self.state == Self.sanitizedToken(self.state, maximumLength: 64),
              self.runID.map(Self.isLowercaseHexDigest) ?? true,
              self.messageID.map(Self.isLowercaseHexDigest) ?? true,
              self.eventID.map(Self.isLowercaseHexDigest) ?? true,
              self.operationID.map(Self.isLowercaseHexDigest) ?? true,
              self.stream == Self.sanitizedToken(self.stream, maximumLength: 64),
              self.sequence.map({ $0 >= 0 }) ?? true,
              self.networkInterfaces.count <= 8,
              self.networkInterfaces == Array(Set(self.networkInterfaces)).sorted(),
              self.networkInterfaces.allSatisfy({
                  $0 == Self.sanitizedToken($0, maximumLength: 32)
              }),
              self.sessionHash.map(Self.isLowercaseHexDigest) ?? true
        else {
            return false
        }
        return true
    }

    private static func isValidTimestamp(_ value: String) -> Bool {
        guard value.utf8.count == 24 else { return false }
        let bytes = Array(value.utf8)
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90]
        for (index, byte) in bytes.enumerated() {
            if let separator = separators[index] {
                guard byte == separator else { return false }
            } else if !(48...57).contains(byte) {
                return false
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private static func isLowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum OpenClawDiagnosticRecorder {
    public typealias Sink = @Sendable (String) -> Void

    private static let sink = OSAllocatedUnfairLock<Sink?>(initialState: nil)
    private static let recordPrefix = "aies_diagnostic="
    private static let maximumEncodedRecordBytes = 8192
    private static let requiredKeys: Set<String> = [
        "schema",
        "observed_at",
        "kind",
        "state",
        "network_interfaces",
    ]
    private static let allowedKeys = OpenClawDiagnosticRecorder.requiredKeys.union([
        "socket_generation",
        "route_generation",
        "activity_generation",
        "session_hash",
        "run_id",
        "message_id",
        "event_id",
        "operation_id",
        "sequence",
        "stream",
    ])

    public static func installSink(_ sink: @escaping Sink) {
        self.sink.withLock { current in
            current = sink
        }
    }

    public static func clearSink() {
        self.sink.withLock { current in
            current = nil
        }
    }

    public static func record(_ event: OpenClawDiagnosticEvent) {
        guard event.isValidDecodedRecord else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(event) else { return }
        let line = self.recordPrefix + encoded.base64EncodedString()
        let currentSink = self.sink.withLock { $0 }
        currentSink?(line)
    }

    public static func decodeRecord(_ record: String) -> OpenClawDiagnosticEvent? {
        guard record.utf8.count <= self.maximumEncodedRecordBytes,
              record.hasPrefix(self.recordPrefix),
              !record.contains(where: { $0.isWhitespace })
        else {
            return nil
        }
        let encoded = String(record.dropFirst(self.recordPrefix.count))
        guard let data = Data(base64Encoded: encoded),
              data.count <= self.maximumEncodedRecordBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let keys = Set(object.keys)
        guard self.requiredKeys.isSubset(of: keys), keys.isSubset(of: self.allowedKeys),
              let event = try? JSONDecoder().decode(OpenClawDiagnosticEvent.self, from: data),
              event.isValidDecodedRecord
        else {
            return nil
        }
        return event
    }
}
