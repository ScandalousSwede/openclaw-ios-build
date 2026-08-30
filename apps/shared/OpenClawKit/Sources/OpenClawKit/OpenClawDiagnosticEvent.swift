import CryptoKit
import Foundation
import os

public enum OpenClawDiagnosticConnectionRole: String, Codable, Sendable {
    case node
    case `operator`
    case unknown
}

public struct OpenClawDiagnosticEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case appLifecycle = "app_lifecycle"
        case apns
        case chat = "chat"
        case liveActivity = "live_activity"
        case network = "network"
        case reconnect = "reconnect"
        case route = "route"
        case socket = "socket"
        case tts = "tts"
    }

    public static let schemaName = "argus.openclaw-ios.diagnostic-event.v2"
    private static let supportedSchemaNames: Set<String> = [
        "argus.openclaw-ios.diagnostic-event.v1",
        "argus.openclaw-ios.diagnostic-event.v2",
    ]
    private static let processLaunchIdentifier = UUID().uuidString
    public static let currentProcessInstanceID = Self.hashedIdentifier(UUID().uuidString)!
    public static let currentLaunchInstanceID = Self.hashedIdentifier(UUID().uuidString)!

    public let schema: String
    public let observedAt: String
    public let kind: Kind
    public let state: String
    public let processID: Int?
    public let launchID: String?
    public let processInstanceID: String?
    public let launchInstanceID: String?
    public let priorProcessInstanceID: String?
    public let priorLaunchInstanceID: String?
    public let connectionRole: OpenClawDiagnosticConnectionRole?
    public let socketGeneration: UInt64?
    public let routeGeneration: UInt64?
    public let nodeRouteGeneration: UInt64?
    public let operatorRouteGeneration: UInt64?
    public let configurationGeneration: UInt64?
    public let activityGeneration: UInt64?
    public let playbackGeneration: UInt64?
    public let cancellationGeneration: UInt64?
    public let sessionHash: String?
    public let runID: String?
    public let messageID: String?
    public let eventID: String?
    public let operationID: String?
    public let operationGeneration: UInt64?
    public let diagnosticAttemptID: String?
    public let registrationAttemptID: String?
    public let sequence: Int?
    public let stream: String?
    public let provider: String?
    public let providerStage: String?
    public let codec: String?
    public let playbackPath: String?
    public let resultClass: String?
    public let deviceIdentityHash: String?
    public let topic: String?
    public let environment: String?
    public let byteCount: Int?
    public let sampleRate: Int?
    public let durationMilliseconds: Int?
    public let networkInterfaces: [String]

    public init(
        kind: Kind,
        state: String,
        processIdentifier: Int? = nil,
        launchIdentifier: String? = nil,
        processInstanceIdentifier: String? = nil,
        launchInstanceIdentifier: String? = nil,
        priorProcessInstanceID: String? = nil,
        priorLaunchInstanceID: String? = nil,
        connectionRole: OpenClawDiagnosticConnectionRole? = nil,
        socketGeneration: UInt64? = nil,
        routeGeneration: UInt64? = nil,
        nodeRouteGeneration: UInt64? = nil,
        operatorRouteGeneration: UInt64? = nil,
        configurationGeneration: UInt64? = nil,
        activityGeneration: UInt64? = nil,
        playbackGeneration: UInt64? = nil,
        cancellationGeneration: UInt64? = nil,
        sessionIdentifier: String? = nil,
        runIdentifier: String? = nil,
        messageIdentifier: String? = nil,
        eventIdentifier: String? = nil,
        operationIdentifier: String? = nil,
        operationGeneration: UInt64? = nil,
        diagnosticAttemptID: String? = nil,
        registrationAttemptID: String? = nil,
        sequence: Int? = nil,
        stream: String? = nil,
        provider: String? = nil,
        providerStage: String? = nil,
        codec: String? = nil,
        playbackPath: String? = nil,
        resultClass: String? = nil,
        deviceIdentityIdentifier: String? = nil,
        topic: String? = nil,
        environment: String? = nil,
        byteCount: Int? = nil,
        sampleRate: Int? = nil,
        durationMilliseconds: Int? = nil,
        networkInterfaces: [String] = [],
        observedAt: Date = Date())
    {
        self.schema = Self.schemaName
        self.observedAt = Self.timestamp(observedAt)
        self.kind = kind
        self.state = Self.sanitizedToken(state, maximumLength: 64) ?? "redacted"
        let resolvedProcessID = processIdentifier ?? Int(ProcessInfo.processInfo.processIdentifier)
        self.processID = resolvedProcessID > 0 ? resolvedProcessID : nil
        self.launchID = Self.hashedIdentifier(launchIdentifier ?? Self.processLaunchIdentifier)
        self.processInstanceID = Self.normalizedIdentifierDigest(processInstanceIdentifier)
            ?? Self.currentProcessInstanceID
        self.launchInstanceID = Self.normalizedIdentifierDigest(launchInstanceIdentifier)
            ?? Self.currentLaunchInstanceID
        self.priorProcessInstanceID = priorProcessInstanceID.flatMap {
            Self.isLowercaseHexDigest($0) ? $0 : nil
        }
        self.priorLaunchInstanceID = priorLaunchInstanceID.flatMap {
            Self.isLowercaseHexDigest($0) ? $0 : nil
        }
        self.connectionRole = connectionRole ?? ([Kind.route, .socket].contains(kind) ? .unknown : nil)
        self.socketGeneration = socketGeneration
        self.routeGeneration = routeGeneration
        self.nodeRouteGeneration = nodeRouteGeneration
        self.operatorRouteGeneration = operatorRouteGeneration
        self.configurationGeneration = configurationGeneration
        self.activityGeneration = activityGeneration
        self.playbackGeneration = playbackGeneration
        self.cancellationGeneration = cancellationGeneration
        self.sessionHash = Self.hashedIdentifier(sessionIdentifier)
        self.runID = Self.hashedIdentifier(runIdentifier)
        self.messageID = Self.hashedIdentifier(messageIdentifier)
        self.eventID = Self.hashedIdentifier(eventIdentifier)
        self.operationID = Self.hashedIdentifier(operationIdentifier)
        self.operationGeneration = operationGeneration
        self.diagnosticAttemptID = Self.hashedIdentifier(diagnosticAttemptID)
        self.registrationAttemptID = Self.hashedIdentifier(registrationAttemptID)
        self.sequence = sequence.flatMap { $0 >= 0 ? $0 : nil }
        self.stream = Self.sanitizedToken(stream, maximumLength: 64)
        self.provider = Self.allowlistedToken(provider, allowed: Self.allowedProviders)
        self.providerStage = Self.allowlistedToken(providerStage, allowed: Self.allowedProviderStages)
        self.codec = Self.allowlistedToken(codec, allowed: Self.allowedCodecs)
        self.playbackPath = Self.allowlistedToken(playbackPath, allowed: Self.allowedPlaybackPaths)
        self.resultClass = Self.allowlistedToken(resultClass, allowed: Self.allowedResultClasses)
        self.deviceIdentityHash = Self.hashedIdentifier(deviceIdentityIdentifier)
        self.topic = Self.allowlistedToken(topic, allowed: Self.allowedTopics)
        self.environment = Self.allowlistedToken(environment, allowed: Self.allowedEnvironments)
        self.byteCount = byteCount.flatMap { $0 >= 0 ? $0 : nil }
        self.sampleRate = sampleRate.flatMap { (1...384_000).contains($0) ? $0 : nil }
        self.durationMilliseconds = durationMilliseconds.flatMap { $0 >= 0 ? $0 : nil }
        let sanitizedInterfaces = Array(Set(networkInterfaces.compactMap {
            Self.sanitizedToken($0, maximumLength: 32)
        })).sorted()
        self.networkInterfaces = Array(sanitizedInterfaces.prefix(8))
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case observedAt = "observed_at"
        case kind
        case state
        case processID = "process_id"
        case launchID = "launch_id"
        case processInstanceID = "process_instance_id"
        case launchInstanceID = "launch_instance_id"
        case priorProcessInstanceID = "prior_process_instance_id"
        case priorLaunchInstanceID = "prior_launch_instance_id"
        case connectionRole = "connection_role"
        case socketGeneration = "socket_generation"
        case routeGeneration = "route_generation"
        case nodeRouteGeneration = "node_route_generation"
        case operatorRouteGeneration = "operator_route_generation"
        case configurationGeneration = "configuration_generation"
        case activityGeneration = "activity_generation"
        case playbackGeneration = "playback_generation"
        case cancellationGeneration = "cancellation_generation"
        case sessionHash = "session_hash"
        case runID = "run_id"
        case messageID = "message_id"
        case eventID = "event_id"
        case operationID = "operation_id"
        case operationGeneration = "operation_generation"
        case diagnosticAttemptID = "diagnostic_attempt_id"
        case registrationAttemptID = "registration_attempt_id"
        case sequence
        case stream
        case provider
        case providerStage = "provider_stage"
        case codec
        case playbackPath = "playback_path"
        case resultClass = "result_class"
        case deviceIdentityHash = "device_identity_hash"
        case topic
        case environment
        case byteCount = "byte_count"
        case sampleRate = "sample_rate"
        case durationMilliseconds = "duration_milliseconds"
        case networkInterfaces = "network_interfaces"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func hashedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096 else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedIdentifierDigest(_ value: String?) -> String? {
        guard let value else { return nil }
        return Self.isLowercaseHexDigest(value) ? value : Self.hashedIdentifier(value)
    }

    private static func sanitizedToken(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumLength else { return nil }
        let isSafe = trimmed.utf8.allSatisfy { byte in
            switch byte {
            case 45...46, 48...58, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
        return isSafe ? trimmed : nil
    }

    private static func allowlistedToken(_ value: String?, allowed: Set<String>) -> String? {
        guard let sanitized = Self.sanitizedToken(value, maximumLength: 128),
              allowed.contains(sanitized)
        else { return nil }
        return sanitized
    }

    private static let allowedProviders: Set<String> = [
        "elevenlabs", "none", "system", "unknown",
    ]
    private static let allowedCodecs: Set<String> = [
        "mp3", "pcm", "system_speech", "unknown", "unspecified",
    ]
    private static let allowedPlaybackPaths: Set<String> = ["mp3", "pcm", "system"]
    private static let allowedEnvironments: Set<String> = ["production", "sandbox"]
    private static let allowedTopics: Set<String> = [
        "ai.openclaw.client",
        "ai.openclaw.client.J76B47MZ6V",
    ]
    private static let allowedProviderStages: Set<String> = [
        "application_launch",
        "audio_payload_validated",
        "audio_session_activation_failed",
        "audio_session_activation_started",
        "audio_session_activation_succeeded",
        "audio_session_to_system",
        "decoder_created",
        "decoder_selected",
        "failed",
        "fallback_completed",
        "fallback_failed",
        "fallback_selected",
        "fallback_started",
        "first_render_callback_observed",
        "mp3_to_system",
        "mp3_retry",
        "node_permission_grant",
        "output_route_observed",
        "payload_or_relay_preparation",
        "pcm_to_mp3",
        "playback_cancelled",
        "playback_completed",
        "playback_failed",
        "playback_submission_accepted",
        "playback_submission_started",
        "player_instance_created",
        "provider_request_started",
        "provider_response_received",
        "provider_resolved",
        "provider_to_system",
        "provider_unavailable_to_system",
        "relay_identity_route",
        "relay_registration_response",
        "stream_completed",
        "stream_first_chunk_received",
        "speaking",
        "system_fallback",
        "transport_write_result",
        "audio_received",
        "completed",
        "config_loading",
        "config_redacted",
        "generating",
        "idle",
        "pcm_playing",
        "permission_required",
        "tts_audio_received",
        "tts_audio_session_prepare_failed",
        "tts_audio_session_prepare_started",
        "tts_audio_session_prepared",
        "tts_audio_session_restore_started",
        "tts_completed",
        "tts_config_loading",
        "tts_config_redacted",
        "tts_decoder_selected",
        "tts_failed",
        "tts_fallback_transition",
        "tts_first_audio_byte",
        "tts_generating",
        "tts_generation_cancelled",
        "tts_generation_finalized",
        "tts_idle",
        "tts_mp3_retry",
        "tts_pcm_playing",
        "tts_permission_required",
        "tts_playback_completed",
        "tts_playback_failed",
        "tts_playback_pipeline_entered",
        "tts_playback_started",
        "tts_player_call_entered",
        "tts_player_call_returned",
        "tts_provider_request_started",
        "tts_provider_resolved",
        "tts_provider_result",
        "tts_request_admitted",
        "tts_speaking",
        "tts_system_fallback",
        "tts_system_speech_call_entered",
        "watch_permission_grant",
    ]
    private static let allowedResultClasses: Set<String> = [
        "cancelled",
        "coalesced_request",
        "direct",
        "failed",
        "finished",
        "http_4xx",
        "http_5xx",
        "incomplete",
        "interrupted",
        "local_direct_registration_match",
        "local_or_relay_preparation_failed",
        "marker_path_unavailable",
        "marker_persisted",
        "marker_replaced",
        "marker_write_failed",
        "new_os_token_received",
        "node_event_transport",
        "not_attempted",
        "playback_failed",
        "production_route_airplay",
        "production_route_bluetooth",
        "production_route_car_audio",
        "production_route_headphones",
        "production_route_hdmi",
        "production_route_no_output",
        "production_route_other",
        "production_route_receiver",
        "production_route_speaker",
        "production_route_usb",
        "provider_content_type_validated_nonempty",
        "publication_already_in_flight",
        "received",
        "relay",
        "relay_http_rejected",
        "relay_http_failed",
        "requested",
        "route_bound",
        "route_or_configuration_changed_after_payload",
        "route_or_configuration_changed_after_transport_write",
        "route_or_configuration_changed_before_payload",
        "success",
        "system_error",
        "timeout",
        "transport_error",
        "transport_or_route_unavailable",
        "transport_write_accepted_unacknowledged",
        "unattributed_callback",
        "unattributed_system_error",
        "zero_audio",
    ]

    fileprivate var isValidDecodedRecord: Bool {
        guard Self.supportedSchemaNames.contains(self.schema),
              Self.isValidTimestamp(self.observedAt),
              self.state == Self.sanitizedToken(self.state, maximumLength: 64),
              self.processID.map({ $0 > 0 }) ?? true,
              self.launchID.map(Self.isLowercaseHexDigest) ?? true,
              self.processInstanceID.map(Self.isLowercaseHexDigest) ?? true,
              self.launchInstanceID.map(Self.isLowercaseHexDigest) ?? true,
              self.priorProcessInstanceID.map(Self.isLowercaseHexDigest) ?? true,
              self.priorLaunchInstanceID.map(Self.isLowercaseHexDigest) ?? true,
              self.runID.map(Self.isLowercaseHexDigest) ?? true,
              self.messageID.map(Self.isLowercaseHexDigest) ?? true,
              self.eventID.map(Self.isLowercaseHexDigest) ?? true,
              self.operationID.map(Self.isLowercaseHexDigest) ?? true,
              self.diagnosticAttemptID.map(Self.isLowercaseHexDigest) ?? true,
              self.registrationAttemptID.map(Self.isLowercaseHexDigest) ?? true,
              self.deviceIdentityHash.map(Self.isLowercaseHexDigest) ?? true,
              self.byteCount.map({ $0 >= 0 }) ?? true,
              self.sampleRate.map({ (1...384_000).contains($0) }) ?? true,
              self.durationMilliseconds.map({ $0 >= 0 }) ?? true,
              self.stream == Self.sanitizedToken(self.stream, maximumLength: 64),
              self.provider == Self.allowlistedToken(self.provider, allowed: Self.allowedProviders),
              self.providerStage == Self.allowlistedToken(
                  self.providerStage, allowed: Self.allowedProviderStages),
              self.codec == Self.allowlistedToken(self.codec, allowed: Self.allowedCodecs),
              self.playbackPath == Self.allowlistedToken(
                  self.playbackPath, allowed: Self.allowedPlaybackPaths),
              self.resultClass == Self.allowlistedToken(
                  self.resultClass, allowed: Self.allowedResultClasses),
              self.topic == Self.allowlistedToken(self.topic, allowed: Self.allowedTopics),
              self.environment == Self.allowlistedToken(
                  self.environment, allowed: Self.allowedEnvironments),
              self.sequence.map({ $0 >= 0 }) ?? true,
              self.networkInterfaces.count <= 8,
              self.networkInterfaces == Array(Set(self.networkInterfaces)).sorted(),
              self.networkInterfaces.allSatisfy({
                  $0 == Self.sanitizedToken($0, maximumLength: 32)
              }),
              self.sessionHash.map(Self.isLowercaseHexDigest) ?? true
        else {
            return false
        }
        if self.schema == "argus.openclaw-ios.diagnostic-event.v1", self.kind == .apns {
            return false
        }
        if self.schema == Self.schemaName,
           [Kind.route, .socket].contains(self.kind),
           self.connectionRole == nil
        {
            return false
        }
        return true
    }

    private static func isValidTimestamp(_ value: String) -> Bool {
        guard value.utf8.count == 24 else { return false }
        let bytes = Array(value.utf8)
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90]
        for (index, byte) in bytes.enumerated() {
            if let separator = separators[index] {
                guard byte == separator else { return false }
            } else if !(48...57).contains(byte) {
                return false
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private static func isLowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum OpenClawDiagnosticRecorder {
    public typealias Sink = @Sendable (String) -> Void

    private static let sink = OSAllocatedUnfairLock<Sink?>(initialState: nil)
    private static let recordPrefix = "aies_diagnostic="
    private static let maximumEncodedRecordBytes = 8192
    private static let requiredKeys: Set<String> = [
        "schema",
        "observed_at",
        "kind",
        "state",
        "network_interfaces",
    ]
    private static let v1AllowedKeys = OpenClawDiagnosticRecorder.requiredKeys.union([
        "socket_generation",
        "route_generation",
        "activity_generation",
        "session_hash",
        "run_id",
        "message_id",
        "event_id",
        "operation_id",
        "process_id",
        "launch_id",
        "operation_generation",
        "sequence",
        "stream",
        "byte_count",
        "sample_rate",
        "duration_milliseconds",
    ])
    private static let v2AllowedKeys = OpenClawDiagnosticRecorder.v1AllowedKeys.union([
        "process_id",
        "launch_id",
        "process_instance_id",
        "launch_instance_id",
        "prior_process_instance_id",
        "prior_launch_instance_id",
        "connection_role",
        "socket_generation",
        "route_generation",
        "node_route_generation",
        "operator_route_generation",
        "configuration_generation",
        "activity_generation",
        "playback_generation",
        "cancellation_generation",
        "session_hash",
        "run_id",
        "message_id",
        "event_id",
        "operation_id",
        "operation_generation",
        "diagnostic_attempt_id",
        "registration_attempt_id",
        "sequence",
        "stream",
        "provider",
        "provider_stage",
        "codec",
        "playback_path",
        "result_class",
        "device_identity_hash",
        "topic",
        "environment",
        "byte_count",
        "sample_rate",
        "duration_milliseconds",
    ])

    public static func installSink(_ sink: @escaping Sink) {
        self.sink.withLock { current in
            current = sink
        }
    }

    public static func clearSink() {
        self.sink.withLock { current in
            current = nil
        }
    }

    public static func record(_ event: OpenClawDiagnosticEvent) {
        guard event.isValidDecodedRecord else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(event) else { return }
        let line = self.recordPrefix + encoded.base64EncodedString()
        let currentSink = self.sink.withLock { $0 }
        currentSink?(line)
    }

    public static func decodeRecord(_ record: String) -> OpenClawDiagnosticEvent? {
        guard record.utf8.count <= self.maximumEncodedRecordBytes,
              record.hasPrefix(self.recordPrefix),
              !record.contains(where: { $0.isWhitespace })
        else {
            return nil
        }
        let encoded = String(record.dropFirst(self.recordPrefix.count))
        guard let data = Data(base64Encoded: encoded),
              data.count <= self.maximumEncodedRecordBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let keys = Set(object.keys)
        guard let schema = object["schema"] as? String else { return nil }
        let allowedKeys: Set<String>
        switch schema {
        case "argus.openclaw-ios.diagnostic-event.v1":
            allowedKeys = self.v1AllowedKeys
        case OpenClawDiagnosticEvent.schemaName:
            allowedKeys = self.v2AllowedKeys
        default:
            return nil
        }
        guard self.requiredKeys.isSubset(of: keys), keys.isSubset(of: allowedKeys),
              let event = try? JSONDecoder().decode(OpenClawDiagnosticEvent.self, from: data),
              event.isValidDecodedRecord
        else {
            return nil
        }
        return event
    }
}
