import ActivityKit
import Foundation

/// Fixed public copy shared with the extension. Private task text never enters
/// an ActivityKit content state, including when execution ends blocked.
enum ArgusTaskActivityPhase: String, Codable, Sendable {
    case queued, running, succeeded, blocked, failed, cancelled, lost
    case timedOut = "timed_out"

    var headline: String {
        switch self {
        case .queued: "Task queued"
        case .running: "Task running"
        case .succeeded: "Execution finished"
        case .blocked: "Task blocked"
        case .failed: "Task failed"
        case .timedOut: "Task timed out"
        case .cancelled: "Task cancelled"
        case .lost: "Task status lost"
        }
    }

    var isTerminal: Bool { self != .queued && self != .running }
}

struct ArgusTaskActivityState: Codable, Hashable, Sendable {
    let phase: ArgusTaskActivityPhase
    let lifecycleRevision: UInt64
    let expiresAtMs: Int64
    var trackingEnded = false
    var expiresAt: Date { Date(timeIntervalSince1970: Double(self.expiresAtMs) / 1000) }
}

/// An opaque read-only destination. Identity is checked again by the authenticated
/// operator reader; a widget URL never supplies a message or gateway credentials.
struct ArgusTaskActivityReference: Codable, Hashable, Sendable {
    let gatewayDeviceID: String
    let taskID: String
    let requestID: String

    init?(gatewayDeviceID: String, taskID: String, requestID: String) {
        guard Self.validIdentity(gatewayDeviceID, limit: 128),
              Self.validTaskID(taskID),
              Self.validRequestID(requestID)
        else { return nil }
        self.gatewayDeviceID = gatewayDeviceID
        self.taskID = taskID
        self.requestID = requestID
    }

    private enum CodingKeys: String, CodingKey {
        case gatewayDeviceID, taskID, requestID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let reference = Self(
            gatewayDeviceID: try values.decode(String.self, forKey: .gatewayDeviceID),
            taskID: try values.decode(String.self, forKey: .taskID),
            requestID: try values.decode(String.self, forKey: .requestID))
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid task activity reference"))
        }
        self = reference
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "openclaw"
        components.host = "task"
        components.queryItems = [
            .init(name: "gateway", value: self.gatewayDeviceID),
            .init(name: "task", value: self.taskID),
            .init(name: "request", value: self.requestID),
        ]
        return components.url
    }

    static func parse(_ url: URL) -> Self? {
        guard url.absoluteString.utf8.count <= 16_384,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "openclaw",
              components.host?.lowercased() == "task",
              components.user == nil, components.password == nil,
              components.port == nil, components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 3,
              Set(items.map(\.name)) == Set(["gateway", "task", "request"]),
              let gateway = items.first(where: { $0.name == "gateway" })?.value,
              let task = items.first(where: { $0.name == "task" })?.value,
              let request = items.first(where: { $0.name == "request" })?.value
        else { return nil }
        return Self(gatewayDeviceID: gateway, taskID: task, requestID: request)
    }

    static func validTaskID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    static func validRequestID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func isAlphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard (1...256).contains(bytes.count), let first = bytes.first, isAlphanumeric(first) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || [46, 95, 58, 45].contains($0) }
    }

    private static func validIdentity(_ value: String, limit: Int) -> Bool {
        (1...limit).contains(value.utf8.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

/// Shared schema used by iOS app + Live Activity widget extension.
struct OpenClawActivityAttributes: ActivityAttributes {
    var agentName: String
    var sessionKey: String
    var taskReference: ArgusTaskActivityReference? = nil
    // Fixed for this ActivityKit identity; separate from task lifecycle revisions
    // and the process-local rendering worker's generation. Older local activities omit it.
    var pushGeneration: UInt64? = nil

    struct ContentState: Codable, Hashable {
        var statusText: String
        var isIdle: Bool
        var isDisconnected: Bool
        var isConnecting: Bool
        var startedAt: Date
        var task: ArgusTaskActivityState? = nil
    }
}

#if DEBUG
extension OpenClawActivityAttributes {
    static let preview = OpenClawActivityAttributes(agentName: "main", sessionKey: "main")
}

extension OpenClawActivityAttributes.ContentState {
    static let connecting = OpenClawActivityAttributes.ContentState(
        statusText: "Connecting...",
        isIdle: false,
        isDisconnected: false,
        isConnecting: true,
        startedAt: .now)

    static let idle = OpenClawActivityAttributes.ContentState(
        statusText: "Idle",
        isIdle: true,
        isDisconnected: false,
        isConnecting: false,
        startedAt: .now)

    static let disconnected = OpenClawActivityAttributes.ContentState(
        statusText: "Disconnected",
        isIdle: false,
        isDisconnected: true,
        isConnecting: false,
        startedAt: .now)

    static let attention = OpenClawActivityAttributes.ContentState(
        statusText: "Approval needed",
        isIdle: false,
        isDisconnected: false,
        isConnecting: false,
        startedAt: .now)
}
#endif
