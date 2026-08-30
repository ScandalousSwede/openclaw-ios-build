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
    @State private var viewModel: OpenClawChatViewModel?
    @State private var chatPreparationError: String?
    @State private var chatPreparationRetry = ChatPreparationRetryState()

    var body: some View {
        NavigationStack {
            ZStack {
                OpenClawProBackground()
                VStack(spacing: 0) {
                    self.header
                    if let viewModel {
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
        .task(id: self.chatOwnerTaskID) {
            await self.prepareChatViewModel(taskID: self.chatOwnerTaskID)
        }
        .onChange(of: self.appModel.chatSessionKey) { _, _ in
            self.viewModel?.syncSession(to: self.appModel.chatSessionKey)
        }
        .onChange(of: self.appModel.isOperatorGatewayConnected) { _, connected in
            guard connected else { return }
            if let viewModel = self.viewModel {
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
                .foregroundStyle(.white)
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
        let owner = self.appModel.isAppleReviewDemoModeEnabled
            ? "apple-review-demo"
            : (self.appModel.chatOutboxGatewayOwnerID ?? "unavailable")
        return self.chatPreparationRetry.taskID(
            owner: owner,
            ownerGeneration: self.appModel.chatOutboxOwnerGeneration)
    }

    private func requestChatPreparationRetry() {
        self.chatPreparationRetry.request()
    }

    private func prepareChatViewModel(taskID: String) async {
        self.viewModel?.shutdown()
        self.viewModel = nil
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
            guard !Task.isCancelled, taskID == self.chatOwnerTaskID else { return }
            // Session focus can change while the durable database is opening.
            // Capture it only after the suspension, in the same MainActor turn
            // that installs the view model.
            let currentSessionKey = self.appModel.chatSessionKey
            self.viewModel = OpenClawChatViewModel(
                sessionKey: currentSessionKey,
                transport: self.appModel.makeOperatorChatTransport(stableGatewayID: stableGatewayID),
                outboxDeliveryOwner: outboxDeliveryOwner,
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
            ProStatusDot(color: self.chatDeliveryReady ? OpenClawBrand.ok : .orange)
            Text(self.chatDeliveryReady ? "Connected" : (self.chatBlockingConditionText ?? "Connecting"))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(self.chatDeliveryReady ? OpenClawBrand.ok : .orange)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            Capsule()
                .fill((self.chatDeliveryReady ? OpenClawBrand.ok : Color.orange).opacity(0.11))
        }
        .overlay {
            Capsule()
                .strokeBorder((self.chatDeliveryReady ? OpenClawBrand.ok : Color.orange).opacity(0.16), lineWidth: 1)
        }
    }

    private var gatewayConnected: Bool {
        self.appModel.isAppleReviewDemoModeEnabled ||
            (self.appModel.operatorRoleState == .online && self.appModel.isOperatorGatewayConnected)
    }

    private var chatDeliveryReady: Bool {
        self.gatewayConnected && self.chatBlockingConditionText == nil
    }

    private var messagePlaceholder: String {
        ChatConnectionPresentation.messagePlaceholder(
            agentName: self.agentDisplayName,
            blockingText: self.chatBlockingConditionText,
            gatewayConnected: self.gatewayConnected,
            canQueueOffline: self.viewModel?.canQueueOffline == true,
            supportsDurableOutbox: self.viewModel?.supportsDurableOutbox == true)
    }

    private var chatBlockingConditionText: String? {
        ChatConnectionPresentation.blockingText(
            deliveryGate: self.viewModel?.outboxStatus.deliveryGate,
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
