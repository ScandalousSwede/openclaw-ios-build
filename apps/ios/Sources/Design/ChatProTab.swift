import OpenClawChatUI
import OpenClawProtocol
import SwiftUI

struct ChatPreparationRetryState: Equatable {
    private(set) var nonce: UInt64 = 0

    mutating func request() {
        self.nonce &+= 1
    }

    mutating func gatewayDidConnect(hasAttachedViewModel: Bool) {
        guard !hasAttachedViewModel else { return }
        self.request()
    }

    func taskID(owner: String, ownerGeneration: UInt64) -> String {
        "\(owner)|\(ownerGeneration)|\(self.nonce)"
    }
}

enum ChatConnectionPresentation {
    static func readinessText(
        blockingText: String?, gatewayConnected: Bool, hasViewModel: Bool,
        isLoading: Bool, hasError: Bool) -> String?
    {
        if let blockingText { return blockingText }
        if !gatewayConnected { return "Connecting" }
        if hasError { return "Chat needs attention" }
        if !hasViewModel { return "Preparing chat" }
        if isLoading { return "Loading chat" }
        return nil
    }

    static func blockingText(
        deliveryGate: OpenClawChatOutboxStatus.DeliveryGate?,
        nodeState: GatewayNodeRoleState,
        operatorState: GatewayOperatorRoleState) -> String?
    {
        // Role issuance and granted-scope state are authoritative. Current
        // operator availability also precedes route-gate snapshots, because a
        // retained gate from a retired route must not hide the live state.
        switch operatorState {
        case .missingRole:
            return "Operator role missing"
        case .scopeBlocked:
            return "Operator scopes unavailable"
        case .offline where nodeState == .online:
            return "Operator session unavailable"
        case .offline:
            return "Gateway offline"
        case .connecting:
            return "Operator connecting"
        case .online:
            break
        }
        if let deliveryGate {
            switch deliveryGate {
            case .operatorRoleMissing:
                return "Operator role missing"
            case .operatorSessionUnavailable:
                return "Operator session unavailable"
            case .operatorScopesUnavailable:
                return "Operator scopes unavailable"
            case .routingContractUnavailable, .capabilityUnavailable, .unsupportedClient:
                return "Routing contract unavailable"
            case .gatewayIdentityUnavailable, .gatewayMismatch:
                return "Gateway identity unavailable"
            case .offline:
                return "Gateway offline"
            }
        }
        return nil
    }

    static func messagePlaceholder(
        agentName: String,
        blockingText: String?,
        gatewayConnected: Bool,
        canQueueOffline: Bool,
        supportsDurableOutbox: Bool) -> String
    {
        if let blockingText {
            return canQueueOffline ? "\(blockingText) — messages queue locally" : blockingText
        }
        if gatewayConnected { return "Message \(agentName)..." }
        if canQueueOffline { return "Message \(agentName) (queues offline)" }
        if supportsDurableOutbox { return "Connect once to enable offline queueing" }
        return "Connect to a gateway"
    }
}

