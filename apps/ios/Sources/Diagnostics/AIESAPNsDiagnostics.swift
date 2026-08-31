import Foundation
import OpenClawKit
import os

enum AIESAPNsPublicationStage: String, Equatable, Sendable {
    case deferred = "gateway_publication_deferred"
    case admitted = "gateway_publication_admitted"
    case attempted = "gateway_publication_attempted"
    case accepted = "gateway_publication_accepted"
    // Reserved for a future protocol acknowledgment. The current one-way
    // node.event path cannot truthfully emit these two gateway outcomes.
    case gatewayDuplicate = "gateway_publication_duplicate"
    case gatewayRejected = "gateway_publication_rejected"
    case localDuplicateSuppressed = "local_publication_duplicate_suppressed"
    case relayRejected = "relay_publication_rejected"
    case failed = "gateway_publication_failed"
    case superseded = "registration_superseded"
    case cancelled = "registration_cancelled"
}

enum AIESAPNsPublicationDeferralReason: String, Equatable, Sendable {
    case ownerUnavailable = "connection_owner_unavailable"
    case nodeConnectionUnavailable = "node_connection_unavailable"
    case tokenUnavailable = "os_token_unavailable"
    case topicUnavailable = "bundle_topic_unavailable"
    case gatewayIdentityUnavailable = "stable_gateway_identity_unavailable"
    case nodeRouteUnavailable = "node_route_unavailable"
    case nodeRouteStale = "node_route_stale"
    case nodeGatewayMismatch = "node_gateway_identity_mismatch"
    case configurationChanged = "configuration_generation_changed"
    case operatorConnectionUnavailable = "operator_connection_unavailable"
    case operatorRouteUnavailable = "operator_route_unavailable"
    case operatorRouteStale = "operator_route_stale"
    case operatorGatewayMismatch = "operator_gateway_identity_mismatch"
    case intentUnavailable = "registration_intent_unavailable"
}

struct AIESAPNsGatewayIdentityDiagnosticEvidence: Sendable {
    let configuredIdentity: String?
    let observedIdentity: String?
    let configuredSource: OpenClawDiagnosticGatewayIdentitySource
    let observedSource: OpenClawDiagnosticGatewayIdentitySource
    let comparison: OpenClawDiagnosticGatewayIdentityComparison

    init(
        configuredIdentity: String?,
        observedIdentity: String?,
        configuredSource: OpenClawDiagnosticGatewayIdentitySource = .activeGatewayConnectConfig,
        observedSource: OpenClawDiagnosticGatewayIdentitySource)
    {
        let configured = configuredIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let observed = observedIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredIdentity = configured.flatMap { $0.isEmpty ? nil : $0 }
        self.observedIdentity = observed.flatMap { $0.isEmpty ? nil : $0 }
        self.configuredSource = configuredSource
        self.observedSource = observedSource
        switch (self.configuredIdentity, self.observedIdentity) {
        case (nil, nil):
            // Both operands missing is never an identity comparison; callers
            // must not construct evidence until at least one source produced an ID.
            self.comparison = .configuredMissing
        case (nil, .some):
            self.comparison = .configuredMissing
        case (.some, nil):
            self.comparison = .observedMissing
        case let (.some(configured), .some(observed)) where configured == observed:
            self.comparison = .equal
        case (.some, .some):
            self.comparison = .different
        }
    }
}

struct AIESAPNsPublicationDiagnosticContext: Sendable {
    let registrationAttemptID: String
    let configurationGeneration: UInt64?
    let socketGeneration: UInt64?
    let routeGeneration: UInt64?
    let nodeRouteGeneration: UInt64?
    let operatorRouteGeneration: UInt64?
    let connectionRole: OpenClawDiagnosticConnectionRole?
    let deviceIdentity: String?
    let gatewayIdentityEvidence: AIESAPNsGatewayIdentityDiagnosticEvidence?
    let transport: OpenClawDiagnosticAPNsTransport?
    let topic: String?
    let environment: String?

    init(
        registrationAttemptID: String,
        configurationGeneration: UInt64? = nil,
        route: GatewayNodeSessionRoute? = nil,
        nodeRoute: GatewayNodeSessionRoute? = nil,
        operatorRoute: GatewayNodeSessionRoute? = nil,
        connectionRole: OpenClawDiagnosticConnectionRole? = nil,
        deviceIdentity: String? = nil,
        gatewayIdentityEvidence: AIESAPNsGatewayIdentityDiagnosticEvidence? = nil,
        transport: OpenClawDiagnosticAPNsTransport? = nil,
        topic: String? = nil,
        environment: String? = nil)
    {
        self.registrationAttemptID = registrationAttemptID
        self.configurationGeneration = configurationGeneration
        self.socketGeneration = route?.diagnosticSocketGeneration
        self.routeGeneration = route?.diagnosticRouteGeneration
        self.nodeRouteGeneration = nodeRoute?.diagnosticRouteGeneration
        self.operatorRouteGeneration = operatorRoute?.diagnosticRouteGeneration
        self.connectionRole = connectionRole
        self.deviceIdentity = deviceIdentity
        self.gatewayIdentityEvidence = gatewayIdentityEvidence
        self.transport = transport
        self.topic = topic
        self.environment = environment
    }
}

