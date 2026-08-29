import Foundation
import OpenClawKit

enum GatewayDisplayState: Equatable {
    case connected
    case connecting
    case error
    case disconnected
}

enum GatewayStatusBuilder {
    @MainActor
    static func build(appModel: NodeAppModel) -> GatewayDisplayState {
        if appModel.isAppleReviewDemoModeEnabled { return .connected }
        return self.build(
            nodeRoleState: appModel.nodeRoleState,
            operatorRoleState: appModel.operatorRoleState,
            lastGatewayProblem: appModel.lastGatewayProblem)
    }

    static func build(
        nodeRoleState: GatewayNodeRoleState,
        operatorRoleState: GatewayOperatorRoleState,
        lastGatewayProblem: GatewayConnectionProblem?) -> GatewayDisplayState
    {
        if let lastGatewayProblem, lastGatewayProblem.pauseReconnect {
            return .error
        }
        switch operatorRoleState {
        case .missingRole, .scopeBlocked:
            return .error
        case .connecting:
            return .connecting
        case .offline, .online:
            break
        }
        switch nodeRoleState {
        case .connecting:
            return .connecting
        case .online where operatorRoleState == .online:
            return .connected
        case .offline, .online:
            return .disconnected
        }
    }

    /// Legacy text projection retained for source compatibility and focused mapping tests.
    /// Product UI must use the role-aware `build(appModel:)` entry point above.
    static func buildLegacy(
        gatewayServerName: String?,
        lastGatewayProblem: GatewayConnectionProblem?,
        gatewayStatusText: String) -> GatewayDisplayState
    {
        self.build(
            gatewayServerName: gatewayServerName,
            lastGatewayProblem: lastGatewayProblem,
            gatewayStatusText: gatewayStatusText)
    }

    static func build(
        gatewayServerName: String?,
        lastGatewayProblem: GatewayConnectionProblem?,
        gatewayStatusText: String) -> GatewayDisplayState
    {
        if gatewayServerName != nil { return .connected }
        if let lastGatewayProblem, lastGatewayProblem.pauseReconnect { return .error }

        let text = gatewayStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.localizedCaseInsensitiveContains("connecting") ||
            text.localizedCaseInsensitiveContains("reconnecting")
        {
            return .connecting
        }

        if text.localizedCaseInsensitiveContains("error") {
            return .error
        }

        return .disconnected
    }
}
