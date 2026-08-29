import SwiftUI

struct GatewayTrustPromptAlert: ViewModifier {
    @Environment(GatewayConnectionController.self) private var gatewayController: GatewayConnectionController
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.alert(
            "Trust this gateway?",
            isPresented: Binding(
                get: { self.isEnabled && self.gatewayController.pendingTrustPrompt != nil },
                set: { _ in
                    // Keep pending trust state until explicit user action. SwiftUI can update
                    // presentation bindings while dismissing; clearing here can race Trust.
                }),
            presenting: self.gatewayController.pendingTrustPrompt)
        { prompt in
            Button("Cancel", role: .cancel) {
                self.gatewayController.declinePendingTrustPrompt(prompt)
            }
            Button("Trust and connect") {
                Task { await self.gatewayController.acceptPendingTrustPrompt(prompt) }
            }
        } message: { prompt in
            Text(
                """
                First-time TLS connection.

                Verify this SHA-256 fingerprint out-of-band before trusting:
                \(prompt.fingerprintSha256)
                """)
        }
    }
}

extension View {
    func gatewayTrustPromptAlert(isEnabled: Bool = true) -> some View {
        self.modifier(GatewayTrustPromptAlert(isEnabled: isEnabled))
    }
}
