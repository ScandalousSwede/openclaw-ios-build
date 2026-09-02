import CryptoKit
import Foundation
import os

public enum OpenClawDiagnosticConnectionRole: String, Codable, Sendable {
    case node
    case `operator`
    case unknown
}

public enum OpenClawDiagnosticRPCOffsetType: String, Codable, Equatable, Sendable {
    case absent
    case integer
    case invalid
}

public enum OpenClawDiagnosticRPCEncodedPropertyName: String, Codable, Equatable, Hashable, Sendable {
    case agentID = "agentId"
    case limit
    case maxChars
    case offset
    case sessionKey
}

public enum OpenClawDiagnosticGatewayValidationPath: String, Codable, Equatable, Sendable {
    case additionalProperty = "additional_property"
    case agentID = "agent_id"
    case limit
    case maxChars = "max_chars"
    case offset
    case selectedAgent = "selected_agent"
    case sessionKey = "session_key"
    case unknown
}

public enum OpenClawDiagnosticGatewayErrorMessageClass: String, Codable, Equatable, Sendable {
    case integerRequired = "integer_required"
    case invalidRequestOther = "invalid_request_other"
    case maximumViolation = "maximum_violation"
    case minimumViolation = "minimum_violation"
    case nonEmptyStringRequired = "non_empty_string_required"
    case requiredPropertyMissing = "required_property_missing"
    case selectedAgentInvalid = "selected_agent_invalid"
    case unexpectedProperty = "unexpected_property"
}

public enum OpenClawDiagnosticGatewayIdentitySource: String, Codable, Equatable, Sendable {
    case activeGatewayConnectConfig = "active_gateway_connect_config"
    case nodeRouteConnectOptions = "node_route_connect_options"
    case operatorRouteConnectOptions = "operator_route_connect_options"
}

public enum OpenClawDiagnosticGatewayIdentityComparison: String, Codable, Equatable, Sendable {
    case equal
    case configuredMissing = "configured_missing"
    case observedMissing = "observed_missing"
    case different
}

public enum OpenClawDiagnosticAPNsTransport: String, Codable, Equatable, Sendable {
    case direct
    case relay
}

public enum OpenClawDiagnosticAudioByteParity: String, Codable, Equatable, Sendable {
    case even
    case odd
}

public enum OpenClawDiagnosticAudioMagicType: String, Codable, Equatable, Sendable {
    case id3MPEG = "id3_mpeg"
    case mpegFrameSync = "mpeg_frame_sync"
    case riffWave = "riff_wave"
    case oggContainer = "ogg_container"
    case oggOpus = "ogg_opus"
    case rawNoKnownHeader = "raw_no_known_header"
    case empty
}

public enum OpenClawDiagnosticAudioOutputRouteClass: String, Codable, Equatable, Hashable, Sendable {
    case airPlay = "airplay"
    case bluetooth
    case builtInReceiver = "built_in_receiver"
    case builtInSpeaker = "built_in_speaker"
    case carAudio = "car_audio"
    case headphones
    case hdmi
    case lineOut = "line_out"
    case noOutput = "no_output"
    case other
    case unknown
    case usb
}

public enum OpenClawDiagnosticAudioRouteChangeReason: String, Codable, Equatable, Sendable {
    case categoryChange = "category_change"
    case newDeviceAvailable = "new_device_available"
    case noSuitableRoute = "no_suitable_route"
    case oldDeviceUnavailable = "old_device_unavailable"
    case override
    case routeConfigurationChange = "route_configuration_change"
    case unknown
    case wakeFromSleep = "wake_from_sleep"
}

public enum OpenClawDiagnosticAudioInterruptionType: String, Codable, Equatable, Sendable {
    case began
    case ended
    case unknown
}

public enum OpenClawDiagnosticAudioInterruptionReason: String, Codable, Equatable, Sendable {
    case appWasSuspended = "app_was_suspended"
    case builtInMicMuted = "built_in_mic_muted"
    case defaultReason = "default"
    case unknown
}

public enum OpenClawDiagnosticAudioInterruptionOption: String, Codable, Equatable, Hashable, Sendable {
    case shouldResume = "should_resume"
}

public enum OpenClawDiagnosticTTSCancellationOrigin: String, Codable, Equatable, Sendable {
    case durableResponseOwner = "durable_response_owner"
    case lifecycleOrManagerStop = "lifecycle_or_manager_stop"
    case providerReplacement = "provider_replacement"
    case pttAdmission = "ptt_admission"
    case speechRecognitionBargeIn = "speech_recognition_barge_in"
    case unknown
    case userOrb = "user_orb"
}

public enum OpenClawDiagnosticOutboxOutcome: String, Codable, Equatable, Sendable {
    case notDispatched = "not_dispatched"
    case dispatchRejected = "dispatch_rejected"
    case accepted
    case ambiguous
    case canonicalHistoryConfirmed = "canonical_history_confirmed"
    case expired
    case cancelled
    case blockedRouteChanged = "blocked_route_changed"
}

public enum OpenClawDiagnosticOutboxDeliveryGate: String, Codable, Equatable, Sendable {
    case offline
    case unsupportedClient = "unsupported_client"
    case gatewayIdentityUnavailable = "gateway_identity_unavailable"
    case gatewayMismatch = "gateway_mismatch"
    case capabilityUnavailable = "capability_unavailable"
    case operatorRoleMissing = "operator_role_missing"
    case operatorSessionUnavailable = "operator_session_unavailable"
    case operatorScopesUnavailable = "operator_scopes_unavailable"
    case routingContractUnavailable = "routing_contract_unavailable"
}

public enum OpenClawDiagnosticOutboxFlushTrigger: String, Codable, Equatable, Sendable {
    case bootstrapComplete = "bootstrap_complete"
    case canonicalConfirmationTimer = "canonical_confirmation_timer"
    case chatEvent = "chat_event"
    case coalesced
    case enqueue
    case explicit
    case foreground
    case health
    case lifecycleRecovery = "lifecycle_recovery"
    case load
    case manualRetry = "manual_retry"
    case refresh
    case safeCancel = "safe_cancel"
    case sequenceGap = "sequence_gap"
    case sessionCreate = "session_create"
    case sessionMessage = "session_message"
    case sessionSwitch = "session_switch"
    case subscriberRestore = "subscriber_restore"
    case talkDelivery = "talk_delivery"
    case tick
    case unknown
}

