import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

private final class APNsDiagnosticLineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        self.lock.lock()
        self.lines.append(line)
        self.lock.unlock()
    }

    func events() -> [OpenClawDiagnosticEvent] {
        self.lock.lock()
        let copy = self.lines
        self.lock.unlock()
        return copy.compactMap(OpenClawDiagnosticRecorder.decodeRecord)
    }
}

private final class APNsDiagnosticFlushProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        self.lock.lock()
        self.value += 1
        self.lock.unlock()
    }

    func count() -> Int {
        self.lock.lock()
        let copy = self.value
        self.lock.unlock()
        return copy
    }
}

@Suite(.serialized)
struct AIESAPNsDiagnosticsTests {
    @Test
    func osRegistrationRequestAndTokenCallbackShareOneAttempt() throws {
        let probe = APNsDiagnosticLineProbe()
        let flushes = APNsDiagnosticFlushProbe()
        OpenClawDiagnosticRecorder.installSink { probe.append($0) }
        AIESAPNsDiagnostics._testReset()
        AIESAPNsDiagnostics._testInstallFlushProbe { flushes.increment() }
        defer {
            AIESAPNsDiagnostics._testReset()
            OpenClawDiagnosticRecorder.clearSink()
        }

        let rawAttemptID = "apns-attempt-one"
        AIESAPNsDiagnostics.recordOSRegistrationRequested(
            source: "application_launch",
            attemptID: rawAttemptID)
        let resolvedAttemptID = AIESAPNsDiagnostics.recordOSTokenReceived()

        #expect(resolvedAttemptID == rawAttemptID)
        let events = probe.events()
        #expect(events.map(\.state) == [
            "os_registration_requested",
            "os_token_received",
        ])
        let attemptHashes = try events.map { try #require($0.registrationAttemptID) }
        #expect(Set(attemptHashes).count == 1)
        #expect(events[0].providerStage == "application_launch")
        #expect(events[0].resultClass == "requested")
        #expect(events[1].resultClass == "received")
        #expect(flushes.count() == 1)
    }

    @Test
    func repeatedOSRequestCoalescesUntilTheSingleCallback() {
        let probe = APNsDiagnosticLineProbe()
        let flushes = APNsDiagnosticFlushProbe()
        OpenClawDiagnosticRecorder.installSink { probe.append($0) }
        AIESAPNsDiagnostics._testReset()
        AIESAPNsDiagnostics._testInstallFlushProbe { flushes.increment() }
        defer {
            AIESAPNsDiagnostics._testReset()
            OpenClawDiagnosticRecorder.clearSink()
        }

        let firstID = AIESAPNsDiagnostics.recordOSRegistrationRequested(
            source: "application_launch",
            attemptID: "first-attempt")
        let coalescedID = AIESAPNsDiagnostics.recordOSRegistrationRequested(
            source: "node_permission_grant",
            attemptID: "replacement-attempt")
        AIESAPNsDiagnostics.recordOSRegistrationFailed()

        let events = probe.events()
        #expect(events.map(\.state) == [
            "os_registration_requested",
            "os_registration_requested",
            "os_registration_failed",
        ])
        #expect(firstID == "first-attempt")
        #expect(coalescedID == firstID)
        #expect(events[1].resultClass == "coalesced_request")
        #expect(events[2].resultClass == "system_error")
        #expect(events.allSatisfy { $0.kind == .apns })
        #expect(flushes.count() == 1)
    }

    @Test @MainActor
    func deviceTokenBytesNeverEnterDiagnosticEvents() throws {
        let model = NodeAppModel()
        let probe = APNsDiagnosticLineProbe()
        OpenClawDiagnosticRecorder.installSink { probe.append($0) }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        model.updateAPNsDeviceToken(
            Data([0xde, 0xad, 0xbe, 0xef]),
            registrationAttemptID: "first-token-attempt")
        model.updateAPNsDeviceToken(
            Data([0xca, 0xfe, 0xba, 0xbe]),
            registrationAttemptID: "replacement-token-attempt")

        let superseded = probe.events().filter { $0.state == "registration_superseded" }
        #expect(superseded.count == 1)
        let supersededEvent = try #require(superseded.first)
        #expect(supersededEvent.resultClass == "new_os_token_received")
        #expect(supersededEvent.byteCount == nil)
        #expect(supersededEvent.deviceIdentityHash == nil)
        let output = String(
            decoding: try JSONEncoder().encode(probe.events()),
            as: UTF8.self).lowercased()
        #expect(!output.contains("deadbeef"))
        #expect(!output.contains("cafebabe"))
    }

    @Test
    func publicationLifecycleHelperEmitsBoundedTruthfulOutcomes() throws {
        let probe = APNsDiagnosticLineProbe()
        let flushes = APNsDiagnosticFlushProbe()
        OpenClawDiagnosticRecorder.installSink { probe.append($0) }
        AIESAPNsDiagnostics._testInstallFlushProbe { flushes.increment() }
        defer {
            AIESAPNsDiagnostics._testReset()
            OpenClawDiagnosticRecorder.clearSink()
        }
        let context = AIESAPNsPublicationDiagnosticContext(
            registrationAttemptID: "raw-registration-attempt",
            configurationGeneration: 41,
            connectionRole: .node,
            deviceIdentity: "raw-stable-device-identity",
            topic: "ai.openclaw.client",
            environment: "production")

        AIESAPNsDiagnostics.recordPublication(
            .admitted,
            resultClass: "direct",
            context: context)
        AIESAPNsDiagnostics.recordPublication(
            .attempted,
            providerStage: "transport_write_result",
            resultClass: "transport_write_accepted_unacknowledged",
            context: context)
        AIESAPNsDiagnostics.recordPublication(
            .localDuplicateSuppressed,
            resultClass: "local_direct_registration_match",
            context: context)
        AIESAPNsDiagnostics.recordPublicationFailure(
            PushRelayError.requestFailed(status: 403, message: "sensitive relay rejection"),
            context: context)
        AIESAPNsDiagnostics.recordPublicationFailure(
            PushRelayError.requestFailed(status: 503, message: "sensitive relay failure"),
            context: context)
        AIESAPNsDiagnostics.recordPublicationFailure(
            PushRelayError.relayMisconfigured("sensitive local failure"),
            context: context)
        AIESAPNsDiagnostics.recordPublication(
            .cancelled,
            resultClass: "route_or_configuration_changed_before_payload",
            context: context)
        AIESAPNsDiagnostics.recordPublication(
            .superseded,
            resultClass: "new_os_token_received",
            context: context)

        let events = probe.events()
        #expect(events.map(\.state) == [
            "gateway_publication_admitted",
            "gateway_publication_attempted",
            "local_publication_duplicate_suppressed",
            "relay_publication_rejected",
            "gateway_publication_failed",
            "gateway_publication_failed",
            "registration_cancelled",
            "registration_superseded",
        ])
        #expect(events.allSatisfy { $0.kind == .apns })
        #expect(events.allSatisfy { $0.connectionRole == .node })
        #expect(events.allSatisfy { $0.configurationGeneration == 41 })
        #expect(Set(events.compactMap(\.registrationAttemptID)).count == 1)
        #expect(events[1].providerStage == "transport_write_result")
        #expect(events[1].resultClass == "transport_write_accepted_unacknowledged")
        #expect(events[3].providerStage == "relay_registration_response")
        #expect(events[3].resultClass == "relay_http_rejected")
        #expect(events[4].providerStage == "relay_registration_response")
        #expect(events[4].resultClass == "relay_http_failed")
        #expect(events[5].providerStage == "payload_or_relay_preparation")
        #expect(events[5].resultClass == "local_or_relay_preparation_failed")
        #expect(!events.contains { $0.state == "gateway_publication_accepted" })
        #expect(!events.contains { $0.state == "gateway_publication_duplicate" })
        #expect(!events.contains { $0.state == "gateway_publication_rejected" })
        #expect(flushes.count() == 7)

        let output = String(
            decoding: try JSONEncoder().encode(events),
            as: UTF8.self)
        #expect(!output.contains("raw-registration-attempt"))
        #expect(!output.contains("raw-stable-device-identity"))
        #expect(!output.contains("sensitive relay rejection"))
        #expect(!output.contains("sensitive relay failure"))
        #expect(!output.contains("sensitive local failure"))
    }

    @Test
    func publicationDeferralsAreExplicitBoundedAndTokenFree() throws {
        let probe = APNsDiagnosticLineProbe()
        OpenClawDiagnosticRecorder.installSink { probe.append($0) }
        defer { OpenClawDiagnosticRecorder.clearSink() }
        let context = AIESAPNsPublicationDiagnosticContext(
            registrationAttemptID: "raw-registration-attempt",
            configurationGeneration: 7,
            connectionRole: .operator,
            deviceIdentity: "raw-device-identity",
            topic: "ai.openclaw.client",
            environment: "production")

        for reason in [
            AIESAPNsPublicationDeferralReason.nodeConnectionUnavailable,
            .tokenUnavailable,
            .nodeRouteUnavailable,
            .operatorConnectionUnavailable,
            .operatorRouteUnavailable,
            .configurationChanged,
        ] {
            AIESAPNsDiagnostics.recordPublication(
                .deferred,
                providerStage: "state_transition",
                resultClass: reason.rawValue,
                context: context)
        }

        let events = probe.events()
        #expect(events.count == 6)
        #expect(events.allSatisfy { $0.state == "gateway_publication_deferred" })
        #expect(events.allSatisfy { $0.connectionRole == .operator })
        #expect(events.allSatisfy { $0.providerStage == "state_transition" })
        #expect(events.map(\.resultClass) == [
            "node_connection_unavailable",
            "os_token_unavailable",
            "node_route_unavailable",
            "operator_connection_unavailable",
            "operator_route_unavailable",
            "configuration_generation_changed",
        ])
        let output = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!output.contains("raw-registration-attempt"))
        #expect(!output.contains("raw-device-identity"))
    }

    @Test
    func gatewayIdentityEvidenceNormalizesClassifiesAndNeverExportsOperands() throws {
        let equal = AIESAPNsGatewayIdentityDiagnosticEvidence(
            configuredIdentity: "  wss://gateway.example.ts.net:443  ",
            observedIdentity: "wss://gateway.example.ts.net:443",
            observedSource: .nodeRouteConnectOptions)
        let missing = AIESAPNsGatewayIdentityDiagnosticEvidence(
            configuredIdentity: "wss://gateway.example.ts.net:443",
            observedIdentity: nil,
            observedSource: .nodeRouteConnectOptions)
        let different = AIESAPNsGatewayIdentityDiagnosticEvidence(
            configuredIdentity: "wss://gateway.example.ts.net:443",
            observedIdentity: "wss://other.example.ts.net:443",
            observedSource: .operatorRouteConnectOptions)

        #expect(equal.comparison == .equal)
        #expect(missing.comparison == .observedMissing)
        #expect(different.comparison == .different)

        let probe = APNsDiagnosticLineProbe()
        OpenClawDiagnosticRecorder.installSink { probe.append($0) }
        defer { OpenClawDiagnosticRecorder.clearSink() }
        for (index, evidence) in [equal, missing, different].enumerated() {
            let resultClass: String
            if index == 0 {
                resultClass = "direct"
            } else if index == 2 {
                resultClass = AIESAPNsPublicationDeferralReason.operatorGatewayMismatch.rawValue
            } else {
                resultClass = AIESAPNsPublicationDeferralReason.nodeGatewayMismatch.rawValue
            }
            AIESAPNsDiagnostics.recordPublication(
                index == 0 ? .admitted : .deferred,
                providerStage: "node_route_admitted",
                resultClass: resultClass,
                context: AIESAPNsPublicationDiagnosticContext(
                    registrationAttemptID: "private-registration-attempt-\(index)",
                    configurationGeneration: UInt64(20 + index),
                    connectionRole: index == 2 ? .operator : .node,
                    deviceIdentity: "private-device-identity",
                    gatewayIdentityEvidence: evidence,
                    transport: index == 0 ? .direct : .relay,
                    topic: "ai.openclaw.client",
                    environment: "production"))
        }

        let events = probe.events()
        #expect(events.count == 3)
        #expect(events.map(\.state) == [
            "gateway_publication_admitted",
            "gateway_publication_deferred",
            "gateway_publication_deferred",
        ])
        #expect(events.map(\.gatewayIdentityComparison) == [.equal, .observedMissing, .different])
        #expect(events.map(\.apnsTransport) == [.direct, .relay, .relay])
        #expect(events[0].configuredGatewayIdentityHash == events[0].observedGatewayIdentityHash)
        #expect(events[1].configuredGatewayIdentityHash?.count == 16)
        #expect(events[1].observedGatewayIdentityHash == nil)
        #expect(events[2].configuredGatewayIdentityHash != events[2].observedGatewayIdentityHash)
        #expect(events.map(\.configurationGeneration) == [20, 21, 22])

        let output = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!output.contains("gateway.example.ts.net"))
        #expect(!output.contains("other.example.ts.net"))
        #expect(!output.contains("private-registration-attempt"))
        #expect(!output.contains("private-device-identity"))
        #expect(!output.lowercased().contains("token"))
    }

    @Test
    func tokenBeforeRouteRetainsOneGenerationFencedIntentUntilCompletion() throws {
        var state = AIESAPNsRegistrationIntentState()
        let intent = state.receiveToken(
            registrationAttemptID: "token-before-route",
            configurationGeneration: 4)

        // A missing route produces evidence in NodeAppModel but must not consume
        // the pending publication. The route-admission callback owns this intent.
        #expect(state.pending == intent)
        #expect(state.owns(intent))
        state.complete(intent)
        #expect(state.pending == nil)
    }

    @Test
    func routeBeforeTokenAdmitsWhenTheLaterTokenCreatesTheIntent() {
        var state = AIESAPNsRegistrationIntentState()

        #expect(state.pending == nil)
        let intent = state.receiveToken(
            registrationAttemptID: "route-before-token",
            configurationGeneration: 9)
        #expect(state.owns(intent))
    }

    @Test
    func simultaneousReadinessCreatesExactlyOneOwnedIntent() {
        var state = AIESAPNsRegistrationIntentState()
        let intent = state.receiveToken(
            registrationAttemptID: "simultaneous",
            configurationGeneration: 12)

        #expect(state.pending == intent)
        #expect(state.tokenGeneration == 1)
    }

    @Test
    func completedRelayGenerationIsNotRecreatedByALaterQueuedReadinessTrigger() {
        var state = AIESAPNsRegistrationIntentState()
        let intent = state.receiveToken(
            registrationAttemptID: "sequential-readiness",
            configurationGeneration: 12)

        #expect(state.resolve(
            registrationAttemptID: "sequential-readiness",
            configurationGeneration: 12) == .pending(intent))
        state.complete(intent)
        #expect(state.pending == nil)
        #expect(state.resolve(
            registrationAttemptID: "sequential-readiness",
            configurationGeneration: 12) == .alreadyCompleted)
        let completedRetry = state.consumeRetryAfterInFlightCompletion()
        #expect(!completedRetry)
    }

    @Test
    func postAwaitOwnershipFenceRejectsSupersededIntentBeforeAdmission() {
        var state = AIESAPNsRegistrationIntentState()
        let superseded = state.receiveToken(
            registrationAttemptID: "superseded",
            configurationGeneration: 20)
        let replacement = state.receiveToken(
            registrationAttemptID: "replacement",
            configurationGeneration: 20)

        #expect(!state.owns(superseded))
        #expect(state.owns(replacement))
    }

    @Test
    func replacementTokenAndConfigurationFenceStaleAttempts() {
        var state = AIESAPNsRegistrationIntentState()
        let oldTokenIntent = state.receiveToken(
            registrationAttemptID: "old-token",
            configurationGeneration: 2)
        let replacementTokenIntent = state.receiveToken(
            registrationAttemptID: "replacement-token",
            configurationGeneration: 2)

        #expect(!state.owns(oldTokenIntent))
        #expect(state.owns(replacementTokenIntent))
        state.complete(oldTokenIntent)
        #expect(state.pending == replacementTokenIntent)

        let replacementRouteIntent = state.requirePublication(
            registrationAttemptID: "replacement-token",
            configurationGeneration: 3)
        #expect(!state.owns(replacementTokenIntent))
        #expect(state.owns(replacementRouteIntent))
        state.complete(replacementTokenIntent)
        #expect(state.pending == replacementRouteIntent)
    }

    @Test
    func duplicateInFlightCoalescesAndRetriesOnlyAReplacementIntent() {
        var state = AIESAPNsRegistrationIntentState()
        let inFlight = state.receiveToken(
            registrationAttemptID: "in-flight",
            configurationGeneration: 5)

        state.coalesceBehindInFlight(ownedBy: inFlight)
        let originalRetry = state.consumeRetryAfterInFlightCompletion()
        #expect(!originalRetry)

        let replacement = state.receiveToken(
            registrationAttemptID: "replacement",
            configurationGeneration: 5)
        state.coalesceBehindInFlight(ownedBy: inFlight)
        #expect(state.pending == replacement)
        let replacementRetry = state.consumeRetryAfterInFlightCompletion()
        let duplicateRetry = state.consumeRetryAfterInFlightCompletion()
        #expect(replacementRetry)
        #expect(!duplicateRetry)
        #expect(state.pending == replacement)
    }

    @Test
    func relayIdentityAndTransportFailuresLeaveTheIntentRetriggerable() {
        var state = AIESAPNsRegistrationIntentState()
        let intent = state.receiveToken(
            registrationAttemptID: "retryable-failure",
            configurationGeneration: 6)

        // The production failure paths intentionally do not call complete(). A
        // later admitted route can therefore own and retry the same generation.
        #expect(state.owns(intent))
        #expect(state.pending == intent)

        #expect(AIESAPNsTransportWriteDisposition(published: false) == .unavailable)
        #expect(AIESAPNsTransportWriteDisposition(published: true) == .acceptedUnacknowledged)
        #expect(state.owns(intent))
    }

    @Test
    func directRegistrationBuildsTheExactGatewayPayloadWithoutRelayIdentity() async throws {
        let manager = PushRegistrationManager(buildConfig: PushBuildConfig(
            transport: .direct,
            distribution: .official,
            relayBaseURL: nil,
            apnsEnvironment: .production))

        let payload = try await manager.makeGatewayRegistrationPayload(
            apnsTokenHex: "fixture-token-not-a-device-token",
            topic: "ai.openclaw.fixture",
            gatewayIdentity: nil)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String])
        #expect(object == [
            "environment": "production",
            "token": "fixture-token-not-a-device-token",
            "topic": "ai.openclaw.fixture",
            "transport": "direct",
        ])
    }

    @Test
    func relayRegistrationFailsBeforePublicationWhenGatewayIdentityIsUnavailable() async {
        let manager = PushRegistrationManager(buildConfig: PushBuildConfig(
            transport: .relay,
            distribution: .official,
            relayBaseURL: URL(string: "https://relay.invalid"),
            apnsEnvironment: .production))

        await #expect(throws: PushRelayError.self) {
            try await manager.makeGatewayRegistrationPayload(
                apnsTokenHex: "fixture-token-not-a-device-token",
                topic: "ai.openclaw.fixture",
                gatewayIdentity: nil)
        }
    }

    @Test
    func publicationSourceRetainsPendingIntentAcrossEveryRetryableOutcome() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Model/NodeAppModel.swift"),
            encoding: .utf8)

        #expect(model.contains("trigger: \"os_token_received\""))
        #expect(model.contains("trigger: \"node_route_admitted\""))
        #expect(model.contains("trigger: \"operator_route_admitted\""))
        #expect(model.contains("trigger: \"in_flight_completed\""))
        #expect(model.contains("self.apnsRegistrationIntentState.owns(intent)"))
        #expect(model.contains("self.apnsRegistrationIntentState.complete(intent)"))
        #expect(model.contains("publication_already_in_flight"))
        #expect(model.contains("relay_identity_unavailable"))
        #expect(model.contains("transport_or_route_unavailable"))
        #expect(model.contains("transport_write_accepted_unacknowledged"))
        #expect(model.contains("self.apnsLastRegisteredKey == directRegistrationKey"))

        let admission = try #require(model.range(of: "trigger: \"operator_route_admitted\""))
        let laterSource = model[admission.upperBound...]
        let chatRecovery = try #require(laterSource.range(of: "startChatOutboxRecovery"))
        #expect(admission.lowerBound < chatRecovery.lowerBound)
    }

    @Test
    func publicationWiringIsTruthfulAndKnownRouteOwnersAreExplicit() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Model/NodeAppModel.swift"),
            encoding: .utf8)
        let app = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/OpenClawApp.swift"),
            encoding: .utf8)
        let diagnostics = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Diagnostics/AIESAPNsDiagnostics.swift"),
            encoding: .utf8)
        let talk = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Voice/TalkModeManager.swift"),
            encoding: .utf8)
        let share = try String(
            contentsOf: iosRoot.appendingPathComponent("ShareExtension/ShareViewController.swift"),
            encoding: .utf8)

        for stage in [
            "gateway_publication_deferred",
            "gateway_publication_admitted",
            "gateway_publication_attempted",
            "gateway_publication_duplicate",
            "gateway_publication_rejected",
            "local_publication_duplicate_suppressed",
            "relay_publication_rejected",
            "gateway_publication_failed",
            "registration_cancelled",
            "registration_superseded",
        ] {
            #expect(diagnostics.contains("\"\(stage)\""))
        }
        #expect(diagnostics.contains("\"gateway_publication_accepted\""))
        #expect(!model.contains("AIESAPNsDiagnostics.recordPublication(\n                .accepted"))
        #expect(!model.contains(".gatewayDuplicate"))
        #expect(!model.contains(".gatewayRejected"))
        #expect(diagnostics.contains("flushCriticalBoundary()"))
        #expect(model.contains("transport_write_accepted_unacknowledged"))
        #expect(model.contains("relay_identity_unavailable"))
        #expect(diagnostics.contains("connection_owner_unavailable"))
        #expect(model.contains("connectionRole: .node"))
        #expect(model.contains("connectionRole: .operator"))
        #expect(model.contains("route: nodeRoute"))
        #expect(model.contains("route: operatorRoute"))
        #expect(model.contains("observedSource: .nodeRouteConnectOptions"))
        #expect(model.contains("observedSource: .operatorRouteConnectOptions"))
        #expect(model.contains("gatewayIdentityEvidence: nodeGatewayIdentityEvidence"))
        #expect(model.contains("transport: diagnosticTransport"))
        #expect(model.contains("GatewaySettingsStore.currentInstanceID()"))
        #expect(model.contains("GatewayNodeSession(connectionRole: .node)"))
        #expect(model.contains("GatewayNodeSession(connectionRole: .operator)"))
        #expect(share.contains("GatewayNodeSession(connectionRole: .node)"))
        #expect(!talk.contains("connectionRole: .unknown"))
        for state in ["tts_route_prepared", "tts_route_changed"] {
            let stateRange = try #require(talk.range(of: "state: \"\(state)\""))
            let emission = talk[stateRange.lowerBound...].prefix(180)
            #expect(emission.contains("connectionRole: .operator"))
        }
        #expect(app.contains("recordOSRegistrationRequested(source: \"application_launch\")"))
        #expect(app.contains("recordOSTokenReceived()"))
        #expect(app.contains("recordOSRegistrationFailed()"))
    }
}
