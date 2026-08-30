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
        #expect(model.contains("connectionRole: .node"))
        #expect(model.contains("connectionRole: .operator"))
        #expect(model.contains("route: nodeRoute"))
        #expect(model.contains("route: operatorRoute"))
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