public enum OpenClawDiagnosticDeliveryTarget: String, Codable, Equatable, Sendable {
    case operatorChat = "operator_chat"
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
    public let rpcMethod: String?
    public let admittedAt: String?
    public let gatewayErrorCode: String?
    public let offsetPresent: Bool?
    public let offsetType: OpenClawDiagnosticRPCOffsetType?
    public let offsetValue: Int?
    public let limitPresent: Bool?
    public let limitValue: Int?
    public let maxCharsPresent: Bool?
    public let maxCharsValue: Int?
    public let encodedPropertyNames: [OpenClawDiagnosticRPCEncodedPropertyName]?
    public let gatewayValidationPath: OpenClawDiagnosticGatewayValidationPath?
    public let gatewayErrorMessageClass: OpenClawDiagnosticGatewayErrorMessageClass?
    public let gatewayValidatorIdentity: String?
    public let protocolSchemaVersion: String?
    public let requestEnvelopeVersion: Int?
    public let elapsedMilliseconds: Int?
    public let eventCount: Int?
    public let messageCount: Int?
    public let sessionGeneration: UInt64?
    public let diagnosticAttemptID: String?
    public let registrationAttemptID: String?
    public let sequence: Int?
    public let stream: String?
    public let provider: String?
    public let providerStage: String?
    public let codec: String?
    public let playbackPath: String?
    public let resultClass: String?
    public let requestedOutputFormat: String?
    public let httpStatus: Int?
    public let contentType: String?
    public let contentEncoding: String?
    public let declaredByteCount: Int?
    public let receivedByteCount: Int?
    public let byteCountParity: OpenClawDiagnosticAudioByteParity?
    public let audioMagicType: OpenClawDiagnosticAudioMagicType?
    public let callbackPlaybackGeneration: UInt64?
    public let activePlaybackGeneration: UInt64?
    public let audioSessionOwnerGeneration: UInt64?
    public let audioRouteChangeReason: OpenClawDiagnosticAudioRouteChangeReason?
    public let previousAudioOutputRouteClasses: [OpenClawDiagnosticAudioOutputRouteClass]?
    public let currentAudioOutputRouteClasses: [OpenClawDiagnosticAudioOutputRouteClass]?
    public let audioInterruptionType: OpenClawDiagnosticAudioInterruptionType?
    public let audioInterruptionReason: OpenClawDiagnosticAudioInterruptionReason?
    public let audioInterruptionOptions: [OpenClawDiagnosticAudioInterruptionOption]?
    public let ttsCancellationOrigin: OpenClawDiagnosticTTSCancellationOrigin?
    public let deviceIdentityHash: String?
    public let configuredGatewayIdentityHash: String?
    public let observedGatewayIdentityHash: String?
    public let configuredGatewayIdentitySource: OpenClawDiagnosticGatewayIdentitySource?
    public let observedGatewayIdentitySource: OpenClawDiagnosticGatewayIdentitySource?
    public let gatewayIdentityComparison: OpenClawDiagnosticGatewayIdentityComparison?
    public let apnsTransport: OpenClawDiagnosticAPNsTransport?
    public let outboxOutcome: OpenClawDiagnosticOutboxOutcome?
    public let outboxCommandHash: String?
    public let outboxDeliveryGate: OpenClawDiagnosticOutboxDeliveryGate?
    public let outboxFlushTrigger: OpenClawDiagnosticOutboxFlushTrigger?
    public let outboxQueuedCount: Int?
    public let outboxConfirmingCount: Int?
    public let outboxBlockedCount: Int?
    public let outboxHasVerifiedRouteSnapshot: Bool?
    public let transportHealthOK: Bool?
    public let deliveryTarget: OpenClawDiagnosticDeliveryTarget?
    public let deliveryGatewayHash: String?
    public let routingContractHash: String?
    public let ackRunHash: String?
    public let topic: String?
    public let environment: String?
    public let byteCount: Int?
    public let sampleRate: Int?
    public let durationMilliseconds: Int?
    public let networkInterfaces: [String]
    public let priorBuildNumber: String?
    public let priorSourceSHA: String?
    public let priorMainExecutableUUID: String?
    public let currentBuildNumber: String?
    public let currentSourceSHA: String?
    public let currentMainExecutableUUID: String?

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
        rpcMethod: String? = nil,
        admittedAt: Date? = nil,
        gatewayErrorCode: String? = nil,
        offsetPresent: Bool? = nil,
        offsetType: OpenClawDiagnosticRPCOffsetType? = nil,
        offsetValue: Int? = nil,
        limitPresent: Bool? = nil,
        limitValue: Int? = nil,
        maxCharsPresent: Bool? = nil,
        maxCharsValue: Int? = nil,
        encodedPropertyNames: [OpenClawDiagnosticRPCEncodedPropertyName]? = nil,
        gatewayValidationPath: OpenClawDiagnosticGatewayValidationPath? = nil,
        gatewayErrorMessageClass: OpenClawDiagnosticGatewayErrorMessageClass? = nil,
        gatewayValidatorIdentity: String? = nil,
        protocolSchemaVersion: String? = nil,
        requestEnvelopeVersion: Int? = nil,
        elapsedMilliseconds: Int? = nil,
        eventCount: Int? = nil,
        messageCount: Int? = nil,
        sessionGeneration: UInt64? = nil,
        diagnosticAttemptID: String? = nil,
        registrationAttemptID: String? = nil,
        sequence: Int? = nil,
        stream: String? = nil,
        provider: String? = nil,
        providerStage: String? = nil,
        codec: String? = nil,
        playbackPath: String? = nil,
        resultClass: String? = nil,
        requestedOutputFormat: String? = nil,
        httpStatus: Int? = nil,
        contentType: String? = nil,
        contentEncoding: String? = nil,
        declaredByteCount: Int? = nil,
        receivedByteCount: Int? = nil,
        byteCountParity: OpenClawDiagnosticAudioByteParity? = nil,
        audioMagicType: OpenClawDiagnosticAudioMagicType? = nil,
        callbackPlaybackGeneration: UInt64? = nil,
        activePlaybackGeneration: UInt64? = nil,
        audioSessionOwnerGeneration: UInt64? = nil,
        audioRouteChangeReason: OpenClawDiagnosticAudioRouteChangeReason? = nil,
        previousAudioOutputRouteClasses: [OpenClawDiagnosticAudioOutputRouteClass]? = nil,
        currentAudioOutputRouteClasses: [OpenClawDiagnosticAudioOutputRouteClass]? = nil,
        audioInterruptionType: OpenClawDiagnosticAudioInterruptionType? = nil,
        audioInterruptionReason: OpenClawDiagnosticAudioInterruptionReason? = nil,
        audioInterruptionOptions: [OpenClawDiagnosticAudioInterruptionOption]? = nil,
        ttsCancellationOrigin: OpenClawDiagnosticTTSCancellationOrigin? = nil,
        deviceIdentityIdentifier: String? = nil,
        configuredGatewayIdentityIdentifier: String? = nil,
        observedGatewayIdentityIdentifier: String? = nil,
        configuredGatewayIdentitySource: OpenClawDiagnosticGatewayIdentitySource? = nil,
        observedGatewayIdentitySource: OpenClawDiagnosticGatewayIdentitySource? = nil,
        gatewayIdentityComparison: OpenClawDiagnosticGatewayIdentityComparison? = nil,
        apnsTransport: OpenClawDiagnosticAPNsTransport? = nil,
        outboxOutcome: OpenClawDiagnosticOutboxOutcome? = nil,
        outboxCommandIdentifier: String? = nil,
        outboxDeliveryGate: OpenClawDiagnosticOutboxDeliveryGate? = nil,
        outboxFlushTrigger: OpenClawDiagnosticOutboxFlushTrigger? = nil,
        outboxQueuedCount: Int? = nil,
        outboxConfirmingCount: Int? = nil,
        outboxBlockedCount: Int? = nil,
        outboxHasVerifiedRouteSnapshot: Bool? = nil,
        transportHealthOK: Bool? = nil,
        deliveryTarget: OpenClawDiagnosticDeliveryTarget? = nil,
        deliveryGatewayIdentifier: String? = nil,
        routingContractIdentifier: String? = nil,
        ackRunIdentifier: String? = nil,
        topic: String? = nil,
        environment: String? = nil,
        byteCount: Int? = nil,
        sampleRate: Int? = nil,
        durationMilliseconds: Int? = nil,
        networkInterfaces: [String] = [],
        priorBuildNumber: String? = nil,
        priorSourceSHA: String? = nil,
        priorMainExecutableUUID: String? = nil,
        currentBuildNumber: String? = nil,
        currentSourceSHA: String? = nil,
        currentMainExecutableUUID: String? = nil,
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
        self.rpcMethod = Self.sanitizedToken(rpcMethod, maximumLength: 128)
        self.admittedAt = admittedAt.map(Self.timestamp)
        self.gatewayErrorCode = Self.sanitizedToken(gatewayErrorCode, maximumLength: 64)
        self.offsetPresent = offsetPresent
        self.offsetType = offsetType
        self.offsetValue = Self.boundedRPCInteger(offsetValue)
        self.limitPresent = limitPresent
        self.limitValue = Self.boundedRPCInteger(limitValue)
        self.maxCharsPresent = maxCharsPresent
        self.maxCharsValue = Self.boundedRPCInteger(maxCharsValue)
        let orderedPropertyNames = encodedPropertyNames?.sorted { $0.rawValue < $1.rawValue }
        self.encodedPropertyNames = orderedPropertyNames.map { names in
            Array(Set(names).sorted(by: { $0.rawValue < $1.rawValue }).prefix(5))
        }
        self.gatewayValidationPath = gatewayValidationPath
        self.gatewayErrorMessageClass = gatewayErrorMessageClass
        self.gatewayValidatorIdentity = Self.allowlistedToken(
            gatewayValidatorIdentity,
            allowed: Self.allowedGatewayValidatorIdentities)
        self.protocolSchemaVersion = Self.allowlistedToken(
            protocolSchemaVersion,
            allowed: Self.allowedProtocolSchemaVersions)
        self.requestEnvelopeVersion = requestEnvelopeVersion.flatMap { $0 == 4 ? $0 : nil }
        self.elapsedMilliseconds = elapsedMilliseconds.flatMap { $0 >= 0 ? $0 : nil }
        self.eventCount = eventCount.flatMap { $0 >= 0 ? $0 : nil }
        self.messageCount = messageCount.flatMap { $0 >= 0 ? $0 : nil }
        self.sessionGeneration = sessionGeneration
        self.diagnosticAttemptID = Self.hashedIdentifier(diagnosticAttemptID)
        self.registrationAttemptID = Self.hashedIdentifier(registrationAttemptID)
        self.sequence = sequence.flatMap { $0 >= 0 ? $0 : nil }
        self.stream = Self.sanitizedToken(stream, maximumLength: 64)
        self.provider = Self.allowlistedToken(provider, allowed: Self.allowedProviders)
        self.providerStage = Self.allowlistedToken(providerStage, allowed: Self.allowedProviderStages)
        self.codec = Self.allowlistedToken(codec, allowed: Self.allowedCodecs)
        self.playbackPath = Self.allowlistedToken(playbackPath, allowed: Self.allowedPlaybackPaths)
        self.resultClass = Self.allowlistedToken(resultClass, allowed: Self.allowedResultClasses)
        self.requestedOutputFormat = Self.sanitizedOutputFormat(requestedOutputFormat)
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        self.contentType = Self.sanitizedHTTPHeaderValue(contentType, maximumLength: 128)
        self.contentEncoding = Self.sanitizedHTTPHeaderValue(contentEncoding, maximumLength: 64)
        self.declaredByteCount = Self.boundedAudioByteCount(declaredByteCount)
        self.receivedByteCount = Self.boundedAudioByteCount(receivedByteCount)
        self.byteCountParity = byteCountParity
        self.audioMagicType = audioMagicType
        self.callbackPlaybackGeneration = callbackPlaybackGeneration
        self.activePlaybackGeneration = activePlaybackGeneration
        self.audioSessionOwnerGeneration = audioSessionOwnerGeneration
        self.audioRouteChangeReason = audioRouteChangeReason
        self.previousAudioOutputRouteClasses = Self.boundedAudioRouteClasses(
            previousAudioOutputRouteClasses)
        self.currentAudioOutputRouteClasses = Self.boundedAudioRouteClasses(
            currentAudioOutputRouteClasses)
        self.audioInterruptionType = audioInterruptionType
        self.audioInterruptionReason = audioInterruptionReason
        self.audioInterruptionOptions = audioInterruptionOptions.map { options in
            Array(Set(options).sorted { $0.rawValue < $1.rawValue }.prefix(2))
        }
        self.ttsCancellationOrigin = ttsCancellationOrigin
        self.deviceIdentityHash = Self.hashedIdentifier(deviceIdentityIdentifier)
        self.configuredGatewayIdentityHash = Self.hashedIdentifier(
            configuredGatewayIdentityIdentifier)
        self.observedGatewayIdentityHash = Self.hashedIdentifier(
            observedGatewayIdentityIdentifier)
        self.configuredGatewayIdentitySource = configuredGatewayIdentitySource
        self.observedGatewayIdentitySource = observedGatewayIdentitySource
        self.gatewayIdentityComparison = gatewayIdentityComparison
        self.apnsTransport = apnsTransport
        self.outboxOutcome = outboxOutcome
        self.outboxCommandHash = Self.hashedIdentifier(outboxCommandIdentifier)
        self.outboxDeliveryGate = outboxDeliveryGate
        self.outboxFlushTrigger = outboxFlushTrigger
        self.outboxQueuedCount = Self.boundedOutboxCount(outboxQueuedCount)
        self.outboxConfirmingCount = Self.boundedOutboxCount(outboxConfirmingCount)
        self.outboxBlockedCount = Self.boundedOutboxCount(outboxBlockedCount)
        self.outboxHasVerifiedRouteSnapshot = outboxHasVerifiedRouteSnapshot
        self.transportHealthOK = transportHealthOK
        self.deliveryTarget = deliveryTarget
        self.deliveryGatewayHash = Self.hashedIdentifier(deliveryGatewayIdentifier)
        self.routingContractHash = Self.hashedIdentifier(routingContractIdentifier)
        self.ackRunHash = Self.hashedIdentifier(ackRunIdentifier)
        self.topic = Self.allowlistedToken(topic, allowed: Self.allowedTopics)
        self.environment = Self.allowlistedToken(environment, allowed: Self.allowedEnvironments)
        self.byteCount = byteCount.flatMap { $0 >= 0 ? $0 : nil }
        self.sampleRate = sampleRate.flatMap { (1...384_000).contains($0) ? $0 : nil }
        self.durationMilliseconds = durationMilliseconds.flatMap { $0 >= 0 ? $0 : nil }
        let sanitizedInterfaces = Array(Set(networkInterfaces.compactMap {
            Self.sanitizedToken($0, maximumLength: 32)
        })).sorted()
        self.networkInterfaces = Array(sanitizedInterfaces.prefix(8))
        self.priorBuildNumber = Self.validBuildNumber(priorBuildNumber)
        self.priorSourceSHA = Self.validSourceSHA(priorSourceSHA)
        self.priorMainExecutableUUID = Self.canonicalUUID(priorMainExecutableUUID)
        self.currentBuildNumber = Self.validBuildNumber(currentBuildNumber)
        self.currentSourceSHA = Self.validSourceSHA(currentSourceSHA)
        self.currentMainExecutableUUID = Self.canonicalUUID(currentMainExecutableUUID)
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
        case rpcMethod = "rpc_method"
        case admittedAt = "admitted_at"
        case gatewayErrorCode = "gateway_error_code"
        case offsetPresent = "offset_present"
        case offsetType = "offset_type"
        case offsetValue = "offset_value"
        case limitPresent = "limit_present"
        case limitValue = "limit_value"
        case maxCharsPresent = "max_chars_present"
        case maxCharsValue = "max_chars_value"
        case encodedPropertyNames = "encoded_property_names"
        case gatewayValidationPath = "gateway_validation_path"
        case gatewayErrorMessageClass = "gateway_error_message_class"
        case gatewayValidatorIdentity = "gateway_validator_identity"
        case protocolSchemaVersion = "protocol_schema_version"
        case requestEnvelopeVersion = "request_envelope_version"
        case elapsedMilliseconds = "elapsed_milliseconds"
        case eventCount = "event_count"
        case messageCount = "message_count"
        case sessionGeneration = "session_generation"
        case diagnosticAttemptID = "diagnostic_attempt_id"
        case registrationAttemptID = "registration_attempt_id"
        case sequence
        case stream
        case provider
        case providerStage = "provider_stage"
        case codec
        case playbackPath = "playback_path"
        case resultClass = "result_class"
        case requestedOutputFormat = "requested_output_format"
        case httpStatus = "http_status"
        case contentType = "content_type"
        case contentEncoding = "content_encoding"
        case declaredByteCount = "declared_byte_count"
        case receivedByteCount = "received_byte_count"
        case byteCountParity = "byte_count_parity"
        case audioMagicType = "audio_magic_type"
        case callbackPlaybackGeneration = "callback_playback_generation"
        case activePlaybackGeneration = "active_playback_generation"
        case audioSessionOwnerGeneration = "audio_session_owner_generation"
        case audioRouteChangeReason = "audio_route_change_reason"
        case previousAudioOutputRouteClasses = "previous_audio_output_route_classes"
        case currentAudioOutputRouteClasses = "current_audio_output_route_classes"
        case audioInterruptionType = "audio_interruption_type"
        case audioInterruptionReason = "audio_interruption_reason"
        case audioInterruptionOptions = "audio_interruption_options"
        case ttsCancellationOrigin = "tts_cancellation_origin"
        case deviceIdentityHash = "device_identity_hash"
        case configuredGatewayIdentityHash = "configured_gateway_identity_hash"
        case observedGatewayIdentityHash = "observed_gateway_identity_hash"
        case configuredGatewayIdentitySource = "configured_gateway_identity_source"
        case observedGatewayIdentitySource = "observed_gateway_identity_source"
        case gatewayIdentityComparison = "gateway_identity_comparison"
        case apnsTransport = "apns_transport"
        case outboxOutcome = "outbox_outcome"
        case outboxCommandHash = "outbox_command_hash"
        case outboxDeliveryGate = "outbox_delivery_gate"
        case outboxFlushTrigger = "outbox_flush_trigger"
        case outboxQueuedCount = "outbox_queued_count"
        case outboxConfirmingCount = "outbox_confirming_count"
        case outboxBlockedCount = "outbox_blocked_count"
        case outboxHasVerifiedRouteSnapshot = "outbox_has_verified_route_snapshot"
        case transportHealthOK = "transport_health_ok"
        case deliveryTarget = "delivery_target"
        case deliveryGatewayHash = "delivery_gateway_hash"
        case routingContractHash = "routing_contract_hash"
        case ackRunHash = "ack_run_hash"
        case topic
        case environment
        case byteCount = "byte_count"
        case sampleRate = "sample_rate"
        case durationMilliseconds = "duration_milliseconds"
        case networkInterfaces = "network_interfaces"
        case priorBuildNumber = "prior_build_number"
        case priorSourceSHA = "prior_source_sha"
        case priorMainExecutableUUID = "prior_main_executable_uuid"
        case currentBuildNumber = "current_build_number"
        case currentSourceSHA = "current_source_sha"
        case currentMainExecutableUUID = "current_main_executable_uuid"
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

