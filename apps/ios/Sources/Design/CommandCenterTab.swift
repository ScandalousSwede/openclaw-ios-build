import OpenClawChatUI
import SwiftUI

struct CommandCenterTab: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessionList = CommandSessionListState()
    let workStore: ArgusOperationsStore
    let workClient: ArgusOperationsClient?
    var openWork: () -> Void
    var openChat: () -> Void
    var openSettings: () -> Void

    enum WorkRoute {
        case chat(String?)
        case settings
    }

    struct WorkItem: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let state: String
        let trailing: String
        let color: Color
        let progress: Double?
        let route: WorkRoute
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CommandControlBackground()
                self.commandAmbientOverlay
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        self.header
                        ArgusHomeResultContent(store: self.workStore, client: self.workClient, openWork: self.openWork)
                        if self.appModel.lastArgusEvidenceNotificationRequest != nil {
                            CommandPanel(padding: 12) {
                                ArgusEvidenceResumeButton {
                                    self.appModel.reopenLastArgusEvidenceNotification()
                                }
                            }
                            .padding(.horizontal, OpenClawProMetric.pagePadding)
                        }
                        self.gatewayCard
                        self.defaultChatSessionSection
                        self.recentSessions
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                }
                .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
            }
            .navigationBarHidden(true)
            .navigationDestination(item: Binding(
                get: { self.appModel.argusEvidenceNotificationRequest },
                set: { self.appModel.argusEvidenceNotificationRequest = $0 }))
            { request in
                ArgusEvidenceNotificationView(request: request).id(request.id)
            }
        }
        .task(id: self.recentSessionsRefreshID) {
            await self.appModel.refreshCommandSessions(self.sessionList, active: self.scenePhase == .active)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            OpenClawProMark(size: 42, shadowRadius: 4)
            Text("ARGUS")
                .font(.title2.weight(.medium))
                .tracking(4.5)
            Spacer()
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    @ViewBuilder
    private var commandAmbientOverlay: some View {
        if self.colorScheme == .light {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private var gatewayCard: some View {
        CommandPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Gateway")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 8)
                    CommandGatewayStatus()
                }

                DisclosureGroup("Connection details") {
                    CommandGatewayFacts(
                        nodeStatus: self.appModel.nodeRoleState.statusLabel,
                        operatorStatus: self.appModel.operatorRoleState.statusLabel,
                        agentCount: self.gatewayAgentCountText)
                        .padding(.top, 8)
                }
                .font(.subheadline)
                .tint(OpenClawBrand.accent)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var defaultChatSessionSection: some View {
        CommandPanel(padding: 12) {
            VStack(spacing: 10) {
                self.cardHeader(
                    title: "Agent session",
                    value: nil,
                    color: OpenClawBrand.accent)

                Button {
                    self.open(.chat(nil))
                } label: {
                    CommandSessionRow(item: self.defaultChatWorkItem)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var recentSessions: some View {
        let renderedOwner = self.appModel.commandSessionListOwner
        return CommandPanel(padding: 12) {
            VStack(spacing: 10) {
                self.cardHeader(
                    title: "Recent sessions",
                    value: nil,
                    color: .secondary)

                if let notice = self.sessionList.notice(
                    for: renderedOwner, available: self.appModel.isCommandSessionListAvailable)
                {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if self.recentSessionPreviewRows.isEmpty {
                    CommandEmptyStateRow(
                        icon: self.gatewayConnected ? "bubble.left.and.text.bubble.right.fill" : "wifi.slash",
                        title: self.sessionList.emptyTitle(
                            for: renderedOwner, available: self.appModel.isCommandSessionListAvailable),
                        detail: "Recent conversations will appear here when available.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(self.recentSessionPreviewRows) { item in
                            Button {
                                guard case let .chat(key?) = item.route,
                                      self.sessionList.canOpen(
                                          sessionKey: key, renderedOwner: renderedOwner,
                                          currentOwner: self.appModel.commandSessionListOwner)
                                else { return }
                                self.open(item.route)
                            } label: {
                                CommandSessionRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }

                        if self.hasMoreRecentSessions {
                            NavigationLink {
                                CommandSessionsScreen(sessionList: self.sessionList, openChat: self.openChat)
                            } label: {
                                CommandViewMoreRow()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private func cardHeader(
        title: String,
        value: String?,
        color: Color,
        icon: String? = nil,
        badgeValue: String? = nil,
        action: (() -> Void)? = nil) -> some View
    {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.bold))
            if let badgeValue {
                Text(badgeValue)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(OpenClawBrand.accentInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(OpenClawBrand.accentHot, in: Capsule())
            }
            Spacer(minLength: 8)
            if let value {
                if let action {
                    Button(value, action: action)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                } else {
                    HStack(spacing: 4) {
                        if let icon {
                            Image(systemName: icon)
                                .font(.caption2.weight(.bold))
                        }
                        Text(value)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                }
            }
        }
    }

    private var gatewayConnected: Bool {
        GatewayStatusBuilder.build(appModel: self.appModel) == .connected
    }

    private var gatewayAddressText: String {
        self.normalized(self.appModel.gatewayRemoteAddress)
            ?? self.normalized(self.appModel.gatewayServerName)
            ?? "Unknown"
    }

    private var gatewayAgentCountText: String {
        self.appModel.gatewayAgentCountText
    }

    private var defaultChatWorkItem: WorkItem {
        let isOpen = self.appModel.chatSessionKey == self.appModel.defaultChatSessionKey
        return WorkItem(
            id: "default-chat",
            icon: isOpen ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.fill",
            title: self.appModel.activeAgentName,
            detail: self.defaultChatActivityText,
            state: isOpen ? "open" : "default",
            trailing: "chat",
            color: isOpen ? OpenClawBrand.accent : OpenClawBrand.ok,
            progress: nil,
            route: .chat(nil))
    }

    private var defaultChatActivityText: String {
        guard let updatedAt = self.sessionList.entries(for: self.appModel.commandSessionListOwner)
            .first(where: { $0.key == self.appModel.defaultChatSessionKey })?.updatedAt, updatedAt > 0
        else {
            return "No recent activity"
        }
        return Self.relativeTimeText(forMilliseconds: updatedAt)
    }

    private var recentSessionRows: [WorkItem] {
        self.sessionItems
    }

    private var recentSessionPreviewRows: [WorkItem] {
        Array(self.recentSessionRows.prefix(3))
    }

    private var hasMoreRecentSessions: Bool {
        self.sessionWorkItems.count > self.recentSessionPreviewRows.count
    }

    private var recentSessionsRefreshID: CommandSessionListState.RefreshID {
        self.appModel.commandSessionListRefreshID(active: self.scenePhase == .active)
    }

    private var sessionItems: [WorkItem] {
        self.sessionWorkItems
    }

    private var sessionWorkItems: [WorkItem] {
        let currentSessionKey = self.appModel.chatSessionKey
        return Self.sessionChoices(
            self.sessionList.entries(for: self.appModel.commandSessionListOwner),
            currentSessionKey: currentSessionKey,
            defaultSessionKey: self.appModel.defaultChatSessionKey)
            .filter { Self.isRecentChatSession($0.key, defaultSessionKey: self.appModel.defaultChatSessionKey) }
            .map { session in
                Self.sessionWorkItem(for: session, currentSessionKey: currentSessionKey)
            }
    }

    private func open(_ route: WorkRoute) {
        switch route {
        case let .chat(sessionKey):
            self.appModel.openChat(sessionKey: sessionKey)
            self.openChat()
        case .settings:
            self.openSettings()
        }
    }

    private static func sessionChoices(
        _ sessions: [OpenClawChatSessionEntry],
        currentSessionKey: String,
        defaultSessionKey: String) -> [OpenClawChatSessionEntry]
    {
        let sorted = sessions.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        var result: [OpenClawChatSessionEntry] = []
        var included = Set<String>()

        if Self.isRecentChatSession(currentSessionKey, defaultSessionKey: defaultSessionKey),
           let current = sorted.first(where: { $0.key == currentSessionKey })
        {
            result.append(current)
            included.insert(current.key)
        }

        for session in sorted {
            guard !included.contains(session.key) else { continue }
            guard Self.isRecentChatSession(session.key, defaultSessionKey: defaultSessionKey) else { continue }
            result.append(session)
            included.insert(session.key)
            if result.count >= 4 {
                break
            }
        }

        return result
    }

    fileprivate static func sessionWorkItem(
        for session: OpenClawChatSessionEntry,
        currentSessionKey: String) -> WorkItem
    {
        let isCurrent = session.key == currentSessionKey
        return WorkItem(
            id: "chat-session-\(session.key)",
            icon: isCurrent ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.fill",
            title: Self.sessionTitle(session),
            detail: Self.sessionDetail(session),
            state: isCurrent ? "open" : "recent",
            trailing: "chat",
            color: isCurrent ? OpenClawBrand.accent : OpenClawBrand.ok,
            progress: nil,
            route: .chat(session.key))
    }

    fileprivate static func sessionTitle(_ session: OpenClawChatSessionEntry) -> String {
        if let title = redactedSessionTitle(for: session.key) {
            return title
        }

        let displayName = session.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let displayName, !displayName.isEmpty {
            return Self.redactedSessionTitle(for: displayName) ?? displayName
        }
        let subject = session.subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let subject, !subject.isEmpty {
            return Self.redactedSessionTitle(for: subject) ?? subject
        }
        return session.key
    }

    fileprivate static func redactedSessionTitle(for key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard !trimmed.isEmpty else { return nil }
        if lowercased.contains(":ios-") {
            return "iOS chat"
        }
        if lowercased.hasPrefix("telegram:") {
            return "Telegram chat"
        }
        if lowercased.hasPrefix("user:+") {
            return "Direct chat"
        }
        if lowercased.hasPrefix("cron:") {
            return Self.humanizedSessionKey(String(trimmed.dropFirst("cron:".count)))
        }
        return nil
    }

    fileprivate static func humanizedSessionKey(_ key: String) -> String? {
        let words = key
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        return words
            .map { word in
                switch word.lowercased() {
                case "ai", "api", "ios", "qmd", "url":
                    word.uppercased()
                default:
                    word.prefix(1).uppercased() + String(word.dropFirst())
                }
            }
            .joined(separator: " ")
    }

    fileprivate static func sessionDetail(_ session: OpenClawChatSessionEntry) -> String {
        if let updatedAt = session.updatedAt, updatedAt > 0 {
            return self.relativeTimeText(forMilliseconds: updatedAt)
        }
        return session.key
    }

    fileprivate static func relativeTimeText(forMilliseconds milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    fileprivate nonisolated static func isHiddenInternalSession(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed == "onboarding" || trimmed.hasSuffix(":onboarding")
    }

    nonisolated static func isRecentChatSession(_ key: String, defaultSessionKey: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == defaultSessionKey {
            return false
        }
        let normalized = trimmed.lowercased()
        let defaultBase = self.sessionBaseKey(defaultSessionKey)
        if !normalized.contains(":"),
           self.isDirectSessionBase(normalized, defaultBase: defaultBase)
        {
            return false
        }
        if self.isHiddenInternalSession(trimmed) {
            return false
        }
        return !self.isAgentDeviceSession(trimmed, defaultSessionKey: defaultSessionKey)
    }

    private nonisolated static func isAgentDeviceSession(_ key: String, defaultSessionKey: String) -> Bool {
        let parts = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].lowercased() == "agent" else { return false }
        guard parts.count == 3 || parts[3].lowercased() == "thread" else { return false }

        let base = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let defaultKey = self.sessionBaseKey(defaultSessionKey)
        return self.isDirectSessionBase(base, defaultBase: defaultKey)
    }

    private nonisolated static func isDirectSessionBase(_ base: String, defaultBase: String) -> Bool {
        base == defaultBase || base == "main" || base == "global" || base.hasPrefix("node-")
    }

    private nonisolated static func sessionBaseKey(_ key: String) -> String {
        let parts = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].lowercased() == "agent" else {
            return key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var gatewaySubtitle: String {
        if let server = normalized(appModel.gatewayServerName) {
            return "\(self.appModel.activeAgentName) on \(server)"
        }
        if let address = normalized(appModel.gatewayRemoteAddress) {
            return "\(self.appModel.activeAgentName) via \(address)"
        }
        return self.appModel.gatewayDisplayStatusText
    }

    private func normalized(_ value: String?) -> String? {
        Self.normalized(value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CommandSessionsScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let sessionList: CommandSessionListState
    let openChat: () -> Void

    var body: some View {
        ZStack {
            CommandControlBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    self.header
                    self.sessionsPanel
                }
                .padding(.top, 16)
                .padding(.bottom, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: self.refreshID) {
            await self.appModel.refreshCommandSessions(self.sessionList, active: self.scenePhase == .active)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions")
                .font(.system(size: 27, weight: .bold, design: .rounded))
            Text(self.headerDetail)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var sessionsPanel: some View {
        let renderedOwner = self.appModel.commandSessionListOwner
        return CommandPanel(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Recent sessions")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 8)
                    if self.sessionList.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 3)

                if let notice = self.sessionList.notice(
                    for: renderedOwner, available: self.appModel.isCommandSessionListAvailable)
                {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
                if self.sessionRows.isEmpty {
                    CommandEmptyStateRow(
                        icon: self.appModel
                            .isCommandSessionListAvailable ? "bubble.left.and.text.bubble.right.fill" : "wifi.slash",
                        title: self.sessionList.emptyTitle(
                            for: renderedOwner, available: self.appModel.isCommandSessionListAvailable),
                        detail: "Recent conversations will appear here when available.")
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                } else {
                    VStack(spacing: 8) {
                        ForEach(self.sessionRows) { item in
                            Button {
                                guard case let .chat(key?) = item.route,
                                      self.sessionList.canOpen(
                                          sessionKey: key, renderedOwner: renderedOwner,
                                          currentOwner: self.appModel.commandSessionListOwner)
                                else { return }
                                self.open(item)
                            } label: {
                                CommandSessionRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var headerDetail: String {
        if self.sessionList.isLoading, self.sessionRows.isEmpty {
            return "Loading recent sessions"
        }
        let count = self.sessionRows.count
        if count == 0 {
            return self.sessionList.emptyTitle(
                for: self.appModel.commandSessionListOwner, available: self.appModel.isCommandSessionListAvailable)
        }
        return "\(count) \(count == 1 ? "session" : "sessions")"
    }

    private var sessionRows: [CommandCenterTab.WorkItem] {
        self.sessionList.entries(for: self.appModel.commandSessionListOwner)
            .filter { CommandCenterTab.isRecentChatSession(
                $0.key,
                defaultSessionKey: self.appModel.defaultChatSessionKey) }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            .map {
                CommandCenterTab.sessionWorkItem(
                    for: $0,
                    currentSessionKey: self.appModel.chatSessionKey)
            }
    }

    private var refreshID: CommandSessionListState.RefreshID {
        self.appModel.commandSessionListRefreshID(active: self.scenePhase == .active)
    }

    private func open(_ item: CommandCenterTab.WorkItem) {
        switch item.route {
        case let .chat(sessionKey):
            self.appModel.openChat(sessionKey: sessionKey)
            self.dismiss()
            self.openChat()
        case .settings:
            break
        }
    }
}
