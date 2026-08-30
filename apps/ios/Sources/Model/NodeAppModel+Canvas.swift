import Foundation
import OpenClawKit

enum A2UIReadyState {
    case ready
    case hostUnavailable
}

extension NodeAppModel {
    func showA2UIOnConnectIfNeeded(
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute? = nil,
        shouldApply: @MainActor @Sendable () -> Bool = { true }) async
    {
        guard shouldApply() else { return }
        if let expectedRoute {
            guard await self.gatewaySession.isCurrentRoute(expectedRoute) else { return }
        }
        guard shouldApply() else { return }
        // Keep the bundled home canvas as the default connected view.
        // Agents can still explicitly present a remote or local canvas later.
        self.screen.showDefaultCanvas()
    }

    func ensureA2UIReadyWithCapabilityRefresh(timeoutMs: Int = 5000) async -> A2UIReadyState {
        if self.screen.isShowingLocalA2UI(),
           await self.screen.waitForA2UIReady(timeoutMs: timeoutMs)
        {
            return .ready
        }

        self.screen.showLocalA2UI()
        if await self.screen.waitForA2UIReady(timeoutMs: timeoutMs) {
            return .ready
        }
        return .hostUnavailable
    }

    func showLocalCanvasOnDisconnect() {
        self.screen.showDefaultCanvas()
    }
}