    private static func boundedRPCInteger(_ value: Int?) -> Int? {
        value.flatMap { (-1_000_000...1_000_000).contains($0) ? $0 : nil }
    }

    private static func boundedOutboxCount(_ value: Int?) -> Int? {
        value.flatMap { $0 >= 0 ? min($0, 50) : nil }
    }

    private static func boundedAudioByteCount(_ value: Int?) -> Int? {
        value.flatMap { (0...100_000_000).contains($0) ? $0 : nil }
    }

    private static func boundedAudioRouteClasses(
        _ value: [OpenClawDiagnosticAudioOutputRouteClass]?
    ) -> [OpenClawDiagnosticAudioOutputRouteClass]? {
        value.map { classes in
            Array(Set(classes).sorted { $0.rawValue < $1.rawValue }.prefix(8))
        }
    }

    private static func sanitizedOutputFormat(_ value: String?) -> String? {
        guard let value = Self.sanitizedToken(value, maximumLength: 48) else { return nil }
        let allowed: Set<String> = [
            "unspecified",
            "pcm_8000", "pcm_16000", "pcm_22050", "pcm_24000", "pcm_44100", "pcm_48000",
            "mp3_22050_32",
            "mp3_44100_32", "mp3_44100_64", "mp3_44100_96", "mp3_44100_128", "mp3_44100_192",
        ]
        return allowed.contains(value) ? value : nil
    }

