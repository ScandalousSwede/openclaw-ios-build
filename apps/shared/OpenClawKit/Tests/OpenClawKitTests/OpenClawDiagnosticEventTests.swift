import Foundation
import os
import Testing
@testable import OpenClawKit

@Suite(.serialized)
struct OpenClawDiagnosticEventTests {
    @Test func hashesSessionAndRejectsUnsafeTokens() throws {
        let event = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "received",
            processIdentifier: 4242,
            launchIdentifier: "launch-epoch-one",
            processInstanceIdentifier: "process-instance-one",
            launchInstanceIdentifier: "launch-instance-one",
            priorProcessInstanceID: "0123456789abcdef",
            priorLaunchInstanceID: "fedcba9876543210",
            connectionRole: .operator,
            socketGeneration: 7,
            routeGeneration: 9,
            nodeRouteGeneration: 14,
            operatorRouteGeneration: 15,
            configurationGeneration: 10,
            activityGeneration: 11,
            playbackGeneration: 12,
            cancellationGeneration: 13,
            sessionIdentifier: "private-session-key",
            runIdentifier: "run-ok",
            messageIdentifier: "private message body\n",
            eventIdentifier: String(repeating: "x", count: 129),
            operationIdentifier: "sk_live_credential",
            operationGeneration: 17,
            diagnosticAttemptID: "diagnostic-attempt-one",
            registrationAttemptID: "registration-attempt-one",
            sequence: 42,
            stream: "assistant",
            provider: "elevenlabs",
            providerStage: "provider_response_received",
            codec: "pcm",
            playbackPath: "pcm",
            resultClass: "success",
            deviceIdentityIdentifier: "private-device-identity",
            topic: "ai.openclaw.client",
            environment: "production",
            byteCount: 8192,
            sampleRate: 44100,
            durationMilliseconds: 321,
            networkInterfaces: ["wifi", "cellular", "wifi", "bad interface"],
            observedAt: Date(timeIntervalSince1970: 0))

