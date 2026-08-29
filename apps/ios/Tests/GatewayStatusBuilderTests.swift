import OpenClawKit
import Testing
@testable import OpenClaw

@Suite struct GatewayStatusBuilderTests {
    @Test func wholeAppIsHealthyOnlyWhenBothRolesAreOnline() {
        #expect(GatewayStatusBuilder.build(
            nodeRoleState: .online,
            operatorRoleState: .online,
            lastGatewayProblem: nil) == .connected)
        #expect(GatewayStatusBuilder.build(
            nodeRoleState: .online,
            operatorRoleState: .offline,
            lastGatewayProblem: nil) == .disconnected)
    }

    @Test func missingOrScopeBlockedOperatorRoleIsAnHonestError() {
        #expect(GatewayStatusBuilder.build(
            nodeRoleState: .online,
            operatorRoleState: .missingRole,
            lastGatewayProblem: nil) == .error)
        #expect(GatewayStatusBuilder.build(
            nodeRoleState: .online,
            operatorRoleState: .scopeBlocked(missing: ["operator.read"]),
            lastGatewayProblem: nil) == .error)
    }

    @Test func pausedProblemKeepsErrorStatus() {
        let state = GatewayStatusBuilder.build(
            gatewayServerName: nil,
            lastGatewayProblem: GatewayConnectionProblem(
                kind: .pairingRequired,
                owner: .gateway,
                title: "Pairing required",
                message: "Approve this device before reconnecting.",
                requestId: "req-123",
                retryable: false,
                pauseReconnect: true),
            gatewayStatusText: "Reconnecting…")

        #expect(state == .error)
    }

    @Test func transientProblemAllowsConnectingStatus() {
        let state = GatewayStatusBuilder.build(
            gatewayServerName: nil,
            lastGatewayProblem: GatewayConnectionProblem(
                kind: .timeout,
                owner: .network,
                title: "Connection timed out",
                message: "The gateway did not respond before the connection timed out.",
                retryable: true,
                pauseReconnect: false),
            gatewayStatusText: "Reconnecting…")

        #expect(state == .connecting)
    }
}