/// Process-local custody for the OS registration request that can later produce
/// an app-delegate token or failure callback. It records correlation only; it
/// never stores a token or changes APNs registration behavior.
enum AIESAPNsDiagnostics {
    private struct PendingRegistration: Sendable {
        let id: String
    }

    private static let pending = OSAllocatedUnfairLock<PendingRegistration?>(initialState: nil)
    #if DEBUG
    private static let flushProbe = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    #endif

    @discardableResult
    static func recordOSRegistrationRequested(
        source: String,
        attemptID: String = UUID().uuidString) -> String
    {
        let resolution = self.pending.withLock { current -> (id: String, coalesced: Bool) in
            if let current {
                return (current.id, true)
            }
            current = PendingRegistration(id: attemptID)
            return (attemptID, false)
        }
        self.record(
            state: "os_registration_requested",
            attemptID: resolution.id,
            providerStage: source,
            resultClass: resolution.coalesced ? "coalesced_request" : "requested")
        return resolution.id
    }

    /// Returns the opaque correlation ID to carry into gateway publication.
    static func recordOSTokenReceived() -> String {
        let resolution = self.resolvePendingAttempt()
        self.record(
            state: "os_token_received",
            attemptID: resolution.id,
            resultClass: resolution.wasPending ? "received" : "unattributed_callback")
        self.flushCriticalBoundary()
        return resolution.id
    }

    static func recordOSRegistrationFailed() {
        let resolution = self.resolvePendingAttempt()
        self.record(
            state: "os_registration_failed",
            attemptID: resolution.id,
            resultClass: resolution.wasPending ? "system_error" : "unattributed_system_error")
        self.flushCriticalBoundary()
    }

    static func recordPublication(
        _ stage: AIESAPNsPublicationStage,
        providerStage: String? = nil,
        resultClass: String,
        context: AIESAPNsPublicationDiagnosticContext)
    {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .apns,
            state: stage.rawValue,
            connectionRole: context.connectionRole,
            socketGeneration: context.socketGeneration,
            routeGeneration: context.routeGeneration,
            nodeRouteGeneration: context.nodeRouteGeneration,
            operatorRouteGeneration: context.operatorRouteGeneration,
            configurationGeneration: context.configurationGeneration,
            registrationAttemptID: context.registrationAttemptID,
            providerStage: providerStage,
            resultClass: resultClass,
            deviceIdentityIdentifier: context.deviceIdentity,
            configuredGatewayIdentityIdentifier: context.gatewayIdentityEvidence?.configuredIdentity,
            observedGatewayIdentityIdentifier: context.gatewayIdentityEvidence?.observedIdentity,
            configuredGatewayIdentitySource: context.gatewayIdentityEvidence?.configuredSource,
            observedGatewayIdentitySource: context.gatewayIdentityEvidence?.observedSource,
            gatewayIdentityComparison: context.gatewayIdentityEvidence?.comparison,
            apnsTransport: context.transport,
            topic: context.topic,
            environment: context.environment))
        if stage != .admitted {
            self.flushCriticalBoundary()
        }
    }

    /// A non-2xx relay response is an observed relay rejection, not a gateway
    /// rejection. Other local, transport, decoding, or preparation errors remain
    /// failures. Neither case proves whether the gateway accepted the later
    /// one-way node event.
    static func recordPublicationFailure(
        _ error: any Error,
        context: AIESAPNsPublicationDiagnosticContext)
    {
        if let relayError = error as? PushRelayError,
           case let .requestFailed(status: status, message: _) = relayError
        {
            guard (400..<500).contains(status) else {
                self.recordPublication(
                    .failed,
                    providerStage: "relay_registration_response",
                    resultClass: "relay_http_failed",
                    context: context)
                return
            }
            self.recordPublication(
                .relayRejected,
                providerStage: "relay_registration_response",
                resultClass: "relay_http_rejected",
                context: context)
            return
        }
        self.recordPublication(
            .failed,
            providerStage: "payload_or_relay_preparation",
            resultClass: "local_or_relay_preparation_failed",
            context: context)
    }

    private static func resolvePendingAttempt() -> (id: String, wasPending: Bool) {
        self.pending.withLock { current in
            if let pendingAttempt = current {
                current = nil
                return (pendingAttempt.id, true)
            }
            return (UUID().uuidString, false)
        }
    }

    private static func record(
        state: String,
        attemptID: String,
        providerStage: String? = nil,
        resultClass: String)
    {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .apns,
            state: state,
            registrationAttemptID: attemptID,
            providerStage: providerStage,
            resultClass: resultClass,
            topic: Bundle.main.bundleIdentifier,
            environment: PushBuildConfig.current.apnsEnvironment.rawValue))
    }

    private static func flushCriticalBoundary() {
        #if DEBUG
        if let flushProbe = self.flushProbe.withLock({ $0 }) {
            flushProbe()
            return
        }
        #endif
        _ = GatewayDiagnostics.flush(timeout: 0.1)
    }

    #if DEBUG
    static func _testInstallFlushProbe(_ probe: (@Sendable () -> Void)?) {
        self.flushProbe.withLock { $0 = probe }
    }

    static func _testReset() {
        self.pending.withLock { $0 = nil }
        self.flushProbe.withLock { $0 = nil }
    }
    #endif
}
