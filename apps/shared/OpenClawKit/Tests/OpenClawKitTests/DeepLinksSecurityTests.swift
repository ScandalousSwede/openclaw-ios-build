import Foundation
import OpenClawKit
import Testing

private func setupCode(from payload: String) -> String {
    Data(payload.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Suite struct DeepLinksSecurityTests {
    @Test func dashboardDeepLinkParses() {
        let url = URL(string: "openclaw://dashboard")!
        #expect(DeepLinkParser.parse(url) == .dashboard)
    }

    @Test func gatewayDeepLinkRejectsInsecureNonLoopbackWs() {
        let url = URL(
            string: "openclaw://gateway?host=attacker.example&port=18789&tls=0&token=abc")!
        #expect(DeepLinkParser.parse(url) == nil)
    }

    @Test func gatewayDeepLinkRejectsInsecurePrefixBypassHost() {
        let url = URL(
            string: "openclaw://gateway?host=127.attacker.example&port=18789&tls=0&token=abc")!
        #expect(DeepLinkParser.parse(url) == nil)
    }

    @Test func gatewayDeepLinkAllowsLoopbackWs() {
        let url = URL(
            string: "openclaw://gateway?host=127.0.0.1&port=18789&tls=0&token=abc")!
        #expect(
            DeepLinkParser.parse(url) == .gateway(
                .init(
                    host: "127.0.0.1",
                    port: 18789,
                    tls: false,
                    bootstrapToken: nil,
                    token: "abc",
                    password: nil)))
    }

    @Test func setupCodeRejectsInsecureNonLoopbackWs() {
        let payload = #"{"url":"ws://attacker.example:18789","bootstrapToken":"tok"}"#
        #expect(GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == nil)
    }

    @Test func setupCodeRejectsInsecurePrefixBypassHost() {
        let payload = #"{"url":"ws://127.attacker.example:18789","bootstrapToken":"tok"}"#
        #expect(GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == nil)
    }

    @Test func setupCodeAllowsLoopbackWs() {
        let payload = #"{"url":"ws://127.0.0.1:18789","bootstrapToken":"tok"}"#
        #expect(
            GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == .init(
                host: "127.0.0.1",
                port: 18789,
                tls: false,
                bootstrapToken: "tok",
                token: nil,
                password: nil))
    }

    @Test func setupCodeAllowsPrivateLanWs() {
        let payload = #"{"url":"ws://192.168.1.20:18789","bootstrapToken":"tok"}"#
        #expect(
            GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == .init(
                host: "192.168.1.20",
                port: 18789,
                tls: false,
                bootstrapToken: "tok",
                token: nil,
                password: nil))
    }

    @Test func setupCodeAllowsMDNSWs() {
        let payload = #"{"url":"ws://openclaw.local:18789","bootstrapToken":"tok"}"#
        #expect(
            GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == .init(
                host: "openclaw.local",
                port: 18789,
                tls: false,
                bootstrapToken: "tok",
                token: nil,
                password: nil))
    }

    @Test func setupCodeParsesOrderedGatewayFallbacks() throws {
        let payload = #"{"url":"ws://192.168.1.20:18789","urls":["ws://192.168.1.20:18789","wss://gateway.tailnet.ts.net:8443"],"bootstrapToken":"tok"}"#
        let link = GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload))

        #expect(link?.connectionEndpoints == [
            .init(host: "192.168.1.20", port: 18789, tls: false),
            .init(host: "gateway.tailnet.ts.net", port: 8443, tls: true),
        ])
        #expect(try link?.selectingEndpoint(#require(link?.connectionEndpoints[1])) == .init(
            host: "gateway.tailnet.ts.net",
            port: 8443,
            tls: true,
            bootstrapToken: "tok",
            token: nil,
            password: nil))
    }

    @Test func legacyEncodedGatewayLinkDecodesWithoutFallbacks() throws {
        let payload = #"{"host":"gateway.tailnet.ts.net","port":443,"tls":true}"#

        let link = try JSONDecoder().decode(
            GatewayConnectDeepLink.self,
            from: Data(payload.utf8))

        #expect(link.fallbackEndpoints.isEmpty)
    }

    @Test func decodedGatewayLinkRejectsInvalidPrimaryEndpoint() {
        let payload = #"{"host":"attacker.example","port":18789,"tls":false}"#

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GatewayConnectDeepLink.self, from: Data(payload.utf8))
        }
    }

    @Test func decodedGatewayLinkBoundsAndFiltersFallbackEndpoints() throws {
        let fallbacks = (0..<12).map { index -> [String: Any] in
            if index == 1 {
                return ["host": "attacker.example", "port": 18789, "tls": false]
            }
            return ["host": "gateway-\(index).example.com", "port": 443, "tls": true]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "host": "gateway.example.com",
            "port": 443,
            "tls": true,
            "fallbackEndpoints": fallbacks,
        ])

        let link = try JSONDecoder().decode(GatewayConnectDeepLink.self, from: data)

        #expect(link.connectionEndpoints.count == 7)
        #expect(!link.connectionEndpoints.contains { $0.host == "attacker.example" })
        #expect(!link.connectionEndpoints.contains { $0.host == "gateway-7.example.com" })
    }

    @Test func setupCodeDropsInsecureGatewayFallbacks() {
        let payload = #"{"url":"ws://attacker.example:18789","urls":["ws://attacker.example:18789","wss://gateway.tailnet.ts.net"],"bootstrapToken":"tok"}"#

        #expect(GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == .init(
            host: "gateway.tailnet.ts.net",
            port: 443,
            tls: true,
            bootstrapToken: "tok",
            token: nil,
            password: nil))
    }

    @Test func setupCodeCapsGatewayEndpoints() throws {
        let urls = (0..<10).map { "wss://gateway-\($0).example.com" }
        let data = try JSONSerialization.data(withJSONObject: ["url": urls[0], "urls": Array(urls.dropFirst())])
        let payload = try #require(String(data: data, encoding: .utf8))

        let link = GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload))

        #expect(link?.connectionEndpoints.count == 8)
        #expect(link?.connectionEndpoints.last?.host == "gateway-7.example.com")
    }

    @Test func setupCodeDoesNotSearchPastRawEndpointLimit() throws {
        let invalid = (0..<8).map { _ in "ws://attacker.example:18789" }
        let data = try JSONSerialization.data(withJSONObject: [
            "urls": invalid + ["wss://reachable.example.com"],
        ])
        let payload = try #require(String(data: data, encoding: .utf8))

        #expect(GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == nil)
    }

    @Test func gatewayDeepLinkUsesImplicitWSSPort443() {
        let url = URL(string: "openclaw://gateway?host=gateway.tailnet.ts.net&tls=1")!

        #expect(DeepLinkParser.parse(url) == .gateway(.init(
            host: "gateway.tailnet.ts.net",
            port: 443,
            tls: true,
            bootstrapToken: nil,
            token: nil,
            password: nil)))
    }

    @Test func gatewayDeepLinkRejectsInvalidPort() {
        let url = URL(string: "openclaw://gateway?host=gateway.tailnet.ts.net&port=70000&tls=1")!
        #expect(DeepLinkParser.parse(url) == nil)
    }

    @Test func setupCodeRejectsTailnetPlaintextWs() {
        let payload = #"{"url":"ws://gateway.tailnet.ts.net:18789","bootstrapToken":"tok"}"#
        #expect(GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == nil)
    }

    @Test func setupCodeRejectsCgnatPlaintextWs() {
        let payload = #"{"url":"ws://100.64.0.9:18789","bootstrapToken":"tok"}"#
        #expect(GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == nil)
    }

    @Test func setupCodeParsesHostPayload() {
        let payload = #"{"host":"gateway.tailnet.ts.net","port":443,"tls":true,"bootstrapToken":"tok"}"#
        #expect(
            GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == .init(
                host: "gateway.tailnet.ts.net",
                port: 443,
                tls: true,
                bootstrapToken: "tok",
                token: nil,
                password: nil))
    }

    @Test func setupCodeParsesHostPayloadWithTLSDefaultPort() {
        let payload = #"{"host":"gateway.tailnet.ts.net","tls":true,"bootstrapToken":"tok"}"#
        #expect(
            GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == .init(
                host: "gateway.tailnet.ts.net",
                port: 443,
                tls: true,
                bootstrapToken: "tok",
                token: nil,
                password: nil))
    }

    @Test func setupCodeRejectsInsecureHostPayload() {
        let payload = #"{"host":"gateway.tailnet.ts.net","port":18789,"tls":false,"bootstrapToken":"tok"}"#
        #expect(GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == nil)
    }

    @Test func setupCodeAllowsPrivateLanHostPayload() {
        let payload = #"{"host":"openclaw.local","port":18789,"tls":false,"bootstrapToken":"tok"}"#
        #expect(
            GatewayConnectDeepLink.fromSetupCode(setupCode(from: payload)) == .init(
                host: "openclaw.local",
                port: 18789,
                tls: false,
                bootstrapToken: "tok",
                token: nil,
                password: nil))
    }

    @Test func setupInputParsesFullCopiedSetupMessage() {
        let payload = #"{"url":"wss://gateway.tailnet.ts.net","bootstrapToken":"tok"}"#
        let message = """
        Pairing setup code generated.

        Setup code:
        \(setupCode(from: payload))
        """
        #expect(
            GatewayConnectDeepLink.fromSetupInput(message) == .init(
                host: "gateway.tailnet.ts.net",
                port: 443,
                tls: true,
                bootstrapToken: "tok",
                token: nil,
                password: nil))
    }

    @Test func setupInputParsesRawGatewayURL() {
        #expect(
            GatewayConnectDeepLink.fromSetupInput("wss://gateway.example.com:444") == .init(
                host: "gateway.example.com",
                port: 444,
                tls: true,
                bootstrapToken: nil,
                token: nil,
                password: nil))
    }
}