struct ChatProTab: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: OpenClawChatViewModel?
    @State private var confirmsUnreadableDraftDiscard = false
    @State private var unreadableDraftTarget: OpenClawChatViewModel?
    @State private var viewModelOwner: String?
    @State private var viewModelResetGeneration: UInt64 = 0
    @State private var chatPreparationError: String?
    @State private var chatPreparationRetry = ChatPreparationRetryState()
    @State private var resultAskError: String?
    @State private var resultAskRetry = 0

    var body: some View {
        NavigationStack {
            ZStack {
                OpenClawProBackground()
                VStack(spacing: 0) {
                    self.header
                    if let viewModel = self.currentViewModel {
                        if let resultAskError {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(resultAskError).font(.subheadline)
                                Button("Retry adding result") { self.resultAskRetry &+= 1 }
                            }
                            .padding(.horizontal, OpenClawProMetric.pagePadding)
                        }
                        if viewModel.attachments.contains(where: { $0.resultSource != nil }) {
                            ScrollView {
                                VStack(spacing: 8) {
                                    ForEach(viewModel.attachments.filter { $0.resultSource != nil }) { attachment in
                                        ArgusResultSourceCard(attachment: attachment)
                                    }
                                }
                                .padding(.horizontal, OpenClawProMetric.pagePadding)
                            }
                            .frame(maxHeight: 210)
                        }
                        if let status = viewModel.composerDraftStatus {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if viewModel.composerDraftRestoreFailed {
                                    Button("Retry draft") { viewModel.retryComposerDraftRestore() }
                                    if viewModel.canDiscardUnreadableComposerDraft {
                                        Button("Discard unreadable draft", role: .destructive) {
                                            self.unreadableDraftTarget = viewModel
                                            self.confirmsUnreadableDraftDiscard = true
                                        }
                                    }
                                } else if viewModel.composerDraftSaveFailed {
                                    Button("Retry save") { Task { await viewModel.flushComposerDraft() } }
                                }
                            }
                            .padding(.horizontal, OpenClawProMetric.pagePadding)
                            .padding(.vertical, 4)
                        }
                        OpenClawChatView(
                            viewModel: viewModel,
                            drawsBackground: false,
                            showsSessionSwitcher: false,
                            userAccent: self.chatUserAccent,
                            assistantName: self.agentDisplayName,
                            assistantAvatarText: self.agentBadge,
                            assistantAvatarTint: OpenClawBrand.accent,
                            showsAssistantAvatars: false,
                            composerChrome: .clean,
                            isComposerEnabled: self.gatewayConnected || viewModel.supportsDurableOutbox,
                            messagePlaceholder: self.messagePlaceholder,
                            talkControl: self.talkControl)
                            .id(ObjectIdentifier(viewModel))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else if let chatPreparationError {
                        ProCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Chat is unavailable")
                                    .font(.headline)
                                Text(chatPreparationError)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button("Retry") {
                                    self.requestChatPreparationRetry()
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityHint("Retries opening protected durable chat storage")
                            }
                        }
                        .padding()
                        Spacer()
                    } else {
                        ProCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Chat is preparing")
                                    .font(.headline)
                                Text("The operator session will attach when the gateway is ready.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationBarHidden(true)
        }
        .alert("Discard unreadable draft?", isPresented: self.$confirmsUnreadableDraftDiscard) {
            Button("Discard draft", role: .destructive) {
                guard let target = self.unreadableDraftTarget, self.currentViewModel === target else { return }
                self.unreadableDraftTarget = nil
                Task { await target.discardUnreadableComposerDraft() }
            }
            Button("Cancel", role: .cancel) { self.unreadableDraftTarget = nil }
        } message: {
            Text("This permanently removes this chat’s unreadable unsent text and attachments from this device. Other drafts and queued messages are kept.")
        }
        .task(id: self.chatOwnerTaskID) {
            await self.prepareChatViewModel(taskID: self.chatOwnerTaskID)
        }
        .task(id: self.resultAskTaskID) {
            await self.consumeResultAskRequest()
        }
        .onChange(of: self.appModel.chatSessionKey) { _, _ in
            self.currentViewModel?.syncSession(to: self.appModel.chatSessionKey)
        }
        .onChange(of: self.scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await self.currentViewModel?.flushComposerDraft() }
        }
        .onDisappear {
            Task { await self.currentViewModel?.flushComposerDraft() }
        }
        .onChange(of: self.appModel.isOperatorGatewayConnected) { _, connected in
            guard connected else { return }
            if let viewModel = self.currentViewModel {
                viewModel.refresh()
            } else {
                // One retry per reconnect edge. Persistent failures remain a
                // stable error with an explicit user action; never spin.
                self.chatPreparationRetry.gatewayDidConnect(hasAttachedViewModel: false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Text(self.agentBadge)
                .font(.system(size: self.agentBadge.count > 2 ? 13 : 16, weight: .bold, design: .rounded))
                .foregroundStyle(OpenClawBrand.accentInk)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    OpenClawBrand.accent,
                                    OpenClawBrand.accentHot,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: OpenClawBrand.accent.opacity(0.18), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(self.agentDisplayName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text("AI Assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            self.connectionPill
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var chatOwnerTaskID: String {
        self.chatPreparationRetry.taskID(
            owner: self.chatOwnerID,
            ownerGeneration: self.appModel.chatOutboxOwnerGeneration)
    }

    private var resultAskTaskID: String {
        let modelID = self.currentViewModel.map { String(describing: ObjectIdentifier($0)) } ?? "unavailable"
        return "\(modelID)|\(self.appModel.resultAskRequest?.id.uuidString ?? "none")|\(self.resultAskRetry)"
    }

    private func consumeResultAskRequest() async {
        self.resultAskError = nil
        guard let request = self.appModel.resultAskRequest, let viewModel = self.currentViewModel,
              request.gatewayID == self.chatOwnerID,
              request.resetGeneration == self.appModel.chatOutboxOwnerGeneration else { return }
        let saved = await viewModel.retainResultAttachment(request.attachment, sessionKey: request.sessionKey)
        guard !Task.isCancelled, self.currentViewModel === viewModel,
              self.appModel.resultAskRequest?.id == request.id else { return }
        if saved {
            self.appModel.consumeResultAskRequest(request.id)
        } else {
            self.resultAskError = "The result could not be saved with this draft. Your message has not been sent. Return to the selected chat or retry."
        }
    }

    private var currentViewModel: OpenClawChatViewModel? {
        guard self.viewModelOwner == self.chatOwnerID,
              self.viewModelResetGeneration == self.appModel.chatOutboxOwnerGeneration else { return nil }
        return self.viewModel
    }

    private var chatOwnerID: String {
        self.appModel.isAppleReviewDemoModeEnabled
            ? "apple-review-demo"
            : (self.appModel.chatOutboxGatewayOwnerID ?? "unavailable")
    }

    private func requestChatPreparationRetry() {
        self.chatPreparationRetry.request()
    }

    private func prepareChatViewModel(taskID: String) async {
        let priorViewModel = self.viewModel
        if let priorViewModel,
           self.viewModelResetGeneration == self.appModel.chatOutboxOwnerGeneration {
            guard await priorViewModel.prepareForReplacement() else {
                // Keep the only visible buffer alive on storage failure. A different
                // gateway cannot display it; returning to its owner permits repair.
                guard !Task.isCancelled, taskID == self.chatOwnerTaskID else { return }
                self.chatPreparationError = "An unsent draft could not be saved. Return to its gateway to edit or clear it, then retry."
                return
            }
        }
        guard !Task.isCancelled, taskID == self.chatOwnerTaskID else { return }
        // This generation changes only for an explicit credential-reset purge.
        // Never restore or re-save the old buffer across that security boundary.
        priorViewModel?.shutdown(saveComposerDraft: false)
        self.viewModel = nil
        self.viewModelOwner = self.chatOwnerID
        self.viewModelResetGeneration = self.appModel.chatOutboxOwnerGeneration
        self.chatPreparationError = nil
        let usesDemoTransport = self.appModel.isAppleReviewDemoModeEnabled
        if usesDemoTransport {
            self.viewModel = OpenClawChatViewModel(
                sessionKey: self.appModel.chatSessionKey,
                transport: AppleReviewDemoChatTransport(),
                onSessionChanged: { sessionKey in
                    self.appModel.focusChatSession(sessionKey)
                },
                diagnosticsLog: { message in
                    GatewayDiagnostics.log(message)
                })
            return
        }

        guard let stableGatewayID = self.appModel.chatOutboxGatewayOwnerID else {
            self.chatPreparationError = "Connect to a gateway once before using durable chat."
            return
        }
        do {
            let outboxDeliveryOwner = try await self.appModel.chatOutboxDelivery(
                stableGatewayID: stableGatewayID)
            let composerDraftStore = try await self.appModel.chatOutboxStore(stableGatewayID: stableGatewayID)
            guard !Task.isCancelled, taskID == self.chatOwnerTaskID else { return }
            // Session focus can change while the durable database is opening.
            // Capture it only after the suspension, in the same MainActor turn
            // that installs the view model.
            let currentSessionKey = self.appModel.chatSessionKey
            self.viewModel = OpenClawChatViewModel(
                sessionKey: currentSessionKey,
                transport: self.appModel.makeOperatorChatTransport(stableGatewayID: stableGatewayID),
                outboxDeliveryOwner: outboxDeliveryOwner,
                composerDraftStore: composerDraftStore,
                onSessionChanged: { sessionKey in
                    self.appModel.focusChatSession(sessionKey)
                },
                diagnosticsLog: { message in
                    GatewayDiagnostics.log(message)
                })
        } catch {
            guard !Task.isCancelled, taskID == self.chatOwnerTaskID else { return }
            self.chatPreparationError = "Durable chat storage could not be opened. Your draft was not sent."
        }
    }

    private var talkControl: OpenClawChatTalkControl {
        OpenClawChatTalkControl(
            isEnabled: self.appModel.talkMode.isEnabled,
            isListening: self.appModel.talkMode.isListening,
            isSpeaking: self.appModel.talkMode.isSpeaking,
            isGatewayConnected: self.appModel.talkMode.isGatewayConnected,
            statusText: self.appModel.talkMode.statusText,
            providerLabel: self.appModel.talkMode.gatewayTalkProviderLabel,
            toggle: { sessionKey in
                self.appModel.focusChatSession(sessionKey)
                self.appModel.setTalkEnabled(!self.appModel.talkMode.isEnabled)
            })
    }

    private var activeAgentID: String {
        self.normalized(self.appModel.chatAgentId)
            ?? "main"
    }

    private var connectionPill: some View {
        HStack(spacing: 6) {
            ProStatusDot(color: self.chatReadinessText == nil ? OpenClawBrand.ok : .orange)
            Text(self.chatReadinessText ?? "Connected")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(self.chatReadinessText == nil ? OpenClawBrand.ok : .orange)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            Capsule()
                .fill((self.chatReadinessText == nil ? OpenClawBrand.ok : Color.orange).opacity(0.11))
        }
        .overlay {
            Capsule()
                .strokeBorder((self.chatReadinessText == nil ? OpenClawBrand.ok : Color.orange).opacity(0.16), lineWidth: 1)
        }
    }

    private var gatewayConnected: Bool {
        self.appModel.isAppleReviewDemoModeEnabled ||
            (self.appModel.operatorRoleState == .online && self.appModel.isOperatorGatewayConnected)
    }

    private var chatReadinessText: String? {
        ChatConnectionPresentation.readinessText(
            blockingText: self.chatBlockingConditionText,
            gatewayConnected: self.gatewayConnected,
            hasViewModel: self.currentViewModel != nil,
            isLoading: self.currentViewModel?.isLoading == true,
            hasError: self.chatPreparationError != nil || self.currentViewModel?.errorText != nil)
    }

    private var messagePlaceholder: String {
        ChatConnectionPresentation.messagePlaceholder(
            agentName: self.agentDisplayName,
            blockingText: self.chatBlockingConditionText,
            gatewayConnected: self.gatewayConnected,
            canQueueOffline: self.currentViewModel?.canQueueOffline == true,
            supportsDurableOutbox: self.currentViewModel?.supportsDurableOutbox == true)
    }

    private var chatBlockingConditionText: String? {
        ChatConnectionPresentation.blockingText(
            deliveryGate: self.currentViewModel?.outboxStatus.deliveryGate,
            nodeState: self.appModel.nodeRoleState,
            operatorState: self.appModel.operatorRoleState)
    }

    private var chatUserAccent: Color {
        self.colorScheme == .light ? Color(red: 0 / 255.0, green: 122 / 255.0, blue: 255 / 255.0) : OpenClawBrand.accent
    }

    private var activeAgent: AgentSummary? {
        self.appModel.gatewayAgents.first { $0.id == self.activeAgentID }
    }

    private var agentDisplayName: String {
        self.normalized(self.activeAgent?.name) ?? self.appModel.chatAgentName
    }

    private var agentBadge: String {
        if let identity = self.activeAgent?.identity,
           let emoji = identity["emoji"]?.value as? String,
           let normalizedEmoji = self.normalized(emoji)
        {
            return normalizedEmoji
        }
        let words = self.agentDisplayName
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(2)
        let initials = words.compactMap(\.first).map(String.init).joined()
        if !initials.isEmpty {
            return initials.uppercased()
        }
        return "OC"
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
