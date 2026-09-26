import Darwin
import SwiftUI

enum SettingsRoute: Hashable {
    case gateway
    case approvals
    case adminApprovals
    case permissions
    case voice
    case diagnostics
    case privacy
    case notifications
    case about
}

enum SettingsLayout {
    static let cardRadius: CGFloat = 12
    static let rowHeight: CGFloat = 58
}

struct SettingsApprovalItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let priority: String
    let color: Color
}

struct SettingsApprovalRow: View {
    let item: SettingsApprovalItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: self.item.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.item.color)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(self.item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(self.item.detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(self.item.priority)
                .font(.caption.weight(.bold))
                .foregroundStyle(self.item.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    Capsule()
                        .fill(self.item.color.opacity(0.10))
                }
        }
        .padding(.vertical, 7)
    }
}

enum SettingsDiagnosticIssue: String, Equatable, CaseIterable {
    case gatewayOffline
    case discoveryUnavailable
    case talkConfigMissing
    case notificationsUnavailable
    case notificationsNotRequested
    case notificationsUnknown

    var summary: String {
        switch self {
        case .gatewayOffline: "Gateway connection was unavailable."
        case .discoveryUnavailable:
            "Network discovery had no results yet at this check. It may still be searching; manually configured gateways can remain connected."
        case .talkConfigMissing: "Voice configuration was unavailable from the connected gateway."
        case .notificationsUnavailable: "Notification permission was denied."
        case .notificationsNotRequested: "Notification permission had not been requested."
        case .notificationsUnknown: "Notification permission could not be determined."
        }
    }
}

struct SettingsDiagnosticRunIssues: View {
    let issues: [SettingsDiagnosticIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checks needing attention at that run")
                .font(.caption.weight(.semibold))
            ForEach(self.issues, id: \.rawValue) { issue in
                Text(issue.summary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.secondary)
    }
}

enum SettingsDiagnostics {
    static func issues(
        gatewayConnected: Bool,
        discoveredGatewayCount: Int,
        talkConfigLoaded: Bool,
        notificationStatusText: String) -> [SettingsDiagnosticIssue]
    {
        var issues: [SettingsDiagnosticIssue] = []
        if !gatewayConnected { issues.append(.gatewayOffline) }
        if discoveredGatewayCount == 0 { issues.append(.discoveryUnavailable) }
        if gatewayConnected, !talkConfigLoaded { issues.append(.talkConfigMissing) }
        switch notificationStatusText {
        case "Allowed": break
        case "Not Allowed": issues.append(.notificationsUnavailable)
        case "Not Set": issues.append(.notificationsNotRequested)
        default: issues.append(.notificationsUnknown)
        }
        return issues
    }

    static func issueCount(
        gatewayConnected: Bool,
        discoveredGatewayCount: Int,
        talkConfigLoaded: Bool,
        notificationStatusText: String) -> Int
    {
        self.issues(
            gatewayConnected: gatewayConnected,
            discoveredGatewayCount: discoveredGatewayCount,
            talkConfigLoaded: talkConfigLoaded,
            notificationStatusText: notificationStatusText).count
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

extension SettingsProTab {
    static func hasTailnetIPv4() -> Bool {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0, let first = addrList else { return false }
        defer { freeifaddrs(addrList) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard let addrPtr = ptr.pointee.ifa_addr else { continue }
            let family = addrPtr.pointee.sa_family
            if !isUp || isLoopback || family != UInt8(AF_INET) { continue }
            var addr = addrPtr.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &addr,
                socklen_t(addrPtr.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST)
            guard result == 0 else { continue }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            guard let ip = String(bytes: bytes, encoding: .utf8) else { continue }
            if self.isTailnetIPv4(ip) { return true }
        }
        return false
    }

    static func isTailnetHostOrIP(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix(".ts.net") || trimmed.hasSuffix(".ts.net.") { return true }
        return self.isTailnetIPv4(trimmed)
    }

    static func isTailnetIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        let a = octets[0]
        let b = octets[1]
        guard (0...255).contains(a), (0...255).contains(b) else { return false }
        return a == 100 && b >= 64 && b <= 127
    }
}