    private static func sanitizedHTTPHeaderValue(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= maximumLength else { return nil }
        let permitted = normalized.utf8.allSatisfy { byte in
            switch byte {
            case 32, 43...59, 61, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
        return permitted ? normalized : nil
    }

    private static func validBuildNumber(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 32
        else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              components.allSatisfy({ component in
                  !component.isEmpty && component.utf8.allSatisfy { (48...57).contains($0) }
              })
        else { return nil }
        return value
    }

    private static func validSourceSHA(_ value: String?) -> String? {
        guard let value,
              value.utf8.count == 40,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else { return nil }
        return value
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              value == value.lowercased(),
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value
        else { return nil }
        return value
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
    private static let allowedGatewayValidatorIdentities: Set<String> = [
        "chat-history-0790d9f593ad",
    ]
    private static let allowedProtocolSchemaVersions: Set<String> = [
        "gateway-protocol-v4",
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
        "node_route_admitted",
        "operator_route_admitted",
        "os_token_received",
        "output_route_observed",
        "payload_or_relay_preparation",
        "pcm_to_mp3",
        "playback_cancelled",
        "playback_completed",
        "playback_failed",
        "playback_submission_accepted",
        "playback_submission_started",
        "player_instance_created",
        "player_instance_deallocated",
        "provider_request_started",
        "provider_response_received",
        "provider_resolved",
        "provider_to_system",
        "provider_unavailable_to_system",
        "relay_identity_route",
        "relay_identity_request",
        "relay_registration_response",
        "registration_state_changed",
        "gateway_configuration_changed",
        "state_transition",
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
        "in_flight_completed",
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
        "accepted",
        "ambiguous",
        "blocked_route_changed",
        "cancelled",
        "canonical_confirmed",
        "canonical_not_found_bounded",
        "coalesced_request",
        "codec_mismatch",
        "codec_validated",
        "connection_owner_unavailable",
        "configuration_generation_changed",
        "current_callback",
        "direct",
        "dispatch_rejected",
        "encoding_failed",
        "empty_payload",
        "failed",
        "fifo_blocked",
        "frame_alignment_invalid",
        "finished",
        "gateway_rejected",
        "http_4xx",
        "http_5xx",
        "http_error",
        "incomplete",
        "interrupted",
        "local_direct_registration_match",
        "local_or_relay_preparation_failed",
        "marker_path_unavailable",
        "marker_persisted",
        "marker_replaced",
        "marker_write_failed",
        "new_os_token_received",
        "node_connection_unavailable",
        "node_event_transport",
        "node_gateway_identity_mismatch",
        "node_route_stale",
        "node_route_unavailable",
        "not_attempted",
        "not_dispatched",
        "operator_connection_unavailable",
        "operator_gateway_identity_mismatch",
        "operator_route_stale",
        "operator_route_unavailable",
        "os_token_unavailable",
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
        "restored",
        "relay",
        "relay_identity_unavailable",
        "relay_http_rejected",
        "relay_http_failed",
        "requested",
        "registration_generation_already_completed",
        "registration_intent_unavailable",
        "route_bound",
        "queue_empty",
        "route_or_configuration_changed_after_payload",
        "route_or_configuration_changed_after_transport_write",
        "route_or_configuration_changed_before_payload",
        "semantic_audio_failed",
        "success",
        "system_error",
        "stable_gateway_identity_unavailable",
        "stale_callback",
        "bundle_topic_unavailable",
        "timeout",
        "transport_error",
        "transport_or_route_unavailable",
        "transport_write_accepted_unacknowledged",
        "unattributed_callback",
        "unattributed_system_error",
        "zero_audio",
    ]
    private static let allowedOutboxStates: Set<String> = [
        "chat_send_acknowledged",
        "chat_send_ambiguous",
        "chat_send_not_dispatched",
        "chat_send_pre_dispatch_rejected",
        "chat_send_rejected",
        "chat_send_dispatch_invoked",
        "chat_send_route_blocked",
        "outbox_canonical_check_completed",
        "outbox_canonical_check_failed",
        "outbox_canonical_check_started",
        "outbox_canonical_receipt_persisted",
        "outbox_canonical_receipt_stale",
        "outbox_canonical_user_receipt",
        "outbox_dispatch_completed",
        "outbox_dispatch_outcome_persisted",
        "outbox_dispatch_outcome_stale",
        "outbox_dispatch_started",
        "outbox_enqueue_failed",
        "outbox_enqueue_persisted",
        "outbox_enqueue_started",
        "outbox_fifo_head_blocked",
        "outbox_flush_completed",
        "outbox_flush_failed",
        "outbox_flush_requested",
        "outbox_flush_started",
        "outbox_health_observed",
        "outbox_local_echo_projected",
        "outbox_pre_dispatch_rejected",
        "outbox_reply_receipt",
        "outbox_restore_applied",
        "outbox_route_gate_evaluated",
        "outbox_row_claim_unavailable",
        "outbox_row_claimed",
        "outbox_run_receipt",
        "outbox_snapshot_loaded",
        "outbox_status_applied",
    ]
    private static let outboxFlushStates: Set<String> = [
        "outbox_flush_completed",
        "outbox_flush_failed",
        "outbox_flush_requested",
        "outbox_flush_started",
    ]
    private static let outboxStatusStates: Set<String> = [
        "outbox_flush_completed",
        "outbox_health_observed",
        "outbox_restore_applied",
        "outbox_snapshot_loaded",
        "outbox_status_applied",
    ]
    private static let outboxRowStates: Set<String> = [
        "chat_send_acknowledged",
        "chat_send_ambiguous",
        "chat_send_not_dispatched",
        "chat_send_pre_dispatch_rejected",
        "chat_send_rejected",
        "chat_send_dispatch_invoked",
        "chat_send_route_blocked",
        "outbox_canonical_check_completed",
        "outbox_canonical_check_failed",
        "outbox_canonical_check_started",
        "outbox_canonical_receipt_persisted",
        "outbox_canonical_receipt_stale",
        "outbox_canonical_user_receipt",
        "outbox_dispatch_completed",
        "outbox_dispatch_outcome_persisted",
        "outbox_dispatch_outcome_stale",
        "outbox_dispatch_started",
        "outbox_enqueue_failed",
        "outbox_enqueue_persisted",
        "outbox_enqueue_started",
        "outbox_fifo_head_blocked",
        "outbox_local_echo_projected",
        "outbox_pre_dispatch_rejected",
        "outbox_reply_receipt",
        "outbox_row_claim_unavailable",
        "outbox_row_claimed",
        "outbox_run_receipt",
    ]
    private static let outboxRouteCustodyStates: Set<String> = [
        "chat_send_acknowledged",
        "chat_send_ambiguous",
        "chat_send_not_dispatched",
        "chat_send_dispatch_invoked",
        "chat_send_rejected",
        "chat_send_route_blocked",
        "outbox_canonical_check_completed",
        "outbox_canonical_check_failed",
        "outbox_canonical_check_started",
        "outbox_canonical_receipt_persisted",
        "outbox_canonical_receipt_stale",
        "outbox_dispatch_completed",
        "outbox_dispatch_outcome_persisted",
        "outbox_dispatch_outcome_stale",
        "outbox_dispatch_started",
        "outbox_fifo_head_blocked",
        "outbox_pre_dispatch_rejected",
        "outbox_row_claim_unavailable",
        "outbox_row_claimed",
    ]
    private static let outboxTransportStates: Set<String> = [
        "chat_send_acknowledged",
        "chat_send_ambiguous",
        "chat_send_not_dispatched",
        "chat_send_dispatch_invoked",
        "chat_send_rejected",
        "chat_send_route_blocked",
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
              self.rpcMethod == Self.sanitizedToken(self.rpcMethod, maximumLength: 128),
              self.admittedAt.map(Self.isValidTimestamp) ?? true,
              self.gatewayErrorCode == Self.sanitizedToken(
                  self.gatewayErrorCode, maximumLength: 64),
              self.offsetValue == Self.boundedRPCInteger(self.offsetValue),
              self.limitValue == Self.boundedRPCInteger(self.limitValue),
              self.maxCharsValue == Self.boundedRPCInteger(self.maxCharsValue),
              self.encodedPropertyNames.map({ names in
                  names.count <= 5 && names == Array(Set(names).sorted {
                      $0.rawValue < $1.rawValue
                  })
              }) ?? true,
              self.gatewayValidatorIdentity == Self.allowlistedToken(
                  self.gatewayValidatorIdentity,
                  allowed: Self.allowedGatewayValidatorIdentities),
              self.protocolSchemaVersion == Self.allowlistedToken(
                  self.protocolSchemaVersion,
                  allowed: Self.allowedProtocolSchemaVersions),
              self.requestEnvelopeVersion.map({ $0 == 4 }) ?? true,
              self.elapsedMilliseconds.map({ $0 >= 0 }) ?? true,
              self.eventCount.map({ $0 >= 0 }) ?? true,
              self.messageCount.map({ $0 >= 0 }) ?? true,
              self.diagnosticAttemptID.map(Self.isLowercaseHexDigest) ?? true,
              self.registrationAttemptID.map(Self.isLowercaseHexDigest) ?? true,
              self.deviceIdentityHash.map(Self.isLowercaseHexDigest) ?? true,
              self.configuredGatewayIdentityHash.map(Self.isLowercaseHexDigest) ?? true,
              self.observedGatewayIdentityHash.map(Self.isLowercaseHexDigest) ?? true,
              self.outboxCommandHash.map(Self.isLowercaseHexDigest) ?? true,
              self.outboxQueuedCount == Self.boundedOutboxCount(self.outboxQueuedCount),
              self.outboxConfirmingCount == Self.boundedOutboxCount(self.outboxConfirmingCount),
              self.outboxBlockedCount == Self.boundedOutboxCount(self.outboxBlockedCount),
              self.deliveryGatewayHash.map(Self.isLowercaseHexDigest) ?? true,
              self.routingContractHash.map(Self.isLowercaseHexDigest) ?? true,
              self.ackRunHash.map(Self.isLowercaseHexDigest) ?? true,
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
              self.requestedOutputFormat == Self.sanitizedOutputFormat(self.requestedOutputFormat),
              self.httpStatus.map({ (100...599).contains($0) }) ?? true,
              self.contentType == Self.sanitizedHTTPHeaderValue(
                  self.contentType, maximumLength: 128),
              self.contentEncoding == Self.sanitizedHTTPHeaderValue(
                  self.contentEncoding, maximumLength: 64),
              self.declaredByteCount == Self.boundedAudioByteCount(self.declaredByteCount),
              self.receivedByteCount == Self.boundedAudioByteCount(self.receivedByteCount),
              self.previousAudioOutputRouteClasses == Self.boundedAudioRouteClasses(
                  self.previousAudioOutputRouteClasses),
              self.currentAudioOutputRouteClasses == Self.boundedAudioRouteClasses(
                  self.currentAudioOutputRouteClasses),
              self.audioInterruptionOptions.map({ options in
                  options.count <= 2 && options == Array(Set(options).sorted {
                      $0.rawValue < $1.rawValue
                  })
              }) ?? true,
              self.topic == Self.allowlistedToken(self.topic, allowed: Self.allowedTopics),
              self.environment == Self.allowlistedToken(
                  self.environment, allowed: Self.allowedEnvironments),
              self.sequence.map({ $0 >= 0 }) ?? true,
              self.networkInterfaces.count <= 8,
              self.networkInterfaces == Array(Set(self.networkInterfaces)).sorted(),
              self.networkInterfaces.allSatisfy({
                  $0 == Self.sanitizedToken($0, maximumLength: 32)
              }),
              self.sessionHash.map(Self.isLowercaseHexDigest) ?? true,
              self.priorBuildNumber == Self.validBuildNumber(self.priorBuildNumber),
              self.priorSourceSHA == Self.validSourceSHA(self.priorSourceSHA),
              self.priorMainExecutableUUID == Self.canonicalUUID(self.priorMainExecutableUUID),
              self.currentBuildNumber == Self.validBuildNumber(self.currentBuildNumber),
              self.currentSourceSHA == Self.validSourceSHA(self.currentSourceSHA),
              self.currentMainExecutableUUID == Self.canonicalUUID(self.currentMainExecutableUUID)
        else {
            return false
        }
        if self.schema == "argus.openclaw-ios.diagnostic-event.v1", self.kind == .apns {
            return false
        }
        if self.schema == Self.schemaName,
           (self.processInstanceID == nil || self.launchInstanceID == nil)
        {
            return false
        }
        if self.schema == Self.schemaName,
           [Kind.route, .socket].contains(self.kind),
           self.connectionRole == nil
        {
            return false
        }
        let hasGatewayIdentityEvidence = self.configuredGatewayIdentityHash != nil ||
            self.observedGatewayIdentityHash != nil ||
            self.configuredGatewayIdentitySource != nil ||
            self.observedGatewayIdentitySource != nil ||
            self.gatewayIdentityComparison != nil
        if self.apnsTransport != nil,
           (self.schema != Self.schemaName || self.kind != .apns)
        {
            return false
        }
        let hasAudioResponseMetadata = self.requestedOutputFormat != nil || self.httpStatus != nil ||
            self.contentType != nil || self.contentEncoding != nil || self.declaredByteCount != nil ||
            self.receivedByteCount != nil || self.byteCountParity != nil || self.audioMagicType != nil
        if hasAudioResponseMetadata, (self.schema != Self.schemaName || self.kind != .tts) {
            return false
        }
        if hasAudioResponseMetadata {
            guard self.provider == "elevenlabs",
                  ["provider_response_received", "audio_payload_validated"].contains(self.state),
                  self.providerStage == self.state,
                  self.requestedOutputFormat != nil,
                  let httpStatus = self.httpStatus,
                  self.contentType != nil,
                  self.contentEncoding != nil,
                  let receivedByteCount = self.receivedByteCount,
                  let byteCountParity = self.byteCountParity,
                  let audioMagicType = self.audioMagicType,
                  let resultClass = self.resultClass,
                  [
                      "codec_validated", "codec_mismatch", "frame_alignment_invalid",
                      "empty_payload", "http_error",
                  ].contains(resultClass),
                  (receivedByteCount.isMultiple(of: 2) ? .even : .odd) == byteCountParity,
                  (receivedByteCount == 0) == (audioMagicType == .empty),
                  (httpStatus >= 400) == (resultClass == "http_error")
            else {
                return false
            }
            if self.state == "audio_payload_validated", resultClass != "codec_validated" {
                return false
            }
            if resultClass == "codec_validated" {
                if self.requestedOutputFormat?.hasPrefix("pcm_") == true {
                    guard audioMagicType == .rawNoKnownHeader,
                          byteCountParity == .even
                    else {
                        return false
                    }
                } else if self.requestedOutputFormat == "unspecified" ||
                    self.requestedOutputFormat?.hasPrefix("mp3_") == true
                {
                    guard [.id3MPEG, .mpegFrameSync].contains(audioMagicType) else {
                        return false
                    }
                } else {
                    return false
                }
            }
            if (resultClass == "empty_payload") != (receivedByteCount == 0) {
                return false
            }
            if resultClass == "frame_alignment_invalid",
               (self.requestedOutputFormat?.hasPrefix("pcm_") != true ||
                   byteCountParity != .odd || audioMagicType != .rawNoKnownHeader)
            {
                return false
            }
        }
        let hasAudioSessionMetadata = self.callbackPlaybackGeneration != nil ||
            self.activePlaybackGeneration != nil || self.audioSessionOwnerGeneration != nil ||
            self.audioRouteChangeReason != nil || self.previousAudioOutputRouteClasses != nil ||
            self.currentAudioOutputRouteClasses != nil || self.audioInterruptionType != nil ||
            self.audioInterruptionReason != nil || self.audioInterruptionOptions != nil
        if hasAudioSessionMetadata,
           (self.schema != Self.schemaName || ![Kind.route, .tts].contains(self.kind))
        {
            return false
        }
        let callbackStates: Set<String> = [
            "tts_route_changed",
            "tts_audio_session_interruption_began",
            "tts_audio_session_interruption_ended",
            "tts_media_services_lost",
            "tts_media_services_reset",
        ]
        if callbackStates.contains(self.state) {
            let expectedResult: String = if let callback = self.callbackPlaybackGeneration {
                callback == self.activePlaybackGeneration ? "current_callback" : "stale_callback"
            } else {
                "unattributed_callback"
            }
            guard hasAudioSessionMetadata,
                  self.resultClass == expectedResult,
                  self.currentAudioOutputRouteClasses != nil
            else { return false }
        }
        if self.state == "tts_route_changed" {
            guard self.kind == .route,
                  self.audioRouteChangeReason != nil,
                  self.previousAudioOutputRouteClasses != nil,
                  self.audioInterruptionType == nil,
                  self.audioInterruptionReason == nil,
                  self.audioInterruptionOptions == nil
            else { return false }
        }
        if [
            "tts_audio_session_interruption_began",
            "tts_audio_session_interruption_ended",
        ].contains(self.state) {
            let expectedType: OpenClawDiagnosticAudioInterruptionType =
                self.state.hasSuffix("_began") ? .began : .ended
            guard self.kind == .tts,
                  self.audioInterruptionType == expectedType,
                  self.audioInterruptionReason != nil,
                  self.audioInterruptionOptions != nil,
                  self.audioRouteChangeReason == nil,
                  self.previousAudioOutputRouteClasses == nil
            else { return false }
        }
        if ["tts_media_services_lost", "tts_media_services_reset"].contains(self.state) {
            guard self.kind == .tts,
                  self.audioRouteChangeReason == nil,
                  self.previousAudioOutputRouteClasses == nil,
                  self.audioInterruptionType == nil,
                  self.audioInterruptionReason == nil,
                  self.audioInterruptionOptions == nil
            else { return false }
        }
        let restoreStates: Set<String> = [
            "tts_audio_session_restore_requested",
            "tts_audio_session_restore_completed",
            "tts_audio_session_restore_failed",
        ]
        if restoreStates.contains(self.state) {
            let expectedResult = switch self.state {
            case "tts_audio_session_restore_requested": "requested"
            case "tts_audio_session_restore_completed": "restored"
            default: "failed"
            }
            guard self.kind == .tts,
                  let owner = self.audioSessionOwnerGeneration,
                  self.playbackGeneration == owner,
                  self.resultClass == expectedResult,
                  self.audioRouteChangeReason == nil,
                  self.previousAudioOutputRouteClasses == nil,
                  self.audioInterruptionType == nil,
                  self.audioInterruptionReason == nil,
                  self.audioInterruptionOptions == nil
            else { return false }
        }
        if (self.state == "tts_stop_requested") != (self.ttsCancellationOrigin != nil) {
            return false
        }
        if self.state == "tts_stop_requested",
           (self.kind != .tts || self.resultClass != "requested")
        {
            return false
        }
        let hasOutboxMetadata = self.outboxOutcome != nil || self.outboxCommandHash != nil ||
            self.outboxDeliveryGate != nil ||
            self.outboxFlushTrigger != nil || self.outboxQueuedCount != nil ||
            self.outboxConfirmingCount != nil || self.outboxBlockedCount != nil ||
            self.outboxHasVerifiedRouteSnapshot != nil || self.transportHealthOK != nil ||
            self.deliveryTarget != nil || self.deliveryGatewayHash != nil ||
            self.routingContractHash != nil || self.ackRunHash != nil
        if hasOutboxMetadata,
           (self.schema != Self.schemaName || self.kind != .chat ||
               self.deliveryTarget != .operatorChat ||
               !Self.allowedOutboxStates.contains(self.state))
        {
            return false
        }
        if Self.allowedOutboxStates.contains(self.state) != hasOutboxMetadata {
            return false
        }
        let hasAnyOutboxCount = self.outboxQueuedCount != nil ||
            self.outboxConfirmingCount != nil || self.outboxBlockedCount != nil
        let hasCompleteOutboxCounts = self.outboxQueuedCount != nil &&
            self.outboxConfirmingCount != nil && self.outboxBlockedCount != nil
        if hasAnyOutboxCount != hasCompleteOutboxCounts {
            return false
        }
        if Self.outboxStatusStates.contains(self.state), !hasCompleteOutboxCounts {
            return false
        }
        if self.state == "outbox_health_observed", self.transportHealthOK == nil {
            return false
        }
        if self.ackRunHash != nil,
           (self.ackRunHash != self.runID || self.ackRunHash != self.outboxCommandHash)
        {
            return false
        }
        if Self.outboxFlushStates.contains(self.state), self.outboxFlushTrigger == nil {
            return false
        }
        if Self.outboxRowStates.contains(self.state),
           (self.outboxCommandHash == nil || self.sessionHash == nil ||
               self.diagnosticAttemptID != self.outboxCommandHash)
        {
            return false
        }
        if Self.outboxRouteCustodyStates.contains(self.state),
           (self.connectionRole != .operator || self.deliveryGatewayHash == nil ||
               self.routingContractHash == nil)
        {
            return false
        }
        if Self.outboxTransportStates.contains(self.state),
           (self.outboxCommandHash == nil || self.sessionHash == nil || self.routeGeneration == nil ||
               self.socketGeneration == nil || self.deliveryGatewayHash == nil ||
               self.routingContractHash == nil)
        {
            return false
        }
        if self.state == "chat_send_acknowledged",
           (self.outboxOutcome != .accepted || self.ackRunHash == nil)
        {
            return false
        }
        if self.state == "outbox_canonical_receipt_persisted",
           self.outboxOutcome != .canonicalHistoryConfirmed
        {
            return false
        }
        if self.state == "outbox_canonical_user_receipt",
           self.outboxOutcome != .canonicalHistoryConfirmed
        {
            return false
        }
        switch self.state {
        case "chat_send_dispatch_invoked":
            guard self.outboxOutcome == nil, self.runID == nil, self.ackRunHash == nil else {
                return false
            }
        case "chat_send_pre_dispatch_rejected", "chat_send_not_dispatched":
            guard self.outboxOutcome == .notDispatched,
                  self.runID == nil,
                  self.ackRunHash == nil
            else { return false }
        case "chat_send_rejected":
            guard self.outboxOutcome == .dispatchRejected,
                  self.runID == nil,
                  self.ackRunHash == nil
            else { return false }
        case "chat_send_ambiguous":
            guard self.outboxOutcome == .ambiguous,
                  self.runID == nil,
                  self.ackRunHash == nil
            else { return false }
        case "chat_send_route_blocked":
            guard self.outboxOutcome == .blockedRouteChanged,
                  self.runID == nil,
                  self.ackRunHash == nil
            else { return false }
        case "chat_send_acknowledged":
            break
        case "outbox_run_receipt", "outbox_reply_receipt":
            guard self.runID != nil,
                  self.runID == self.outboxCommandHash,
                  self.ackRunHash == nil
            else { return false }
        default:
            if hasOutboxMetadata, self.runID != nil || self.ackRunHash != nil {
                return false
            }
        }
        if hasGatewayIdentityEvidence {
            guard self.schema == Self.schemaName,
                  self.kind == .apns,
                  self.configuredGatewayIdentitySource != nil,
                  self.observedGatewayIdentitySource != nil,
                  let comparison = self.gatewayIdentityComparison,
                  self.apnsTransport != nil
            else {
                return false
            }
            switch comparison {
            case .equal:
                guard let configured = self.configuredGatewayIdentityHash,
                      configured == self.observedGatewayIdentityHash
                else { return false }
            case .configuredMissing:
                guard self.configuredGatewayIdentityHash == nil,
                      self.observedGatewayIdentityHash != nil
                else { return false }
            case .observedMissing:
                guard self.configuredGatewayIdentityHash != nil,
                      self.observedGatewayIdentityHash == nil
                else { return false }
            case .different:
                guard let configured = self.configuredGatewayIdentityHash,
                      let observed = self.observedGatewayIdentityHash,
                      configured != observed
                else { return false }
            }
            switch self.resultClass {
            case "node_gateway_identity_mismatch":
                guard self.state == "gateway_publication_deferred",
                      comparison != .equal,
                      self.observedGatewayIdentitySource == .nodeRouteConnectOptions
                else { return false }
            case "operator_gateway_identity_mismatch":
                guard self.state == "gateway_publication_deferred",
                      comparison != .equal,
                      self.observedGatewayIdentitySource == .operatorRouteConnectOptions
                else { return false }
            default:
                break
            }
            if self.state == "gateway_publication_admitted", comparison != .equal {
                return false
            }
        }
        let hasRPCMetadata = self.rpcMethod != nil || self.admittedAt != nil ||
            self.gatewayErrorCode != nil || self.offsetPresent != nil || self.offsetType != nil ||
            self.offsetValue != nil || self.limitPresent != nil || self.limitValue != nil ||
            self.maxCharsPresent != nil || self.maxCharsValue != nil ||
            self.encodedPropertyNames != nil || self.gatewayValidationPath != nil ||
            self.gatewayErrorMessageClass != nil || self.gatewayValidatorIdentity != nil ||
            self.protocolSchemaVersion != nil || self.requestEnvelopeVersion != nil ||
            self.elapsedMilliseconds != nil
        if hasRPCMetadata {
            guard self.schema == Self.schemaName,
                  self.kind == .socket,
                  self.operationID != nil,
                  self.rpcMethod != nil,
                  self.admittedAt != nil,
                  let offsetPresent = self.offsetPresent,
                  let offsetType = self.offsetType,
                  self.limitPresent != nil,
                  self.maxCharsPresent != nil,
                  self.elapsedMilliseconds != nil,
                  offsetPresent == (offsetType != .absent)
            else {
                return false
            }

            // Build 94/104 v2 records predate the additive validator-custody fields below.
            // Continue accepting that complete legacy core, but fail closed if a record
            // claims any part of the enriched contract without supplying all of it.
            let hasNewRPCCustodyMetadata = self.offsetValue != nil || self.limitValue != nil ||
                self.maxCharsValue != nil || self.encodedPropertyNames != nil ||
                self.gatewayValidationPath != nil || self.gatewayErrorMessageClass != nil ||
                self.gatewayValidatorIdentity != nil || self.protocolSchemaVersion != nil ||
                self.requestEnvelopeVersion != nil
            if hasNewRPCCustodyMetadata {
                guard let encodedPropertyNames = self.encodedPropertyNames,
                      self.protocolSchemaVersion != nil,
                      self.requestEnvelopeVersion == 4,
                  (self.offsetValue == nil || offsetType == .integer),
                  (self.offsetValue == nil || offsetPresent),
                  (self.limitValue == nil || self.limitPresent == true),
                  (self.maxCharsValue == nil || self.maxCharsPresent == true),
                  (self.gatewayValidationPath == nil) == (self.gatewayErrorMessageClass == nil)
                else {
                    return false
                }
                if self.rpcMethod == "chat.history" {
                    guard self.gatewayValidatorIdentity == "chat-history-0790d9f593ad",
                          encodedPropertyNames.contains(.offset) == offsetPresent,
                          encodedPropertyNames.contains(.limit) == (self.limitPresent == true),
                          encodedPropertyNames.contains(.maxChars) == (self.maxCharsPresent == true)
                    else { return false }
                } else if self.gatewayValidatorIdentity != nil || !encodedPropertyNames.isEmpty {
                    return false
                }
                if self.gatewayValidationPath != nil,
                   self.gatewayErrorCode != "INVALID_REQUEST"
                {
                    return false
                }
            }
        }
        let hasBuildTransitionMetadata = self.priorBuildNumber != nil || self.priorSourceSHA != nil ||
            self.priorMainExecutableUUID != nil || self.currentBuildNumber != nil ||
            self.currentSourceSHA != nil || self.currentMainExecutableUUID != nil
        let hasCompletePriorBuildIdentity = self.priorBuildNumber != nil &&
            self.priorSourceSHA != nil && self.priorMainExecutableUUID != nil
        let hasCompleteCurrentBuildIdentity = self.currentBuildNumber != nil &&
            self.currentSourceSHA != nil && self.currentMainExecutableUUID != nil
        let hasAnyPriorBuildIdentity = self.priorBuildNumber != nil || self.priorSourceSHA != nil ||
            self.priorMainExecutableUUID != nil
        let hasAnyCurrentBuildIdentity = self.currentBuildNumber != nil ||
            self.currentSourceSHA != nil || self.currentMainExecutableUUID != nil
        if hasBuildTransitionMetadata,
           (self.schema != Self.schemaName || self.kind != .appLifecycle)
        {
            return false
        }
        if hasAnyPriorBuildIdentity != hasCompletePriorBuildIdentity ||
            hasAnyCurrentBuildIdentity != hasCompleteCurrentBuildIdentity
        {
            return false
        }
        let buildIdentitiesMatch = self.priorBuildNumber == self.currentBuildNumber &&
            self.priorSourceSHA == self.currentSourceSHA &&
            self.priorMainExecutableUUID == self.currentMainExecutableUUID
        if self.state == "previous_run_unclosed_same_build",
           (!hasCompletePriorBuildIdentity || !hasCompleteCurrentBuildIdentity ||
               !buildIdentitiesMatch)
        {
            return false
        }
        if self.state == "previous_run_unclosed_build_transition",
           (!hasCompletePriorBuildIdentity || !hasCompleteCurrentBuildIdentity ||
               buildIdentitiesMatch)
        {
            return false
        }
        if self.state == "previous_run_unclosed_identity_unknown",
           hasCompletePriorBuildIdentity && hasCompleteCurrentBuildIdentity
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
        "rpc_method",
        "admitted_at",
        "gateway_error_code",
        "offset_present",
        "offset_type",
        "offset_value",
        "limit_present",
        "limit_value",
        "max_chars_present",
        "max_chars_value",
        "encoded_property_names",
        "gateway_validation_path",
        "gateway_error_message_class",
        "gateway_validator_identity",
        "protocol_schema_version",
        "request_envelope_version",
        "elapsed_milliseconds",
        "event_count",
        "message_count",
        "session_generation",
        "diagnostic_attempt_id",
        "registration_attempt_id",
        "sequence",
        "stream",
        "provider",
        "provider_stage",
        "codec",
        "playback_path",
        "result_class",
        "requested_output_format",
        "http_status",
        "content_type",
        "content_encoding",
        "declared_byte_count",
        "received_byte_count",
        "byte_count_parity",
        "audio_magic_type",
        "callback_playback_generation",
        "active_playback_generation",
        "audio_session_owner_generation",
        "audio_route_change_reason",
        "previous_audio_output_route_classes",
        "current_audio_output_route_classes",
        "audio_interruption_type",
        "audio_interruption_reason",
        "audio_interruption_options",
        "tts_cancellation_origin",
        "device_identity_hash",
        "configured_gateway_identity_hash",
        "observed_gateway_identity_hash",
        "configured_gateway_identity_source",
        "observed_gateway_identity_source",
        "gateway_identity_comparison",
        "apns_transport",
        "outbox_outcome",
        "outbox_command_hash",
        "outbox_delivery_gate",
        "outbox_flush_trigger",
        "outbox_queued_count",
        "outbox_confirming_count",
        "outbox_blocked_count",
        "outbox_has_verified_route_snapshot",
        "transport_health_ok",
        "delivery_target",
        "delivery_gateway_hash",
        "routing_contract_hash",
        "ack_run_hash",
        "topic",
        "environment",
        "byte_count",
        "sample_rate",
        "duration_milliseconds",
        "prior_build_number",
        "prior_source_sha",
        "prior_main_executable_uuid",
        "current_build_number",
        "current_source_sha",
        "current_main_executable_uuid",
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
