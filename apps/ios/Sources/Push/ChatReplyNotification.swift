import Foundation
import OpenClawChatUI
import SwiftUI
import UserNotifications

struct ChatReplyNotificationReference: Hashable, Sendable {
    static let kind = "chat.reply"
    let gatewayDeviceId: String
    let sessionKey: String
    let agentId: String?
    let messageId: String

    static func parse(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Self? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let value = userInfo["openclaw"] as? [String: Any],
              value["kind"] as? String == Self.kind,
              Set(value.keys).isSubset(of: ["kind", "gatewayDeviceId", "sessionKey", "agentId", "messageId"]),
              let gatewayDeviceId = value["gatewayDeviceId"] as? String,
              Self.validIdentity(gatewayDeviceId, limit: 256),
              let sessionKey = value["sessionKey"] as? String,
              Self.validIdentity(sessionKey, limit: 1024),
              let messageId = value["messageId"] as? String,
              Self.validIdentity(messageId, limit: 256)
        else { return nil }
        let agentId = value["agentId"] as? String
        if value["agentId"] != nil {
            guard let agentId, Self.validIdentity(agentId, limit: 256) else { return nil }
        }
        return Self(gatewayDeviceId: gatewayDeviceId, sessionKey: sessionKey,
                    agentId: agentId, messageId: messageId)
    }

    private static func validIdentity(_ value: String, limit: Int) -> Bool {
        (1...limit).contains(value.utf16.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    struct GatewayIdentity: Decodable, Sendable { let deviceId: String }
    struct MessageRead: Decodable, Sendable {
        let ok: Bool
        let message: OpenClawChatMessage?
        let unavailableReason: String?
    }

    @MainActor
    func resolve(
        identity: @MainActor () async throws -> GatewayIdentity,
        read: @MainActor ([String: String]) async throws -> MessageRead,
        stillCurrent: @MainActor () async -> Bool) async throws -> OpenClawChatMessage
    {
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        let gateway = try await identity()
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        guard gateway.deviceId == self.gatewayDeviceId else { throw ArgusOperationsError.invalidResponse }
        var params = ["sessionKey": self.sessionKey, "messageId": self.messageId]
        if let agentId = self.agentId { params["agentId"] = agentId }
        let response = try await read(params)
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        guard response.ok, let message = response.message,
              message.transcriptMessageID == self.messageId,
              message.role == "assistant", message.stopReason != "error",
              message.errorMessage == nil, message.toolCallId == nil, message.toolName == nil,
              Self.readableText(message) != nil
        else { throw ArgusOperationsError.invalidResponse }
        return message
    }

    static func readableText(_ message: OpenClawChatMessage) -> String? {
        let text = message.content.compactMap { content in
            content.type == nil || content.type == "text" ? content.text : nil
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

struct ChatReplyNotificationRequest: Hashable, Identifiable {
    let reference: ChatReplyNotificationReference
    let gatewayOwnerID: String?
    var id: Self { self }
}

extension NodeAppModel {
    func openChatReplyNotification(_ reference: ChatReplyNotificationReference) {
        self.chatReplyNotificationRequest = .init(
            reference: reference, gatewayOwnerID: self.chatOutboxGatewayOwnerID)
        self.chatReplyNotificationPresentationID &+= 1
    }

    func reopenLastChatReplyNotification() {
        guard let request = self.lastChatReplyNotificationRequest else { return }
        self.chatReplyNotificationRequest = request
        self.chatReplyNotificationPresentationID &+= 1
    }
}

struct ChatReplyNotificationView: View {
    @Environment(NodeAppModel.self) private var appModel
    let request: ChatReplyNotificationRequest
    @State private var boundGatewayID: String?
    @State private var message: OpenClawChatMessage?
    @State private var error: String?
    @State private var retry = 0
    @State private var generation = 0

    init(request: ChatReplyNotificationRequest) {
        self.request = request
        self._boundGatewayID = State(initialValue: request.gatewayOwnerID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Argus reply").font(.title2.weight(.semibold))
                if let message, self.boundGatewayID == self.appModel.chatOutboxGatewayOwnerID,
                   let text = ChatReplyNotificationReference.readableText(message)
                {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open conversation") {
                        self.appModel.openChat(sessionKey: self.request.reference.sessionKey)
                    }
                } else if let error {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                } else if self.appModel.gatewayPairingPaused || self.appModel.operatorReconnectNeedsUserAction {
                    Text(self.appModel.gatewayDisplayStatusText)
                    Text("Review the connection in Settings, then retry this reply.")
                } else if !self.appModel.isOperatorGatewayConnected {
                    Text("Connect to the paired gateway to read this exact reply. You can reopen it from Home during this app session.")
                } else {
                    ProgressView("Checking exact reply")
                }
                if self.message == nil {
                    Button("Retry") { self.retry += 1 }
                        .disabled(!self.appModel.isOperatorGatewayConnected)
                }
            }
            .padding()
        }
        .navigationTitle("Reply")
        .task(id: "\(self.appModel.chatOutboxGatewayOwnerID ?? "none")|\(self.appModel.isOperatorGatewayConnected)|\(self.retry)") {
            await self.load()
        }
    }

    private func load() async {
        self.generation += 1
        let generation = self.generation
        guard !self.appModel.isAppleReviewDemoModeEnabled else {
            self.error = "This reply is unavailable in demo mode."
            return
        }
        guard let gatewayID = self.appModel.chatOutboxGatewayOwnerID else { return }
        if let boundGatewayID, boundGatewayID != gatewayID {
            self.message = nil
            self.error = "The paired gateway changed. This reply cannot open from another gateway."
            return
        }
        self.boundGatewayID = gatewayID
        guard self.appModel.isOperatorGatewayConnected else { return }
        do {
            let session = self.appModel.operatorSession
            guard let route = await session.currentRoute(ifGatewayID: gatewayID) else {
                throw ArgusOperationsError.unavailable
            }
            let client = ArgusOperationsClient(session: session, gatewayID: gatewayID, pinnedRoute: route)
            let reply = try await self.request.reference.resolve(
                identity: { try await client.request("gateway.identity.get", params: [:],
                                                     as: ChatReplyNotificationReference.GatewayIdentity.self) },
                read: { try await client.request("chat.message.get", params: $0,
                                                 as: ChatReplyNotificationReference.MessageRead.self) },
                stillCurrent: {
                    guard !Task.isCancelled, self.generation == generation,
                          self.appModel.chatReplyNotificationRequest == self.request,
                          self.appModel.chatOutboxGatewayOwnerID == gatewayID else { return false }
                    guard await session.isCurrentRoute(route) else { return false }
                    return !Task.isCancelled && self.generation == generation
                        && self.appModel.chatReplyNotificationRequest == self.request
                        && self.appModel.chatOutboxGatewayOwnerID == gatewayID
                })
            guard await session.isCurrentRoute(route), !Task.isCancelled, self.generation == generation,
                  self.appModel.chatReplyNotificationRequest == self.request,
                  self.appModel.chatOutboxGatewayOwnerID == gatewayID else { return }
            self.message = reply
            self.error = nil
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            self.message = nil
            self.error = "The exact reply is unavailable or no longer visible. Retry after reconnecting."
        }
    }
}