        #expect(event.schema == OpenClawDiagnosticEvent.schemaName)
        #expect(event.state == "received")
        #expect(event.processID == 4242)
        #expect(event.launchID?.count == 16)
        #expect(event.launchID != "launch-epoch-one")
        #expect(event.processInstanceID?.count == 16)
        #expect(event.processInstanceID != "process-instance-one")
        #expect(event.launchInstanceID?.count == 16)
        #expect(event.launchInstanceID != "launch-instance-one")
        #expect(event.priorProcessInstanceID == "0123456789abcdef")
        #expect(event.priorLaunchInstanceID == "fedcba9876543210")
        #expect(event.connectionRole == .operator)
        #expect(event.socketGeneration == 7)
        #expect(event.routeGeneration == 9)
        #expect(event.nodeRouteGeneration == 14)
        #expect(event.operatorRouteGeneration == 15)
        #expect(event.configurationGeneration == 10)
        #expect(event.activityGeneration == 11)
        #expect(event.playbackGeneration == 12)
        #expect(event.cancellationGeneration == 13)
        #expect(event.sessionHash?.count == 16)
        #expect(event.sessionHash != "private-session-key")
        #expect(event.runID?.count == 16)
        #expect(event.runID != "run-ok")
        #expect(event.messageID?.count == 16)
        #expect(event.messageID != "private message body\n")
        #expect(event.eventID?.count == 16)
        #expect(event.operationID?.count == 16)
        #expect(event.operationID != "sk_live_credential")
        #expect(event.operationGeneration == 17)
        #expect(event.diagnosticAttemptID?.count == 16)
        #expect(event.registrationAttemptID?.count == 16)
        #expect(event.sequence == 42)
        #expect(event.stream == "assistant")
        #expect(event.provider == "elevenlabs")
        #expect(event.providerStage == "provider_response_received")
        #expect(event.codec == "pcm")
        #expect(event.playbackPath == "pcm")
        #expect(event.resultClass == "success")
        #expect(event.deviceIdentityHash?.count == 16)
        #expect(event.deviceIdentityHash != "private-device-identity")
        #expect(event.topic == "ai.openclaw.client")
        #expect(event.environment == "production")
        #expect(event.byteCount == 8192)
        #expect(event.sampleRate == 44100)
        #expect(event.durationMilliseconds == 321)
        #expect(event.networkInterfaces == ["cellular", "wifi"])
        #expect(event.observedAt == "1970-01-01T00:00:00.000Z")
    }

    @Test func recorderEmitsOnlyEncodedSanitizedEvent() throws {
        let captured = OSAllocatedUnfairLock(initialState: [String]())
        OpenClawDiagnosticRecorder.installSink { line in
            captured.withLock { lines in
                lines.append(line)
            }
        }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .route,
            state: "stale_rejected",
            routeGeneration: 12,
            sessionIdentifier: "do-not-export-this",
            observedAt: Date(timeIntervalSince1970: 0)))

        let line = try #require(captured.withLock { $0.first })
        #expect(line.hasPrefix("aies_diagnostic="))
        #expect(!line.contains("do-not-export-this"))
        let payload = String(line.dropFirst("aies_diagnostic=".count))
        let data = try #require(Data(base64Encoded: payload))
        let event = try JSONDecoder().decode(OpenClawDiagnosticEvent.self, from: data)
        #expect(event.kind == .route)
        #expect(event.state == "stale_rejected")
        #expect(event.routeGeneration == 12)
        #expect(event.sessionHash?.count == 16)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(line) == event)
        #expect(OpenClawDiagnosticRecorder.decodeRecord("private transcript") == nil)
    }

    @Test func audioSessionRestoreBreadcrumbStageRoundTripsAsTypedMetadata() throws {
        let event = OpenClawDiagnosticEvent(
            kind: .tts,
            state: "tts_audio_session_restore_started",
            providerStage: "tts_audio_session_restore_started",
            observedAt: Date(timeIntervalSince1970: 0))
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(OpenClawDiagnosticEvent.self, from: encoded)

        #expect(decoded.providerStage == "tts_audio_session_restore_started")
        #expect(decoded.state == "tts_audio_session_restore_started")
    }

    @Test func rpcDiagnosticsRetainOnlyAllowlistedIdentityAndParameterShape() throws {
        let event = OpenClawDiagnosticEvent(
            kind: .socket,
            state: "request_completed",
            connectionRole: .operator,
            socketGeneration: 17,
            routeGeneration: 23,
            sessionIdentifier: "private-session-key",
            operationIdentifier: "client-local-operation-id",
            rpcMethod: "chat.history",
            admittedAt: Date(timeIntervalSince1970: 0),
            gatewayErrorCode: "INVALID_REQUEST",
            offsetPresent: true,
            offsetType: .integer,
            offsetValue: 0,
            limitPresent: false,
            maxCharsPresent: false,
            encodedPropertyNames: [.sessionKey, .offset],
            gatewayValidationPath: .offset,
            gatewayErrorMessageClass: .integerRequired,
            gatewayValidatorIdentity: "chat-history-0790d9f593ad",
            protocolSchemaVersion: "gateway-protocol-v4",
            requestEnvelopeVersion: 4,
            elapsedMilliseconds: 42,
            resultClass: "gateway_rejected",
            observedAt: Date(timeIntervalSince1970: 1))

        let data = try JSONEncoder().encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["rpc_method"] as? String == "chat.history")
        #expect(object["offset_present"] as? Bool == true)
        #expect(object["offset_type"] as? String == "integer")
        #expect(object["offset_value"] as? Int == 0)
        #expect(object["limit_present"] as? Bool == false)
        #expect(object["max_chars_present"] as? Bool == false)
        #expect(object["gateway_error_code"] as? String == "INVALID_REQUEST")
        #expect(object["encoded_property_names"] as? [String] == ["offset", "sessionKey"])
        #expect(object["gateway_validation_path"] as? String == "offset")
        #expect(object["gateway_error_message_class"] as? String == "integer_required")
        #expect(object["gateway_validator_identity"] as? String == "chat-history-0790d9f593ad")
        #expect(object["protocol_schema_version"] as? String == "gateway-protocol-v4")
        #expect(object["request_envelope_version"] as? Int == 4)
        #expect(object["elapsed_milliseconds"] as? Int == 42)
        #expect(object["session_hash"] as? String != "private-session-key")
        #expect(object["operation_id"] as? String != "client-local-operation-id")
        #expect(object["params"] == nil)
        #expect(object["message"] == nil)

        let record = "aies_diagnostic=" + data.base64EncodedString()
        #expect(OpenClawDiagnosticRecorder.decodeRecord(record) == event)

        for key in [
            "operation_id", "rpc_method", "admitted_at", "offset_present",
            "offset_type", "limit_present", "max_chars_present", "encoded_property_names",
            "gateway_validator_identity", "protocol_schema_version", "request_envelope_version",
            "elapsed_milliseconds",
        ] {
            var incomplete = object
            incomplete.removeValue(forKey: key)
            let incompleteData = try JSONSerialization.data(withJSONObject: incomplete)
            #expect(OpenClawDiagnosticRecorder.decodeRecord(
                "aies_diagnostic=" + incompleteData.base64EncodedString()) == nil)
        }

        var contradictory = object
        contradictory["offset_present"] = false
        let contradictoryData = try JSONSerialization.data(withJSONObject: contradictory)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + contradictoryData.base64EncodedString()) == nil)

        var rawParams = object
        rawParams["params"] = ["sessionKey": "private-session-key"]
        let rawParamsData = try JSONSerialization.data(withJSONObject: rawParams)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + rawParamsData.base64EncodedString()) == nil)

        var rawGatewayMessage = object
        rawGatewayMessage["gateway_error_message"] = "/offset: must be integer; token=private"
        let rawGatewayMessageData = try JSONSerialization.data(withJSONObject: rawGatewayMessage)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + rawGatewayMessageData.base64EncodedString()) == nil)
    }

    @Test func decoderRetainsLegacyV2RPCRecordsWithoutAdditiveValidatorCustody() throws {
        let legacyJSON = #"""
        {
          "schema": "argus.openclaw-ios.diagnostic-event.v2",
          "kind": "socket",
          "state": "request_completed",
          "observed_at": "2026-08-31T15:14:58.979Z",
          "process_instance_id": "1485c598a1351c7b",
          "launch_instance_id": "cd47892287ec50b9",
          "connection_role": "operator",
          "operation_id": "4b2cfeed24694acc",
          "rpc_method": "chat.history",
          "admitted_at": "2026-08-31T15:14:58.820Z",
          "gateway_error_code": "INVALID_REQUEST",
          "offset_present": true,
          "offset_type": "integer",
          "limit_present": true,
          "max_chars_present": true,
          "elapsed_milliseconds": 159,
          "result_class": "gateway_rejected"
        }
        """#
        let data = try #require(legacyJSON.data(using: .utf8))
        let record = "aies_diagnostic=" + data.base64EncodedString()
        let decoded = try #require(OpenClawDiagnosticRecorder.decodeRecord(record))

        #expect(decoded.rpcMethod == "chat.history")
        #expect(decoded.offsetPresent == true)
        #expect(decoded.offsetType == .integer)
        #expect(decoded.encodedPropertyNames == nil)
        #expect(decoded.gatewayValidatorIdentity == nil)
        #expect(decoded.protocolSchemaVersion == nil)
        #expect(decoded.requestEnvelopeVersion == nil)

        var partialEnrichment = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        partialEnrichment["offset_value"] = 0
        let partialData = try JSONSerialization.data(withJSONObject: partialEnrichment)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + partialData.base64EncodedString()) == nil)
    }

    @Test func apnsGatewayIdentityEvidenceIsHashedTypedAndInternallyConsistent() throws {
        let equal = OpenClawDiagnosticEvent(
            kind: .apns,
            state: "gateway_publication_admitted",
            connectionRole: .node,
            socketGeneration: 3,
            routeGeneration: 5,
            configurationGeneration: 7,
            registrationAttemptID: "private-registration-attempt",
            resultClass: "direct",
            configuredGatewayIdentityIdentifier: "wss://gateway.example.ts.net:443",
            observedGatewayIdentityIdentifier: "wss://gateway.example.ts.net:443",
            configuredGatewayIdentitySource: .activeGatewayConnectConfig,
            observedGatewayIdentitySource: .nodeRouteConnectOptions,
            gatewayIdentityComparison: .equal,
            apnsTransport: .direct,
            observedAt: Date(timeIntervalSince1970: 0))
        let missing = OpenClawDiagnosticEvent(
            kind: .apns,
            state: "gateway_publication_deferred",
            connectionRole: .node,
            socketGeneration: 11,
            routeGeneration: 13,
            configurationGeneration: 17,
            registrationAttemptID: "private-registration-attempt",
            providerStage: "node_route_admitted",
            resultClass: "node_gateway_identity_mismatch",
            configuredGatewayIdentityIdentifier: "wss://gateway.example.ts.net:443",
            configuredGatewayIdentitySource: .activeGatewayConnectConfig,
            observedGatewayIdentitySource: .nodeRouteConnectOptions,
            gatewayIdentityComparison: .observedMissing,
            apnsTransport: .relay,
            observedAt: Date(timeIntervalSince1970: 1))
        let different = OpenClawDiagnosticEvent(
            kind: .apns,
            state: "gateway_publication_deferred",
            connectionRole: .operator,
            registrationAttemptID: "private-registration-attempt",
            resultClass: "operator_gateway_identity_mismatch",
            configuredGatewayIdentityIdentifier: "wss://first.example.ts.net:443",
            observedGatewayIdentityIdentifier: "wss://second.example.ts.net:443",
            configuredGatewayIdentitySource: .activeGatewayConnectConfig,
            observedGatewayIdentitySource: .operatorRouteConnectOptions,
            gatewayIdentityComparison: .different,
            apnsTransport: .relay,
            observedAt: Date(timeIntervalSince1970: 2))

        for event in [equal, missing, different] {
            let data = try JSONEncoder().encode(event)
            let record = "aies_diagnostic=" + data.base64EncodedString()
            #expect(OpenClawDiagnosticRecorder.decodeRecord(record) == event)
            let output = String(decoding: data, as: UTF8.self)
            #expect(!output.contains("gateway.example.ts.net"))
            #expect(!output.contains("first.example.ts.net"))
            #expect(!output.contains("second.example.ts.net"))
            #expect(!output.contains("private-registration-attempt"))
        }
        #expect(equal.configuredGatewayIdentityHash?.count == 16)
        #expect(equal.configuredGatewayIdentityHash == equal.observedGatewayIdentityHash)
        #expect(equal.gatewayIdentityComparison == .equal)
        #expect(equal.apnsTransport == .direct)
        #expect(missing.configuredGatewayIdentityHash?.count == 16)
        #expect(missing.observedGatewayIdentityHash == nil)
        #expect(missing.gatewayIdentityComparison == .observedMissing)
        #expect(missing.socketGeneration == 11)
        #expect(missing.routeGeneration == 13)
        #expect(missing.configurationGeneration == 17)
        #expect(different.configuredGatewayIdentityHash != different.observedGatewayIdentityHash)
        #expect(different.observedGatewayIdentitySource == .operatorRouteConnectOptions)

        var inconsistent = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(missing)) as? [String: Any])
        inconsistent["gateway_identity_comparison"] = "equal"
        let inconsistentData = try JSONSerialization.data(withJSONObject: inconsistent)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + inconsistentData.base64EncodedString()) == nil)

        var falseMismatch = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(equal)) as? [String: Any])
        falseMismatch["state"] = "gateway_publication_deferred"
        falseMismatch["result_class"] = "node_gateway_identity_mismatch"
        let falseMismatchData = try JSONSerialization.data(withJSONObject: falseMismatch)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + falseMismatchData.base64EncodedString()) == nil)

        var falseAdmission = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(different)) as? [String: Any])
        falseAdmission["state"] = "gateway_publication_admitted"
        falseAdmission["result_class"] = "direct"
        let falseAdmissionData = try JSONSerialization.data(withJSONObject: falseAdmission)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + falseAdmissionData.base64EncodedString()) == nil)
    }

    @Test func chatProjectionCountsAndSessionGenerationAreBounded() throws {
        let event = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "history_application_completed",
            eventCount: 12,
            messageCount: 34,
            sessionGeneration: 56,
            observedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(event)
        let decoded = try #require(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + data.base64EncodedString()))
        #expect(decoded.eventCount == 12)
        #expect(decoded.messageCount == 34)
        #expect(decoded.sessionGeneration == 56)

        let rejected = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "history_application_completed",
            eventCount: -1,
            messageCount: -1)
        #expect(rejected.eventCount == nil)
        #expect(rejected.messageCount == nil)
    }

    @Test func buildTransitionMetadataIsTypedBoundedAndRestrictedToLifecycleEvents() throws {
        let event = OpenClawDiagnosticEvent(
            kind: .appLifecycle,
            state: "previous_run_unclosed_build_transition",
            priorBuildNumber: "104",
            priorSourceSHA: "22f90eacf93ba05f16aea6b106bd3c063f95d79d",
            priorMainExecutableUUID: "bec23370-891f-3fa9-91d4-d5021a687519",
            currentBuildNumber: "105",
            currentSourceSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            currentMainExecutableUUID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            observedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(event)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + data.base64EncodedString()) == event)

        var falseSameBuild = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        falseSameBuild["state"] = "previous_run_unclosed_same_build"
        let falseSameBuildData = try JSONSerialization.data(withJSONObject: falseSameBuild)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + falseSameBuildData.base64EncodedString()) == nil)

        let sameBuild = OpenClawDiagnosticEvent(
            kind: .appLifecycle,
            state: "previous_run_unclosed_same_build",
            priorBuildNumber: "104",
            priorSourceSHA: "22f90eacf93ba05f16aea6b106bd3c063f95d79d",
            priorMainExecutableUUID: "bec23370-891f-3fa9-91d4-d5021a687519",
            currentBuildNumber: "104",
            currentSourceSHA: "22f90eacf93ba05f16aea6b106bd3c063f95d79d",
            currentMainExecutableUUID: "bec23370-891f-3fa9-91d4-d5021a687519",
            observedAt: Date(timeIntervalSince1970: 1))
        let sameBuildData = try JSONEncoder().encode(sameBuild)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + sameBuildData.base64EncodedString()) == sameBuild)

        var falseTransition = try #require(
            JSONSerialization.jsonObject(with: sameBuildData) as? [String: Any])
        falseTransition["state"] = "previous_run_unclosed_build_transition"
        let falseTransitionData = try JSONSerialization.data(withJSONObject: falseTransition)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + falseTransitionData.base64EncodedString()) == nil)

        var falseUnknown = falseTransition
        falseUnknown["state"] = "previous_run_unclosed_identity_unknown"
        let falseUnknownData = try JSONSerialization.data(withJSONObject: falseUnknown)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + falseUnknownData.base64EncodedString()) == nil)

        var genuinelyUnknown = falseUnknown
        genuinelyUnknown.removeValue(forKey: "current_build_number")
        genuinelyUnknown.removeValue(forKey: "current_source_sha")
        genuinelyUnknown.removeValue(forKey: "current_main_executable_uuid")
        let genuinelyUnknownData = try JSONSerialization.data(withJSONObject: genuinelyUnknown)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + genuinelyUnknownData.base64EncodedString()) != nil)

        let malformed = OpenClawDiagnosticEvent(
            kind: .appLifecycle,
            state: "previous_run_unclosed_identity_unknown",
            priorBuildNumber: "104-beta",
            priorSourceSHA: "22F90EACF93BA05F16AEA6B106BD3C063F95D79D",
            priorMainExecutableUUID: "BEC23370-891F-3FA9-91D4-D5021A687519")
        #expect(malformed.priorBuildNumber == nil)
        #expect(malformed.priorSourceSHA == nil)
        #expect(malformed.priorMainExecutableUUID == nil)

        var wrongKind = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        wrongKind["kind"] = "chat"
        let wrongKindData = try JSONSerialization.data(withJSONObject: wrongKind)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + wrongKindData.base64EncodedString()) == nil)

        var partialIdentity = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        partialIdentity.removeValue(forKey: "prior_source_sha")
        let partialIdentityData = try JSONSerialization.data(withJSONObject: partialIdentity)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + partialIdentityData.base64EncodedString()) == nil)

        var missingCurrentIdentity = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        missingCurrentIdentity.removeValue(forKey: "current_build_number")
        missingCurrentIdentity.removeValue(forKey: "current_source_sha")
        missingCurrentIdentity.removeValue(forKey: "current_main_executable_uuid")
        let missingCurrentIdentityData = try JSONSerialization.data(withJSONObject: missingCurrentIdentity)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + missingCurrentIdentityData.base64EncodedString()) == nil)
    }

    @Test func v2RouteAndSocketRecordsRequireAnExplicitRoleField() throws {
        for kind in [OpenClawDiagnosticEvent.Kind.route, .socket] {
            let event = OpenClawDiagnosticEvent(
                kind: kind,
                state: "connected",
                connectionRole: .unknown,
                observedAt: Date(timeIntervalSince1970: 0))
            var object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
            #expect(object["connection_role"] as? String == "unknown")
            object.removeValue(forKey: "connection_role")
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(OpenClawDiagnosticRecorder.decodeRecord(
                "aies_diagnostic=" + data.base64EncodedString()) == nil)
        }
    }

    @Test func v2RecordsRequireProcessAndLaunchInstanceIdentity() throws {
        let event = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "received",
            observedAt: Date(timeIntervalSince1970: 0))
        let validObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])

        for requiredKey in ["process_instance_id", "launch_instance_id"] {
            var object = validObject
            object.removeValue(forKey: requiredKey)
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(OpenClawDiagnosticRecorder.decodeRecord(
                "aies_diagnostic=" + data.base64EncodedString()) == nil)
        }
    }

    @Test func decoderRejectsInjectedOrMalformedMetadata() throws {
        let valid = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "received",
            sessionIdentifier: "private-session",
            runIdentifier: "run-1",
            observedAt: Date(timeIntervalSince1970: 0))
        let validObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])

        let mutations: [[String: Any]] = [
            ["prompt": "private transcript"],
            ["run_id": "Bearer sk-private-credential"],
            ["session_hash": "private-session"],
            ["launch_id": "unhashed-launch-identifier"],
            ["process_instance_id": "unhashed-process-identifier"],
            ["launch_instance_id": "unhashed-launch-identifier"],
            ["prior_process_instance_id": "unhashed-prior-identifier"],
            ["prior_launch_instance_id": "unhashed-prior-identifier"],
            ["connection_role": "administrator"],
            ["diagnostic_attempt_id": "private-attempt"],
            ["registration_attempt_id": "private-attempt"],
            ["device_identity_hash": "private-device"],
            ["configured_gateway_identity_hash": "private-gateway"],
            ["observed_gateway_identity_hash": "private-gateway"],
            ["configured_gateway_identity_source": "raw_user_input"],
            ["observed_gateway_identity_source": "raw_user_input"],
            ["gateway_identity_comparison": "approximately_equal"],
            ["apns_transport": "broadcast"],
            ["encoded_property_names": ["message"]],
            ["gateway_validation_path": "raw/private/path"],
            ["gateway_error_message_class": "token=private"],
            ["gateway_validator_identity": "unreviewed-validator"],
            ["protocol_schema_version": "gateway-protocol-v999"],
            ["request_envelope_version": 999],
            ["prior_build_number": "build private"],
            ["prior_source_sha": "22F90EACF93BA05F16AEA6B106BD3C063F95D79D"],
            ["prior_main_executable_uuid": "BEC23370-891F-3FA9-91D4-D5021A687519"],
            ["provider": "sklivecredential"],
            ["provider_stage": "sklivecredential"],
            ["codec": "sklivecredential"],
            ["playback_path": "sklivecredential"],
            ["result_class": "sklivecredential"],
            ["topic": "sklivecredential"],
            ["environment": "sklivecredential"],
            ["provider_stage": "provider result contained a secret"],
            ["topic": "bad topic"],
            ["process_id": -1],
            ["byte_count": -1],
            ["sample_rate": 0],
            ["duration_milliseconds": -1],
            ["elapsed_milliseconds": -1],
            ["event_count": -1],
            ["message_count": -1],
            ["observed_at": "not-a-timestamp"],
            ["network_interfaces": ["wifi", "cellular"]],
        ]
        for mutation in mutations {
            var object = validObject
            object.merge(mutation) { _, replacement in replacement }
            let data = try JSONSerialization.data(withJSONObject: object)
            let record = "aies_diagnostic=" + data.base64EncodedString()
            #expect(OpenClawDiagnosticRecorder.decodeRecord(record) == nil)
        }

        let oversized = "aies_diagnostic=" + String(repeating: "a", count: 8192)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(oversized) == nil)

        var unsafeObject = validObject
        unsafeObject["run_id"] = "Bearer sk-private-credential"
        let unsafeEvent = try JSONDecoder().decode(
            OpenClawDiagnosticEvent.self,
            from: JSONSerialization.data(withJSONObject: unsafeObject))
        let captured = OSAllocatedUnfairLock(initialState: [String]())
        OpenClawDiagnosticRecorder.installSink { line in
            captured.withLock { $0.append(line) }
        }
        defer { OpenClawDiagnosticRecorder.clearSink() }
        OpenClawDiagnosticRecorder.record(unsafeEvent)
        #expect(captured.withLock { $0.isEmpty })
    }

    @Test func initializerDropsSafeCharacterSecretsFromClosedV2Metadata() {
        let event = OpenClawDiagnosticEvent(
            kind: .tts,
            state: "tts_request_admitted",
            provider: "sklivecredential",
            providerStage: "sklivecredential",
            codec: "sklivecredential",
            playbackPath: "sklivecredential",
            resultClass: "sklivecredential",
            topic: "sklivecredential",
            environment: "sklivecredential")

        #expect(event.provider == nil)
        #expect(event.providerStage == nil)
        #expect(event.codec == nil)
        #expect(event.playbackPath == nil)
        #expect(event.resultClass == nil)
        #expect(event.topic == nil)
        #expect(event.environment == nil)
    }

    @Test func newEventsCarryStablePerProcessLaunchMetadata() {
        let first = OpenClawDiagnosticEvent(kind: .appLifecycle, state: "first")
        let second = OpenClawDiagnosticEvent(kind: .tts, state: "second")

        #expect(first.processID == Int(ProcessInfo.processInfo.processIdentifier))
        #expect(second.processID == first.processID)
        #expect(first.launchID?.count == 16)
        #expect(second.launchID == first.launchID)
        #expect(first.processInstanceID == OpenClawDiagnosticEvent.currentProcessInstanceID)
        #expect(second.processInstanceID == first.processInstanceID)
        #expect(first.launchInstanceID == OpenClawDiagnosticEvent.currentLaunchInstanceID)
        #expect(second.launchInstanceID == first.launchInstanceID)
    }

    @Test func decoderRetainsLegacyV1RecordsWithoutNewMetadata() throws {
        let current = OpenClawDiagnosticEvent(
            kind: .chat,
            state: "received",
            socketGeneration: 3,
            observedAt: Date(timeIntervalSince1970: 0))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["schema"] = "argus.openclaw-ios.diagnostic-event.v1"
        for key in [
            "process_id",
            "launch_id",
            "process_instance_id",
            "launch_instance_id",
            "operation_generation",
            "byte_count",
            "sample_rate",
            "duration_milliseconds",
        ] {
            object.removeValue(forKey: key)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let record = "aies_diagnostic=" + data.base64EncodedString()
        let decoded = try #require(OpenClawDiagnosticRecorder.decodeRecord(record))

        #expect(decoded.schema == "argus.openclaw-ios.diagnostic-event.v1")
        #expect(decoded.kind == .chat)
        #expect(decoded.state == "received")
        #expect(decoded.socketGeneration == 3)
        #expect(decoded.processID == nil)
        #expect(decoded.launchID == nil)
        #expect(decoded.processInstanceID == nil)
        #expect(decoded.launchInstanceID == nil)

        var injectedV1 = object
        injectedV1["connection_role"] = "node"
        let injectedData = try JSONSerialization.data(withJSONObject: injectedV1)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + injectedData.base64EncodedString()) == nil)
    }

    @Test func decoderRetainsEveryLegacyV1OptionalField() throws {
        let current = OpenClawDiagnosticEvent(
            kind: .tts,
            state: "provider_result",
            processIdentifier: 4242,
            launchIdentifier: "legacy-launch",
            socketGeneration: 3,
            routeGeneration: 5,
            activityGeneration: 7,
            sessionIdentifier: "session",
            runIdentifier: "run",
            messageIdentifier: "message",
            eventIdentifier: "event",
            operationIdentifier: "operation",
            operationGeneration: 11,
            sequence: 13,
            stream: "pcm",
            byteCount: 1024,
            sampleRate: 44100,
            durationMilliseconds: 250,
            observedAt: Date(timeIntervalSince1970: 0))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["schema"] = "argus.openclaw-ios.diagnostic-event.v1"
        for key in [
            "process_instance_id",
            "launch_instance_id",
            "connection_role",
            "configuration_generation",
            "playback_generation",
            "cancellation_generation",
        ] {
            object.removeValue(forKey: key)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try #require(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + data.base64EncodedString()))

        #expect(decoded.processID == 4242)
        #expect(decoded.launchID?.count == 16)
        #expect(decoded.operationGeneration == 11)
        #expect(decoded.byteCount == 1024)
        #expect(decoded.sampleRate == 44100)
        #expect(decoded.durationMilliseconds == 250)
    }

    @Test func decoderRejectsAPNsKindForgedIntoLegacyV1Schema() throws {
        let current = OpenClawDiagnosticEvent(
            kind: .apns,
            state: "os_registration_requested",
            observedAt: Date(timeIntervalSince1970: 0))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["schema"] = "argus.openclaw-ios.diagnostic-event.v1"
        for key in ["process_instance_id", "launch_instance_id"] {
            object.removeValue(forKey: key)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(OpenClawDiagnosticRecorder.decodeRecord(
            "aies_diagnostic=" + data.base64EncodedString()) == nil)
    }
}
