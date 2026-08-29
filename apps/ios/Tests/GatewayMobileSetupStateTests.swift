import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

@Suite struct GatewayMobileSetupStateTests {
    @Test func completeFreshDualRoleReceiptIsReady() {
        #expect(NodeAppModel.mobileSetupHandoffState(
            issues: [],
            persistence: .succeeded) == .ready)
    }

    @Test func nodeOnlyReceiptCannotBeMaskedByStoredCredentials() {
        #expect(NodeAppModel.mobileSetupHandoffState(
            issues: [.missingOperatorRole],
            persistence: .notAttempted) == .nodeOnly)
    }

    @Test func missingNodeAndOperatorRolesIsInvalidRatherThanNodeOnly() {
        #expect(NodeAppModel.mobileSetupHandoffState(
            issues: [.missingNodeRole, .missingOperatorRole],
            persistence: .notAttempted) == .invalid)
    }

    @Test func missingOperatorCredentialIsNotReportedAsPersistenceFailure() {
        #expect(NodeAppModel.mobileSetupHandoffState(
            issues: [.missingOperatorToken],
            persistence: .notAttempted) == .missingOperatorCredential)
    }

    @Test(arguments: [
        GatewayBootstrapHandoffIssue.missingOperatorRead,
        GatewayBootstrapHandoffIssue.missingOperatorWrite,
        GatewayBootstrapHandoffIssue.missingOperatorTalkSecrets,
    ])
    func everyRequiredOperatorScopeHasAnExplicitBlockedState(_ issue: GatewayBootstrapHandoffIssue) {
        let scope = switch issue {
        case .missingOperatorRead: "operator.read"
        case .missingOperatorWrite: "operator.write"
        default: "operator.talk.secrets"
        }
        #expect(NodeAppModel.mobileSetupHandoffState(
            issues: [issue],
            persistence: .notAttempted) == .scopeBlocked(missing: [scope]))
    }

    @Test func atomicPersistenceFailureIsDistinctFromRoleIssuance() {
        #expect(NodeAppModel.mobileSetupHandoffState(
            issues: [],
            persistence: .failed) == .persistenceFailed)
    }

    @Test func overgrantedOrMalformedIssuanceNeverBecomesReady() {
        for issue in [
            GatewayBootstrapHandoffIssue.unexpectedNodeScopes,
            GatewayBootstrapHandoffIssue.unexpectedOperatorScopes,
            GatewayBootstrapHandoffIssue.malformedResponse,
        ] {
            #expect(NodeAppModel.mobileSetupHandoffState(
                issues: [issue],
                persistence: .notAttempted) == .invalid)
        }
    }

    @Test func firstBootstrapAdmissionRequiresReceiptButLaterReconnectDoesNot() {
        #expect(NodeAppModel.mobileSetupHandoffValidationDecision(
            usedBootstrapToken: true,
            validationPending: true,
            currentRouteState: nil) == .rejected(.invalid))
        #expect(NodeAppModel.mobileSetupHandoffValidationDecision(
            usedBootstrapToken: true,
            validationPending: true,
            currentRouteState: .ready) == .ready)
        #expect(NodeAppModel.mobileSetupHandoffValidationDecision(
            usedBootstrapToken: true,
            validationPending: false,
            currentRouteState: nil) == .notRequired)
    }

    @Test func explicitAuthPrecedenceMatchesWireSelectionAndHandoffAdmission() {
        #expect(GatewayAuthSource.explicitCredentialSource(
            token: nil,
            bootstrapToken: "bootstrap",
            password: nil) == .bootstrapToken)
        #expect(GatewayAuthSource.explicitCredentialSource(
            token: nil,
            bootstrapToken: "bootstrap",
            password: "password") == .password)
        #expect(GatewayAuthSource.explicitCredentialSource(
            token: "token",
            bootstrapToken: "bootstrap",
            password: "password") == .sharedToken)
        #expect(!NodeAppModel._test_shouldStartOperatorGatewayLoop(
            token: nil,
            bootstrapToken: "bootstrap",
            password: nil,
            hasStoredOperatorToken: true))
        #expect(NodeAppModel._test_shouldStartOperatorGatewayLoop(
            token: nil,
            bootstrapToken: "bootstrap",
            password: "password",
            hasStoredOperatorToken: false))
    }

    @Test func bootstrapOwnerRejectsStaleGenerationAndDifferentInputs() throws {
        let first = try Self.makeConfig(
            url: #require(URL(string: "wss://first.example")),
            bootstrapToken: "first-bootstrap")
        let owner = GatewayConnectionOwner(generation: 7, config: first)
        #expect(owner.matches(currentGeneration: 7, activeConfig: first))
        #expect(!owner.matches(currentGeneration: 8, activeConfig: first))

        let replacement = try Self.makeConfig(
            url: #require(URL(string: "wss://second.example")),
            bootstrapToken: "second-bootstrap")
        #expect(!owner.matches(currentGeneration: 7, activeConfig: replacement))

        let consumed = try Self.makeConfig(
            url: #require(URL(string: "wss://first.example")),
            bootstrapToken: nil)
        #expect(owner.matches(currentGeneration: 7, activeConfig: consumed))
    }

    @Test func operatorScopeBlockIsTerminalOnlyForItsOwnedGeneration() {
        #expect(NodeAppModel.operatorLoopPostConnectDecision(
            ownerIsCurrent: true,
            ownerGeneration: 11,
            blockedGeneration: 11,
            missingScopes: nil) == .stopScopeBlocked)
        #expect(NodeAppModel.operatorLoopPostConnectDecision(
            ownerIsCurrent: false,
            ownerGeneration: 11,
            blockedGeneration: nil,
            missingScopes: []) == .stopStaleOwner)
        #expect(NodeAppModel.operatorLoopPostConnectDecision(
            ownerIsCurrent: true,
            ownerGeneration: 12,
            blockedGeneration: 11,
            missingScopes: []) == .monitor)
        #expect(NodeAppModel.operatorLoopPostConnectDecision(
            ownerIsCurrent: true,
            ownerGeneration: 12,
            blockedGeneration: nil,
            missingScopes: ["operator.write"]) == .stopScopeBlocked)
        #expect(NodeAppModel.operatorLoopPostConnectDecision(
            ownerIsCurrent: true,
            ownerGeneration: 12,
            blockedGeneration: nil,
            missingScopes: nil) == .retryRouteAdmission)
        #expect(NodeAppModel.operatorLoopPostConnectDecision(
            ownerIsCurrent: false,
            ownerGeneration: 12,
            blockedGeneration: nil,
            missingScopes: ["operator.write"]) == .stopStaleOwner)
    }

    @Test @MainActor func scopeBlockPreservesHealthyNodeAndStopsOperatorGeneration() {
        let model = NodeAppModel()
        model._test_setGatewayRoleStates(node: .online, operator: .online)
        model._test_applyOperatorScopeBlock(missing: ["operator.write"])

        #expect(model.nodeRoleState == .online)
        #expect(model.operatorRoleState == .scopeBlocked(missing: ["operator.write"]))
        #expect(model._test_operatorReconnectBlockedGeneration() == model._test_gatewayConfigurationGeneration())
        #expect(model.gatewayAutoReconnectEnabled)
        #expect(!model.gatewayPairingPaused)
    }

    @Test func chatPresentationNeverHidesRoleRouteOrIdentityBlockers() {
        #expect(ChatConnectionPresentation.blockingText(
            deliveryGate: .routingContractUnavailable,
            nodeState: .online,
            operatorState: .online) == "Routing contract unavailable")
        #expect(ChatConnectionPresentation.blockingText(
            deliveryGate: .gatewayIdentityUnavailable,
            nodeState: .online,
            operatorState: .online) == "Gateway identity unavailable")
        #expect(ChatConnectionPresentation.blockingText(
            deliveryGate: nil,
            nodeState: .offline,
            operatorState: .missingRole) == "Operator role missing")
        #expect(ChatConnectionPresentation.blockingText(
            deliveryGate: .offline,
            nodeState: .online,
            operatorState: .missingRole) == "Operator role missing")
        #expect(ChatConnectionPresentation.blockingText(
            deliveryGate: .operatorSessionUnavailable,
            nodeState: .online,
            operatorState: .scopeBlocked(missing: ["operator.write"])) == "Operator scopes unavailable")
        #expect(ChatConnectionPresentation.messagePlaceholder(
            agentName: "Main",
            blockingText: "Routing contract unavailable",
            gatewayConnected: true,
            canQueueOffline: true,
            supportsDurableOutbox: true) == "Routing contract unavailable — messages queue locally")
    }

    @Test @MainActor func missingOperatorRoleDoesNotDegradeToGenericOfflineRoute() async {
        let model = NodeAppModel()
        model._test_setGatewayRoleStates(node: .offline, operator: .missingRole)
        let result = await model.makeOperatorChatTransport(
            stableGatewayID: "gateway").acquireOutboxRouteLease()
        switch result {
        case .unavailable(reason: .operatorRoleMissing):
            break
        default:
            Issue.record("expected missing operator role, got \(String(describing: result))")
        }
    }

    @Test @MainActor func agentsAreUnavailableUntilAgentsListSucceeds() {
        let model = NodeAppModel()
        model.gatewayAgents = []
        model._test_setGatewayAgentRosterLoadState(.unavailable)
        #expect(model.gatewayAgentCountText == "Unavailable")
        #expect(model.gatewayAgentRosterSummaryText == "Unavailable")

        model._test_setGatewayAgentRosterLoadState(.loaded)
        #expect(model.gatewayAgentCountText == "0")
        #expect(model.gatewayAgentRosterSummaryText == "0 total")
    }

    @Test func productSurfacesUseRoleAwareSetupAndStatusContracts() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Model/NodeAppModel.swift"),
            encoding: .utf8)
        let rootTabs = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/RootTabs.swift"),
            encoding: .utf8)
        let settings = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Design/SettingsProTabSections.swift"),
            encoding: .utf8)
        let command = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Design/CommandCenterTab.swift"),
            encoding: .utf8)
        let agents = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Design/AgentProTab+Overview.swift"),
            encoding: .utf8)
        let chat = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Design/ChatProTab.swift"),
            encoding: .utf8)
        let talk = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Design/TalkProTab.swift"),
            encoding: .utf8)
        let canvas = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Model/NodeAppModel+Canvas.swift"),
            encoding: .utf8)

        #expect(model.contains("bootstrapHandoffOwner"))
        #expect(model.contains("mobileSetupHandoffValidationDecision"))
        #expect(model.contains("case let .rejected(rejectedState)"))
        #expect(model.contains("This device was approved for node only."))
        #expect(rootTabs.contains("self.appModel.mobileSetupComplete"))
        #expect(settings.contains("Gateway/node"))
        #expect(settings.contains("Operator/chat"))
        #expect(settings.contains("gatewayAgentCountText"))
        #expect(command.contains("Gateway/node"))
        #expect(command.contains("Operator/chat"))
        #expect(agents.contains("gatewayAgentRosterSummaryText"))
        #expect(agents.contains("no agent count is authoritative"))
        #expect(chat.contains("Operator session unavailable"))
        #expect(chat.contains("Operator scopes unavailable"))
        #expect(chat.contains("Routing contract unavailable"))
        #expect(chat.contains("Gateway identity unavailable"))
        #expect(chat.contains("Gateway offline"))
        #expect(talk.contains("operator session required for Talk is unavailable"))
        #expect(talk.contains("server has no Talk configuration"))
        #expect(model.contains("onConnectedRoute: { [weak self] admittedRoute in"))
        #expect(model.contains("self.gatewayOwnerCheck(loopOwner)"))
        #expect(model.contains("self.gatewayOwnerCheck(owner)"))
        #expect(model.contains("ifCurrentRoute: admittedRoute"))
        #expect(model.contains("operatorRoute: admittedRoute"))
        #expect(model.contains("nodeRoute: admittedRoute"))
        #expect(model.contains("shouldContinue: shouldContinue"))
        #expect(canvas.contains("ifCurrentRoute expectedRoute: GatewayNodeSessionRoute?"))
        #expect(canvas.contains("self.nodeGateway.isCurrentRoute(expectedRoute)"))
    }

    @Test func healthScopeAndAPNsSideEffectsRemainBoundToTheirOwningRoutes() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Model/NodeAppModel.swift"),
            encoding: .utf8)

        // Health failure may retire only the routes captured when monitoring began.
        #expect(model.contains("operatorRoute: GatewayNodeSessionRoute,"))
        #expect(model.contains(
            "guard await self.operatorGateway.disconnect(ifCurrentRoute: operatorRoute) else { return }"))
        #expect(model.contains(
            "nodeDisconnected = await self.nodeGateway.disconnect(ifCurrentRoute: nodeRoute)"))
        #expect(model.contains(
            "self.operatorGateway.currentRoute(\n                      ifGatewayID: expectedGatewayID)"))
        #expect(model.contains("self.nodeGateway.currentRoute(ifGatewayID: expectedGatewayID)"))
        let admittedOperatorGatewayGuard =
            "self.operatorGateway.currentGatewayID(\n"
                + "                                ifCurrentRoute: admittedRoute) == stableID"
        #expect(model.contains(admittedOperatorGatewayGuard))
        #expect(model.contains("self.nodeGateway.currentRoute(ifGatewayID: stableID)"))

        // A canceled or route-losing operator loop cannot disconnect or scope-block
        // the successor that replaced its own admitted route.
        #expect(model.contains("guard !Task.isCancelled,"))
        #expect(model.contains("case .retryRouteAdmission:"))
        #expect(model.contains(
            "_ = await self.operatorGateway.disconnect(ifCurrentRoute: admittedRoute)"))
        #expect(model.contains(
            "await self.operatorGateway.disconnect(ifCurrentRoute: admittedRoute)"))
        let canceledScopeBlockGuard =
            "else { continue operatorReconnectLoop }\n"
                + "                        guard !Task.isCancelled else { break operatorReconnectLoop }"
        #expect(model.contains(canceledScopeBlockGuard))
        #expect(model.contains("self.applyOperatorScopeBlock(missing: admittedScopes)"))

        // APNs registration is coalesced by its exact route pair and repeatedly
        // fenced by the captured configuration generation and stable gateway ID.
        #expect(model.contains("private struct APNsRegistrationAttempt: Equatable"))
        #expect(model.contains("let configurationGeneration = self.gatewayConfigurationGeneration"))
        #expect(model.contains(
            "self.activeGatewayConnectConfig?.effectiveStableID == expectedGatewayID"))
        #expect(model.contains(
            "self.nodeGateway.currentGatewayID(ifCurrentRoute: nodeRoute) == expectedGatewayID"))
        #expect(model.contains(
            "self.operatorGateway.currentGatewayID(ifCurrentRoute: operatorRoute) == expectedGatewayID"))
        #expect(model.contains(
            "guard !self.apnsRegistrationsInFlight.contains(attempt) else { return }"))
        #expect(model.contains("ifCurrentRoute: nodeRoute"))
        #expect(model.contains(
            "[token, topic, expectedGatewayID, \"direct\"].joined(separator: \"|\")"))
        #expect(!model.contains("apnsLastRegisteredTokenHex"))
    }

    private static func makeConfig(
        url: URL,
        bootstrapToken: String?) throws -> GatewayConnectConfig
    {
        GatewayConnectConfig(
            url: url,
            stableID: "gateway",
            tls: nil,
            token: nil,
            bootstrapToken: bootstrapToken,
            password: nil,
            nodeOptions: GatewayConnectOptions(
                role: "node",
                scopes: [],
                caps: [],
                commands: [],
                permissions: [:],
                clientId: "openclaw-ios",
                clientMode: "node",
                clientDisplayName: nil))
    }
}
