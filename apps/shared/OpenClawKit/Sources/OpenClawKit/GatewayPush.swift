import Foundation
import OpenClawProtocol

public enum GatewayServerCapability: String, CaseIterable, Sendable {
    case chatSendRoutingContract = "chat-send-routing-contract"
}

extension HelloOk {
    public var advertisedServerCapabilityNames: Set<String> {
        let values = self.features["capabilities"]?.value as? [AnyCodable] ?? []
        return Set(values.compactMap { value in
            let raw = (value.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw : nil
        })
    }

    public var advertisedServerCapabilities: Set<GatewayServerCapability> {
        Set(self.advertisedServerCapabilityNames.compactMap { GatewayServerCapability(rawValue: $0) })
    }

    public func supportsServerCapability(_ capability: GatewayServerCapability) -> Bool {
        self.advertisedServerCapabilities.contains(capability)
    }

    public var authenticatedOperatorScopes: Set<String>? {
        let role = (self.auth["role"]?.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard role == "operator" else { return nil }
        let values = self.auth["scopes"]?.value as? [AnyCodable] ?? []
        let scopes = values.compactMap { value -> String? in
            let scope = (value.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return scope?.isEmpty == false ? scope : nil
        }
        return Set(scopes)
    }
}

/// Server-push messages from the gateway websocket.
///
/// This is the in-process replacement for the legacy `NotificationCenter` fan-out.
public enum GatewayPush: Sendable {
    /// A full snapshot that arrives on connect (or reconnect).
    case snapshot(HelloOk)
    /// A server push event frame.
    case event(EventFrame)
    /// A detected sequence gap (`expected...received`) for event frames.
    case seqGap(expected: Int, received: Int)
}
