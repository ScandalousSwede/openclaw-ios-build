import Foundation
import OpenClawChatUI
import Testing
import UserNotifications
@testable import OpenClaw

@MainActor
@Suite(.serialized)
struct ChatReplyNotificationTests {
    private let gateway = "fixture-gateway"
    private let owner = "fixture-owner"
    private let session = "agent:main:main"
    private let messageID = "fixture-stored-entry"

    private func payload(messageID: String? = nil) -> [AnyHashable: Any] {
        ["openclaw": [
            "kind": "chat.reply", "gatewayDeviceId": self.gateway,
            "sessionKey": self.session, "agentId": "main",
            "messageId": messageID ?? self.messageID,
        ]]
    }

    private func message(id: String, role: String = "assistant", text: String = "Exact stored answer")
        -> OpenClawChatMessage
    {
        OpenClawChatMessage(
            role: role,
            content: [.init(type: "text", text: text, mimeType: nil, fileName: nil, content: nil)],
            timestamp: nil,
            transcriptMessageID: id)
    }

    @Test func `tap retains exact reply and route across back and reopen`() throws {
        let model = NodeAppModel()
        model._test_setChatOutboxGatewayOwnerID(self.owner)
        let delegate = OpenClawAppDelegate()
        delegate.appModel = model
        #expect(delegate.routeChatReplyNotification(
            actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: self.payload()))
        let original = try #require(model.chatReplyNotificationRequest)
        #expect(original.gatewayOwnerID == self.owner)
        #expect(original.reference.messageId == self.messageID)
        model.chatReplyNotificationRequest = nil
        #expect(model.lastChatReplyNotificationRequest == original)
        let presentation = model.chatReplyNotificationPresentationID
        model.reopenLastChatReplyNotification()
        #expect(model.chatReplyNotificationRequest == original)
        #expect(model.chatReplyNotificationPresentationID == presentation + 1)
    }

    @Test func `exact read requires paired gateway and persisted assistant entry`() async throws {
        let reference = try #require(ChatReplyNotificationReference.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: self.payload()))
        var calls: [String] = []
        let resolved = try await reference.resolve(
            identity: { calls.append("identity"); return .init(deviceId: self.gateway) },
            read: { params in
                calls.append("read")
                #expect(params == ["sessionKey": self.session, "agentId": "main", "messageId": self.messageID])
                return .init(ok: true, message: self.message(id: self.messageID), unavailableReason: nil)
            }, stillCurrent: { true })
        #expect(calls == ["identity", "read"])
        #expect(ChatReplyNotificationReference.readableText(resolved) == "Exact stored answer")

        for rejected in [
            self.message(id: "different-entry"),
            self.message(id: self.messageID, role: "user"),
            self.message(id: self.messageID, text: "  "),
        ] {
            do {
                _ = try await reference.resolve(
                    identity: { .init(deviceId: self.gateway) },
                    read: { _ in .init(ok: true, message: rejected, unavailableReason: nil) },
                    stillCurrent: { true })
                Issue.record("accepted a non-matching or unreadable reply")
            } catch {}
        }
        do {
            _ = try await reference.resolve(
                identity: { .init(deviceId: "other-gateway") },
                read: { _ in Issue.record("read on wrong gateway"); return .init(
                    ok: true, message: self.message(id: self.messageID), unavailableReason: nil) },
                stillCurrent: { true })
            Issue.record("accepted a reply from another gateway")
        } catch {}
        do {
            _ = try await reference.resolve(
                identity: { .init(deviceId: self.gateway) },
                read: { _ in .init(ok: false, message: nil, unavailableReason: "not_visible") },
                stillCurrent: { true })
            Issue.record("accepted an invisible reply")
        } catch {}
    }

    @Test func `malformed reply pointers and non-tap actions do not route`() {
        let delegate = OpenClawAppDelegate()
        for payload in [
            ["openclaw": ["kind": "chat.reply", "gatewayDeviceId": self.gateway,
                           "sessionKey": self.session]],
            self.payload(messageID: "bad\nentry"),
            self.payload(messageID: String(repeating: "a", count: 257)),
            ["openclaw": ["kind": "chat.reply", "gatewayDeviceId": self.gateway,
                           "sessionKey": self.session, "messageId": self.messageID,
                           "unexpected": "value"]],
        ] as [[AnyHashable: Any]] {
            #expect(!delegate.routeChatReplyNotification(
                actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload))
        }
        #expect(!delegate.routeChatReplyNotification(actionIdentifier: "DISMISS", userInfo: self.payload()))
        #expect(OpenClawAppDelegate.foregroundNotificationPresentationOptions(userInfo: self.payload()).isEmpty)
    }
}
