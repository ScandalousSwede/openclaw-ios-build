import AVFAudio
import Foundation
import OpenClawKit

enum TalkTTSTestPhrase {
    static let system = "OpenClaw system voice test successful."
    static let elevenLabs = "OpenClaw ElevenLabs test successful."
}

enum TalkTTSState: String, CaseIterable, Sendable {
    case idle
    case configLoading = "config_loading"
    case configRedacted = "config_redacted"
    case permissionRequired = "permission_required"
    case providerResolved = "provider_resolved"
    case generating
    case audioReceived = "audio_received"
    case pcmPlaying = "pcm_playing"
    case mp3Retry = "mp3_retry"
    case systemFallback = "system_fallback"
    case speaking
    case completed
    case failed
}

enum TalkTTSSecretsAccess: String, Sendable {
    case unknown
    case accepted
    case rejected
    case redacted
}

enum TalkTTSCredentialOwnership: String, Sendable {
    case unknown
    case client
    case gateway
}

enum TalkTTSCredentialSource: String, Sendable {
    case none
    case gatewayConfig = "gateway_config"
    case gatewayRuntime = "gateway_runtime"
    case clientLocalOverride = "client_local_override"
    case clientDebugEnvironment = "client_debug_environment"

    var ownership: TalkTTSCredentialOwnership {
        switch self {
        case .gatewayConfig, .gatewayRuntime: .gateway
        case .clientLocalOverride, .clientDebugEnvironment: .client
        case .none: .unknown
        }
    }

    var clientAPIKeyPresent: Bool {
        switch self {
        case .gatewayConfig, .clientLocalOverride, .clientDebugEnvironment: true
        case .gatewayRuntime, .none: false
        }
    }
}

enum TalkTTSCredentialSourceResolver {
    static func resolve(
        gatewayOwnedProvider: Bool,
        gatewayConfigKeyPresent: Bool,
        localOverrideKeyPresent: Bool,
        debugEnvironmentKeyPresent: Bool) -> TalkTTSCredentialSource
    {
        if gatewayOwnedProvider { return .gatewayRuntime }
        if localOverrideKeyPresent { return .clientLocalOverride }
        if gatewayConfigKeyPresent { return .gatewayConfig }
        if debugEnvironmentKeyPresent { return .clientDebugEnvironment }
        return .none
    }
}

enum TalkTTSAvailabilityMessage {
    static func elevenLabsUnavailable(
        permissionRequired: Bool,
        configLoaded: Bool,
        apiKeyPresent: Bool,
        voiceIDPresent: Bool) -> String
    {
        if permissionRequired {
            return "Gateway permission required. iOS voice succeeded; text reply preserved."
        }
        if !configLoaded {
            return "Talk configuration unavailable. iOS voice succeeded; text reply preserved."
        }
        if !apiKeyPresent {
            return "ElevenLabs API key unavailable. iOS voice succeeded; text reply preserved."
        }
        if !voiceIDPresent {
            return "ElevenLabs voice ID unavailable. iOS voice succeeded; text reply preserved."
        }
        return "ElevenLabs unavailable. iOS voice succeeded; text reply preserved."
    }
}

enum TalkTTSScopePresence: String, Sendable {
    case unknown
    case present
    case absent
}

enum TalkTTSProviderOutcome: String, Sendable {
    case notAttempted = "not_attempted"
    case success
    case http4xx = "http_4xx"
    case http5xx = "http_5xx"
    case timeout
    case transportError = "transport_error"
    case playbackFailed = "playback_failed"
    case zeroAudio = "zero_audio"
    case interrupted
}

struct TalkTTSConfigEvidence: Equatable, Sendable {
    var loaded = false
    var secretsAccess: TalkTTSSecretsAccess = .unknown
    var provider = "unknown"
    var modelPresent = false
    var voiceIDPresent = false
    var apiKeyPresent = false
    var credentialSource: TalkTTSCredentialSource = .none
    var credentialOwnership: TalkTTSCredentialOwnership = .unknown
    var operatorTalkSecrets: TalkTTSScopePresence = .unknown
}

enum TalkTTSConfigEvidenceBuilder {
    static func build(
        loaded: Bool,
        secretsAccess: TalkTTSSecretsAccess,
        provider: String,
        modelPresent: Bool,
        voiceIDPresent: Bool,
        apiKeyPresent: Bool,
        credentialSource: TalkTTSCredentialSource) -> TalkTTSConfigEvidence
    {
        let operatorTalkSecrets: TalkTTSScopePresence = switch secretsAccess {
        case .accepted: .present
        case .rejected: .absent
        case .redacted, .unknown: .unknown
        }
        return TalkTTSConfigEvidence(
            loaded: loaded,
            secretsAccess: secretsAccess,
            provider: provider,
            modelPresent: modelPresent,
            voiceIDPresent: voiceIDPresent,
            apiKeyPresent: apiKeyPresent,
            credentialSource: credentialSource,
            credentialOwnership: credentialSource.ownership,
            operatorTalkSecrets: operatorTalkSecrets)
    }
}

struct TalkAudioRouteEvidence: Equatable, Sendable {
    enum Activation: String, Sendable {
        case unknown
        case active
        case inactive
    }

    var outputPortTypes: [String] = []
    var outputNames: [String] = []
    var speakerphonePreferred = false
    var category = "unknown"
    var mode = "unknown"
    var activation: Activation = .unknown

    var outputSummary: String {
        guard !self.outputPortTypes.isEmpty else { return "No output route" }
        return self.outputPortTypes.enumerated().map { element in
            let name = self.outputNames.indices.contains(element.offset)
                ? self.outputNames[element.offset]
                : ""
            return name.isEmpty ? element.element : "\(element.element) — \(name)"
        }.joined(separator: ", ")
    }
}

enum TalkTTSPlaybackProvider: String, Sendable {
    case elevenLabs = "elevenlabs"
    case system
    case none
}

struct TalkTTSDiagnosticSnapshot: Equatable, Sendable {
    var state: TalkTTSState = .idle
    var config = TalkTTSConfigEvidence()
    var route = TalkAudioRouteEvidence()
    var providerAttemptOutcome: TalkTTSProviderOutcome = .notAttempted
    var finalProvider: TalkTTSPlaybackProvider = .none
    var finalOutcome: TalkTTSProviderOutcome = .notAttempted
    var firstAudioByteReceived = false
    var totalAudioBytes = 0
    var pcmSampleRate: Int?
    var durationMilliseconds: Int?
    var userMessage = "Speech has not been tested."
}

struct TalkTTSPlaybackResult: Equatable, Sendable {
    let succeeded: Bool
    let provider: TalkTTSPlaybackProvider
    let textPreserved: Bool
    let outcome: TalkTTSProviderOutcome
}

enum TalkTTSPayloadValidationEvidence: Equatable, Sendable {
    case notObserved
    case providerContentTypeValidated
}

struct TalkTTSProviderAttempt {
    let outputFormat: String?
    let payloadValidation: TalkTTSPayloadValidationEvidence
    let makeStream: @MainActor () -> AsyncThrowingStream<Data, Error>

    init(
        outputFormat: String?,
        payloadValidation: TalkTTSPayloadValidationEvidence = .notObserved,
        makeStream: @escaping @MainActor () -> AsyncThrowingStream<Data, Error>)
    {
        self.outputFormat = outputFormat
        self.payloadValidation = payloadValidation
        self.makeStream = makeStream
    }
}

struct TalkTTSProgress: Sendable {
    let state: TalkTTSState
    var providerAttemptOutcome: TalkTTSProviderOutcome? = nil
    var finalProvider: TalkTTSPlaybackProvider? = nil
    var finalOutcome: TalkTTSProviderOutcome? = nil
    var firstAudioByteReceived: Bool? = nil
    var totalAudioBytes: Int? = nil
    var pcmSampleRate: Int? = nil
    var pcmFormatRejected: Bool? = nil
    var durationMilliseconds: Int? = nil
    var userMessage: String? = nil
}

/// Metadata-only checkpoints for post-relaunch crash diagnostics. Values are deliberately
/// bounded to enums, numeric measurements, and route/format tokens; user text is never recorded.
enum TalkTTSBreadcrumbStage: String, Sendable {
    case requestAdmitted = "tts_request_admitted"
    case playbackPipelineEntered = "tts_playback_pipeline_entered"
    case audioSessionPrepareStarted = "tts_audio_session_prepare_started"
    case audioSessionPrepared = "tts_audio_session_prepared"
    case audioSessionPrepareFailed = "tts_audio_session_prepare_failed"
    case providerRequestStarted = "tts_provider_request_started"
    case decoderSelected = "tts_decoder_selected"
    case playerCallEntered = "tts_player_call_entered"
    case firstAudioByte = "tts_first_audio_byte"
    case playerCallReturned = "tts_player_call_returned"
    case providerResult = "tts_provider_result"
    case fallbackTransition = "tts_fallback_transition"
    case systemSpeechCallEntered = "tts_system_speech_call_entered"
    case playbackStarted = "tts_playback_started"
    case playbackCompleted = "tts_playback_completed"
    case playbackFailed = "tts_playback_failed"
    case audioSessionRestoreStarted = "tts_audio_session_restore_started"
    case generationCancelled = "tts_generation_cancelled"
    case generationFinalized = "tts_generation_finalized"

    var requestsDurableWrite: Bool {
        true
    }
}

struct TalkTTSBreadcrumb: Equatable, Sendable {
    let stage: TalkTTSBreadcrumbStage
    var detail: String? = nil
    var byteCount: Int? = nil
    var sampleRate: Int? = nil
    var durationMilliseconds: Int? = nil
}

enum TalkTTSLifecycleObservationStage: String, Sendable {
    case providerRequestStarted = "provider_request_started"
    case providerResponseReceived = "provider_response_received"
    case streamFirstChunkReceived = "stream_first_chunk_received"
    case streamCompleted = "stream_completed"
    case audioPayloadValidated = "audio_payload_validated"
    case decoderSelected = "decoder_selected"
    case audioSessionActivationStarted = "audio_session_activation_started"
    case audioSessionActivationSucceeded = "audio_session_activation_succeeded"
    case audioSessionActivationFailed = "audio_session_activation_failed"
    case outputRouteObserved = "output_route_observed"
    case fallbackSelected = "fallback_selected"
    case fallbackStarted = "fallback_started"
    case fallbackCompleted = "fallback_completed"
    case fallbackFailed = "fallback_failed"
    case firstRenderCallbackObserved = "first_render_callback_observed"
}

struct TalkTTSLifecycleObservation: Equatable, Sendable {
    let stage: TalkTTSLifecycleObservationStage
    let provider: String
    let codec: String
    let playbackPath: String
    var providerStage: String? = nil
    var byteCount: Int? = nil
    var resultClass: String? = nil
}

extension TalkTTSDiagnosticSnapshot {
    mutating func apply(_ progress: TalkTTSProgress) {
        self.state = progress.state
        if let outcome = progress.providerAttemptOutcome {
            self.providerAttemptOutcome = outcome
        }
        if let provider = progress.finalProvider {
            self.finalProvider = provider
        }
        if let outcome = progress.finalOutcome {
            self.finalOutcome = outcome
        }
        if let received = progress.firstAudioByteReceived {
            self.firstAudioByteReceived = received
        }
        if let bytes = progress.totalAudioBytes {
            self.totalAudioBytes = max(0, bytes)
        }
        if let sampleRate = progress.pcmSampleRate {
            self.pcmSampleRate = sampleRate
        }
        if let duration = progress.durationMilliseconds {
            self.durationMilliseconds = max(0, duration)
        }
        if let message = progress.userMessage {
            self.userMessage = message
        }
    }
}

@MainActor
protocol TalkSystemSpeechProviding: AnyObject {
    func speak(text: String, language: String?, onStart: (() -> Void)?) async throws
    func stop()
}

extension TalkSystemSpeechSynthesizer: TalkSystemSpeechProviding {}

final class TalkTTSStreamEvidenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var byteCountStorage = 0
    private var errorStorage: Error?
    private var acceptingBytesStorage = true

    func record(bytes: Int) -> Bool {
        let acceptedBytes = max(0, bytes)
        self.lock.lock()
        let isFirstAudioByte = self.byteCountStorage == 0 && acceptedBytes > 0
        self.byteCountStorage += acceptedBytes
        self.lock.unlock()
        return isFirstAudioByte
    }

    func record(error: Error) {
        self.lock.lock()
        self.errorStorage = error
        self.lock.unlock()
    }

    func finish() {
        self.lock.lock()
        self.acceptingBytesStorage = false
        self.lock.unlock()
    }

    var isAcceptingBytes: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.acceptingBytesStorage
    }

    var byteCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.byteCountStorage
    }

    var error: Error? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.errorStorage
    }
}

enum TalkTTSFailureClassification {
    static func outcome(error: Error?, byteCount: Int, playback: StreamingPlaybackResult) -> TalkTTSProviderOutcome {
        if playback.interruptedAt != nil { return .interrupted }
        if byteCount == 0, playback.finished { return .zeroAudio }
        if let error = error as NSError? {
            if error.code == 408 || error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
                return .timeout
            }
            if error.domain == "ElevenLabsTTS" {
                if (400...499).contains(error.code) { return .http4xx }
                if (500...599).contains(error.code) { return .http5xx }
            }
            return .transportError
        }
        return playback.finished ? .success : .playbackFailed
    }

    static func isPCMFormatRejected(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        guard error.domain == "ElevenLabsTTS", error.code >= 400 else { return false }
        let message = (error.userInfo[NSLocalizedDescriptionKey] as? String ?? "").lowercased()
        return message.contains("output_format")
            || message.contains("pcm_")
            || message.contains("pcm ")
            || message.contains("subscription_required")
    }
}

enum TalkAudioRoutePolicy {
    private static let externalPortTypes: Set<String> = [
        AVAudioSession.Port.airPlay.rawValue,
        AVAudioSession.Port.bluetoothA2DP.rawValue,
        AVAudioSession.Port.bluetoothHFP.rawValue,
        AVAudioSession.Port.bluetoothLE.rawValue,
        AVAudioSession.Port.carAudio.rawValue,
        AVAudioSession.Port.headphones.rawValue,
        AVAudioSession.Port.usbAudio.rawValue,
    ]

    static func shouldOverrideToSpeaker(
        speakerphonePreferred: Bool,
        outputPortTypes: [String]) -> Bool
    {
        speakerphonePreferred && !outputPortTypes.contains(where: self.externalPortTypes.contains)
    }
}

@MainActor
final class TalkTTSPlaybackPipeline {
    private let pcmPlayer: PCMStreamingAudioPlaying
    private let mp3Player: StreamingAudioPlaying
    private let systemSpeech: TalkSystemSpeechProviding
    private let prepareAudio: () throws -> TalkAudioRouteEvidence
    private let isCurrent: @MainActor @Sendable () -> Bool
    private let report: (TalkTTSProgress) -> Void
    private let breadcrumb: (TalkTTSBreadcrumb) -> Void
    private let playbackObserver: StreamingPlaybackObserver
    private let lifecycleObserver: (TalkTTSLifecycleObservation) -> Void

    init(
        pcmPlayer: PCMStreamingAudioPlaying,
        mp3Player: StreamingAudioPlaying,
        systemSpeech: TalkSystemSpeechProviding,
        prepareAudio: @escaping () throws -> TalkAudioRouteEvidence,
        isCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
        report: @escaping (TalkTTSProgress) -> Void,
        breadcrumb: @escaping (TalkTTSBreadcrumb) -> Void = { _ in },
        playbackObserver: StreamingPlaybackObserver = StreamingPlaybackObserver(),
        lifecycleObserver: @escaping (TalkTTSLifecycleObservation) -> Void = { _ in })
    {
        self.pcmPlayer = pcmPlayer
        self.mp3Player = mp3Player
        self.systemSpeech = systemSpeech
        self.prepareAudio = prepareAudio
        self.isCurrent = isCurrent
        self.report = report
        self.breadcrumb = breadcrumb
        self.playbackObserver = playbackObserver
        self.lifecycleObserver = lifecycleObserver
    }

    func speak(
        text: String,
        language: String?,
        providerAttempt: TalkTTSProviderAttempt?,
        mp3Retry: TalkTTSProviderAttempt?) async -> TalkTTSPlaybackResult
    {
        let startedAt = ProcessInfo.processInfo.systemUptime
        self.breadcrumb(TalkTTSBreadcrumb(stage: .playbackPipelineEntered))
        self.breadcrumb(TalkTTSBreadcrumb(stage: .audioSessionPrepareStarted))
        self.observe(.audioSessionActivationStarted, attempt: providerAttempt)
        do {
            let route = try self.prepareAudio()
            self.breadcrumb(TalkTTSBreadcrumb(
                stage: .audioSessionPrepared,
                detail: Self.routeToken(route)))
            self.observe(
                .audioSessionActivationSucceeded,
                attempt: providerAttempt,
                resultClass: "success")
            self.observe(
                .outputRouteObserved,
                attempt: providerAttempt,
                providerStage: TalkTTSLifecycleObservationStage.outputRouteObserved.rawValue,
                resultClass: Self.outputRouteResultClass(route))
        } catch {
            self.breadcrumb(TalkTTSBreadcrumb(stage: .audioSessionPrepareFailed))
            self.observe(
                .audioSessionActivationFailed,
                attempt: providerAttempt,
                resultClass: "failed")
            guard self.isCurrent(), !Task.isCancelled else {
                return TalkTTSPlaybackResult(
                    succeeded: false,
                    provider: .system,
                    textPreserved: true,
                    outcome: .interrupted)
            }
            self.report(TalkTTSProgress(
                state: .systemFallback,
                userMessage: "Audio setup failed — trying iOS voice."))
            self.breadcrumb(TalkTTSBreadcrumb(
                stage: .fallbackTransition,
                detail: "audio_session_to_system"))
            self.observeFallbackSelected("audio_session_to_system")
            return await self.speakSystem(
                text: text,
                language: language,
                startedAt: startedAt,
                fallbackReason: "audio_session_to_system",
                successMessage: "Audio setup failed — iOS voice succeeded; text reply preserved.")
        }

        guard self.isCurrent(), !Task.isCancelled else {
            return TalkTTSPlaybackResult(
                succeeded: false,
                provider: .none,
                textPreserved: true,
                outcome: .interrupted)
        }
        guard let providerAttempt else {
            self.report(TalkTTSProgress(
                state: .systemFallback,
                userMessage: "ElevenLabs unavailable — using iOS voice."))
            self.breadcrumb(TalkTTSBreadcrumb(
                stage: .fallbackTransition,
                detail: "provider_unavailable_to_system"))
            self.observeFallbackSelected("provider_unavailable_to_system")
            return await self.speakSystem(
                text: text,
                language: language,
                startedAt: startedAt,
                fallbackReason: "provider_unavailable_to_system")
        }

        self.report(TalkTTSProgress(state: .generating))
        let firstState: TalkTTSState = TalkTTSValidation.pcmSampleRate(from: providerAttempt.outputFormat) == nil
            ? .speaking
            : .pcmPlaying
        let firstResult = await self.playProviderAttempt(providerAttempt, state: firstState)
        guard self.isCurrent() else {
            return TalkTTSPlaybackResult(
                succeeded: false,
                provider: .elevenLabs,
                textPreserved: true,
                outcome: .interrupted)
        }
        guard !Task.isCancelled else {
            self.stopProviderPlayer(for: providerAttempt)
            return TalkTTSPlaybackResult(
                succeeded: false,
                provider: .elevenLabs,
                textPreserved: true,
                outcome: .interrupted)
        }
        if firstResult.outcome == .success {
            self.stopSuccessfulPCMIfNeeded(for: providerAttempt)
            return self.completeProvider(result: firstResult, startedAt: startedAt)
        }
        if firstResult.outcome == .interrupted {
            self.report(TalkTTSProgress(
                state: .failed,
                providerAttemptOutcome: .interrupted,
                finalProvider: .elevenLabs,
                finalOutcome: .interrupted,
                userMessage: "Speech interrupted — text reply preserved."))
            return TalkTTSPlaybackResult(
                succeeded: false,
                provider: .elevenLabs,
                textPreserved: true,
                outcome: .interrupted)
        }

        self.stopProviderPlayer(for: providerAttempt)
        if let mp3Retry {
            self.report(TalkTTSProgress(
                state: .mp3Retry,
                providerAttemptOutcome: firstResult.outcome,
                userMessage: "ElevenLabs PCM playback failed — retrying MP3."))
            self.breadcrumb(TalkTTSBreadcrumb(
                stage: .fallbackTransition,
                detail: "pcm_to_mp3"))
            self.observe(
                .fallbackSelected,
                attempt: mp3Retry,
                providerStage: "pcm_to_mp3")
            self.observe(
                .fallbackStarted,
                attempt: mp3Retry,
                providerStage: "pcm_to_mp3")
            let retryResult = await self.playProviderAttempt(mp3Retry, state: .mp3Retry)
            guard self.isCurrent() else {
                return TalkTTSPlaybackResult(
                    succeeded: false,
                    provider: .elevenLabs,
                    textPreserved: true,
                    outcome: .interrupted)
            }
            guard !Task.isCancelled else {
                self.stopProviderPlayer(for: mp3Retry)
                return TalkTTSPlaybackResult(
                    succeeded: false,
                    provider: .elevenLabs,
                    textPreserved: true,
                    outcome: .interrupted)
            }
            if retryResult.outcome == .success {
                self.observe(
                    .fallbackCompleted,
                    attempt: mp3Retry,
                    providerStage: "pcm_to_mp3",
                    resultClass: "success")
                self.stopSuccessfulPCMIfNeeded(for: mp3Retry)
                return self.completeProvider(result: retryResult, startedAt: startedAt)
            }
            if retryResult.outcome == .interrupted {
                self.report(TalkTTSProgress(
                    state: .failed,
                    providerAttemptOutcome: .interrupted,
                    finalProvider: .elevenLabs,
                    finalOutcome: .interrupted,
                    userMessage: "Speech interrupted — text reply preserved."))
                return TalkTTSPlaybackResult(
                    succeeded: false,
                    provider: .elevenLabs,
                    textPreserved: true,
                    outcome: .interrupted)
            }
            self.observe(
                .fallbackFailed,
                attempt: mp3Retry,
                providerStage: "pcm_to_mp3",
                resultClass: "failed")
            self.stopProviderPlayer(for: mp3Retry)
            self.report(TalkTTSProgress(
                state: .systemFallback,
                providerAttemptOutcome: retryResult.outcome,
                userMessage: "ElevenLabs playback failed — using iOS voice."))
            self.breadcrumb(TalkTTSBreadcrumb(
                stage: .fallbackTransition,
                detail: "mp3_to_system"))
            self.observeFallbackSelected("mp3_to_system")
            return await self.speakSystem(
                text: text,
                language: language,
                startedAt: startedAt,
                fallbackReason: "mp3_to_system",
                providerFailure: retryResult.outcome)
        } else {
            self.report(TalkTTSProgress(
                state: .systemFallback,
                providerAttemptOutcome: firstResult.outcome,
                userMessage: "ElevenLabs playback failed — using iOS voice."))
            self.breadcrumb(TalkTTSBreadcrumb(
                stage: .fallbackTransition,
                detail: "provider_to_system"))
            self.observeFallbackSelected("provider_to_system")
            return await self.speakSystem(
                text: text,
                language: language,
                startedAt: startedAt,
                fallbackReason: "provider_to_system",
                providerFailure: firstResult.outcome)
        }
    }

    private func playProviderAttempt(
        _ attempt: TalkTTSProviderAttempt,
        state: TalkTTSState) async -> (outcome: TalkTTSProviderOutcome, bytes: Int, sampleRate: Int?)
    {
        let evidence = TalkTTSStreamEvidenceBox()
        let sampleRate = TalkTTSValidation.pcmSampleRate(from: attempt.outputFormat).map(Int.init)
        let decoder = sampleRate == nil ? "mp3" : "pcm"
        let codec = decoder
        self.breadcrumb(TalkTTSBreadcrumb(
            stage: .providerRequestStarted,
            detail: decoder,
            sampleRate: sampleRate))
        self.observe(.providerRequestStarted, attempt: attempt)
        self.breadcrumb(TalkTTSBreadcrumb(
            stage: .decoderSelected,
            detail: decoder,
            sampleRate: sampleRate))
        self.observe(.decoderSelected, attempt: attempt)
        let measured = Self.measuredStream(
            attempt.makeStream(),
            evidence: evidence,
            isCurrent: self.isCurrent,
            onFirstStreamChunk: { [weak self] firstChunkBytes in
                guard let self, self.isCurrent(), !Task.isCancelled else { return }
                self.observe(
                    .providerResponseReceived,
                    provider: "elevenlabs",
                    codec: codec,
                    playbackPath: decoder,
                    byteCount: firstChunkBytes,
                    resultClass: "success")
                self.observe(
                    .streamFirstChunkReceived,
                    provider: "elevenlabs",
                    codec: codec,
                    playbackPath: decoder,
                    byteCount: firstChunkBytes,
                    resultClass: "success")
            },
            onFirstAudioByte: { [weak self] firstChunkBytes in
                guard let self, self.isCurrent(), !Task.isCancelled else { return }
                self.report(TalkTTSProgress(
                    state: .audioReceived,
                    firstAudioByteReceived: true,
                    totalAudioBytes: firstChunkBytes,
                    pcmSampleRate: sampleRate))
                self.breadcrumb(TalkTTSBreadcrumb(
                    stage: .firstAudioByte,
                    detail: decoder,
                    byteCount: firstChunkBytes,
                    sampleRate: sampleRate))
            },
            onStreamCompleted: { [weak self] byteCount in
                guard let self, self.isCurrent(), !Task.isCancelled else { return }
                self.observe(
                    .streamCompleted,
                    provider: "elevenlabs",
                    codec: codec,
                    playbackPath: decoder,
                    byteCount: byteCount,
                    resultClass: "success")
            })
        self.report(TalkTTSProgress(state: state, pcmSampleRate: sampleRate))
        self.breadcrumb(TalkTTSBreadcrumb(
            stage: .playerCallEntered,
            detail: decoder,
            sampleRate: sampleRate))
        let playback: StreamingPlaybackResult
        if let sampleRate {
            playback = await self.pcmPlayer.play(
                stream: measured,
                sampleRate: Double(sampleRate),
                observer: self.playbackObserver)
        } else {
            playback = await self.mp3Player.play(
                stream: measured,
                observer: self.playbackObserver)
        }
        self.breadcrumb(TalkTTSBreadcrumb(
            stage: .playerCallReturned,
            detail: Self.playbackResultToken(playback),
            sampleRate: sampleRate))
        // Some dependency players can resolve playback before their stream-reader Task exits.
        // Fence this attempt before any retry so late chunks cannot restart or overlap replacement audio.
        evidence.finish()
        let byteCount = evidence.byteCount
        let outcome = TalkTTSFailureClassification.outcome(
            error: evidence.error,
            byteCount: byteCount,
            playback: playback)
        if byteCount == 0, outcome == .http4xx || outcome == .http5xx {
            self.observe(
                .providerResponseReceived,
                attempt: attempt,
                resultClass: outcome.rawValue)
        }
        if attempt.payloadValidation == .providerContentTypeValidated,
           evidence.error == nil,
           byteCount > 0
        {
            self.observe(
                .audioPayloadValidated,
                attempt: attempt,
                byteCount: byteCount,
                resultClass: "provider_content_type_validated_nonempty")
        }
        self.breadcrumb(TalkTTSBreadcrumb(
            stage: .providerResult,
            detail: outcome.rawValue,
            byteCount: byteCount,
            sampleRate: sampleRate))
        guard self.isCurrent(), !Task.isCancelled else {
            return (outcome, byteCount, sampleRate)
        }
        if byteCount > 0 {
            self.report(TalkTTSProgress(
                state: .audioReceived,
                providerAttemptOutcome: outcome,
                firstAudioByteReceived: true,
                totalAudioBytes: byteCount,
                pcmSampleRate: sampleRate,
                pcmFormatRejected: TalkTTSFailureClassification.isPCMFormatRejected(evidence.error)))
        } else {
            self.report(TalkTTSProgress(
                state: state,
                providerAttemptOutcome: outcome,
                firstAudioByteReceived: false,
                totalAudioBytes: 0,
                pcmSampleRate: sampleRate,
                pcmFormatRejected: TalkTTSFailureClassification.isPCMFormatRejected(evidence.error)))
        }
        return (outcome, byteCount, sampleRate)
    }

    private func completeProvider(
        result: (outcome: TalkTTSProviderOutcome, bytes: Int, sampleRate: Int?),
        startedAt: TimeInterval) -> TalkTTSPlaybackResult
    {
        let duration = Self.durationMilliseconds(since: startedAt)
        self.report(TalkTTSProgress(
            state: .completed,
            providerAttemptOutcome: .success,
            finalProvider: .elevenLabs,
            finalOutcome: .success,
            firstAudioByteReceived: true,
            totalAudioBytes: result.bytes,
            pcmSampleRate: result.sampleRate,
            durationMilliseconds: duration,
            userMessage: "Speech completed with ElevenLabs."))
        self.breadcrumb(TalkTTSBreadcrumb(
            stage: .playbackCompleted,
            detail: "elevenlabs",
            byteCount: result.bytes,
            sampleRate: result.sampleRate,
            durationMilliseconds: duration))
        return TalkTTSPlaybackResult(
            succeeded: true,
            provider: .elevenLabs,
            textPreserved: true,
            outcome: .success)
    }

    private func speakSystem(
        text: String,
        language: String?,
        startedAt: TimeInterval,
        fallbackReason: String,
        providerFailure: TalkTTSProviderOutcome? = nil,
        successMessage: String? = nil) async -> TalkTTSPlaybackResult
    {
        guard self.isCurrent(), !Task.isCancelled else {
            return TalkTTSPlaybackResult(
                succeeded: false,
                provider: .none,
                textPreserved: true,
                outcome: .interrupted)
        }
        self.breadcrumb(TalkTTSBreadcrumb(
            stage: .systemSpeechCallEntered,
            detail: providerFailure?.rawValue ?? "direct"))
        self.observe(
            .fallbackStarted,
            provider: "system",
            codec: "system_speech",
            playbackPath: "system",
            providerStage: fallbackReason)
        do {
            try await self.systemSpeech.speak(text: text, language: language) {
                [weak self, report = self.report, breadcrumb = self.breadcrumb] in
                report(TalkTTSProgress(state: .speaking))
                breadcrumb(TalkTTSBreadcrumb(stage: .playbackStarted, detail: "system"))
                self?.observe(
                    .firstRenderCallbackObserved,
                    provider: "system",
                    codec: "system_speech",
                    playbackPath: "system")
            }
            guard self.isCurrent(), !Task.isCancelled else {
                return TalkTTSPlaybackResult(
                    succeeded: false,
                    provider: .system,
                    textPreserved: true,
                    outcome: .interrupted)
            }
            let duration = Self.durationMilliseconds(since: startedAt)
            self.report(TalkTTSProgress(
                state: .completed,
                finalProvider: .system,
                finalOutcome: .success,
                durationMilliseconds: duration,
                userMessage: successMessage ?? Self.systemSuccessMessage(providerFailure: providerFailure)))
            self.breadcrumb(TalkTTSBreadcrumb(
                stage: .playbackCompleted,
                detail: "system",
                durationMilliseconds: duration))
            self.observe(
                .fallbackCompleted,
                provider: "system",
                codec: "system_speech",
                playbackPath: "system",
                providerStage: fallbackReason,
                resultClass: "success")
            return TalkTTSPlaybackResult(
                succeeded: true,
                provider: .system,
                textPreserved: true,
                outcome: .success)
        } catch {
            guard self.isCurrent(), !Task.isCancelled else {
                return TalkTTSPlaybackResult(
                    succeeded: false,
                    provider: .system,
                    textPreserved: true,
                    outcome: .interrupted)
            }
            let duration = Self.durationMilliseconds(since: startedAt)
            self.report(TalkTTSProgress(
                state: .failed,
                finalProvider: .system,
                finalOutcome: .playbackFailed,
                durationMilliseconds: duration,
                userMessage: "Speech failed — text reply preserved."))
            self.breadcrumb(TalkTTSBreadcrumb(
                stage: .playbackFailed,
                detail: "system",
                durationMilliseconds: duration))
            self.observe(
                .fallbackFailed,
                provider: "system",
                codec: "system_speech",
                playbackPath: "system",
                providerStage: fallbackReason,
                resultClass: "failed")
            return TalkTTSPlaybackResult(
                succeeded: false,
                provider: .system,
                textPreserved: true,
                outcome: .playbackFailed)
        }
    }

    private func observeFallbackSelected(_ reason: String) {
        self.observe(
            .fallbackSelected,
            provider: "system",
            codec: "system_speech",
            playbackPath: "system",
            providerStage: reason)
    }

    private func observe(
        _ stage: TalkTTSLifecycleObservationStage,
        attempt: TalkTTSProviderAttempt? = nil,
        provider: String? = nil,
        codec: String? = nil,
        playbackPath: String? = nil,
        providerStage: String? = nil,
        byteCount: Int? = nil,
        resultClass: String? = nil)
    {
        let inferredPath: String
        if let attempt {
            inferredPath = TalkTTSValidation.pcmSampleRate(from: attempt.outputFormat) == nil
                ? "mp3"
                : "pcm"
        } else {
            inferredPath = "system"
        }
        self.lifecycleObserver(TalkTTSLifecycleObservation(
            stage: stage,
            provider: provider ?? (attempt == nil ? "system" : "elevenlabs"),
            codec: codec ?? attempt.map {
                TalkTTSValidation.pcmSampleRate(from: $0.outputFormat) == nil ? "mp3" : "pcm"
            } ?? "system_speech",
            playbackPath: playbackPath ?? inferredPath,
            providerStage: providerStage ?? stage.rawValue,
            byteCount: byteCount.map { max(0, $0) },
            resultClass: resultClass))
    }

    private func stopProviderPlayer(for attempt: TalkTTSProviderAttempt) {
        if TalkTTSValidation.pcmSampleRate(from: attempt.outputFormat) != nil {
            _ = self.pcmPlayer.stop()
        } else {
            _ = self.mp3Player.stop()
        }
    }

    private func stopSuccessfulPCMIfNeeded(for attempt: TalkTTSProviderAttempt) {
        guard TalkTTSValidation.pcmSampleRate(from: attempt.outputFormat) != nil else { return }
        // ElevenLabsKit 0.1.1 resolves successful PCM playback without stopping its engine/player.
        _ = self.pcmPlayer.stop()
    }

    private static func systemSuccessMessage(providerFailure: TalkTTSProviderOutcome?) -> String {
        guard let providerFailure else { return "Speech completed with iOS voice." }
        return "ElevenLabs failed (\(providerFailure.rawValue)) — iOS voice succeeded; text reply preserved."
    }

    private static func formatToken(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unspecified" }
        return String(value.lowercased().map { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
                ? character
                : "_"
        }.prefix(48))
    }

    private static func routeToken(_ route: TalkAudioRouteEvidence) -> String {
        let category = Self.routeComponent(route.category, removing: "avaudiosessioncategory")
        let mode = Self.routeComponent(route.mode, removing: "avaudiosessionmode")
        let port = Self.routeComponent(route.outputPortTypes.first ?? "no_output", removing: "avaudiosessionport")
        return Self.formatToken("\(category)_\(mode)_\(route.activation.rawValue)_\(port)")
    }

    private static func outputRouteResultClass(_ route: TalkAudioRouteEvidence) -> String {
        guard let rawPort = route.outputPortTypes.first?.lowercased(), !rawPort.isEmpty else {
            return "production_route_no_output"
        }
        if rawPort.contains("builtinspeaker") { return "production_route_speaker" }
        if rawPort.contains("builtinreceiver") { return "production_route_receiver" }
        if rawPort.contains("bluetooth") { return "production_route_bluetooth" }
        if rawPort.contains("headphone") || rawPort.contains("headset") {
            return "production_route_headphones"
        }
        if rawPort.contains("airplay") { return "production_route_airplay" }
        if rawPort.contains("usb") { return "production_route_usb" }
        if rawPort.contains("hdmi") { return "production_route_hdmi" }
        if rawPort.contains("caraudio") { return "production_route_car_audio" }
        return "production_route_other"
    }

    private static func routeComponent(_ value: String, removing prefix: String) -> String {
        let token = Self.formatToken(value)
        return token.hasPrefix(prefix) ? String(token.dropFirst(prefix.count)) : token
    }

    private static func playbackResultToken(_ result: StreamingPlaybackResult) -> String {
        if result.interruptedAt != nil { return "interrupted" }
        return result.finished ? "finished" : "incomplete"
    }

    private static func measuredStream(
        _ stream: AsyncThrowingStream<Data, Error>,
        evidence: TalkTTSStreamEvidenceBox,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        onFirstStreamChunk: @escaping @MainActor @Sendable (Int) -> Void,
        onFirstAudioByte: @escaping @MainActor @Sendable (Int) -> Void,
        onStreamCompleted: @escaping @MainActor @Sendable (Int) -> Void) -> AsyncThrowingStream<Data, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var receivedChunk = false
                do {
                    for try await chunk in stream {
                        guard isCurrent(), evidence.isAcceptingBytes, !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        if !receivedChunk {
                            receivedChunk = true
                            onFirstStreamChunk(chunk.count)
                        }
                        if evidence.record(bytes: chunk.count) {
                            onFirstAudioByte(chunk.count)
                        }
                        continuation.yield(chunk)
                    }
                    onStreamCompleted(evidence.byteCount)
                    continuation.finish()
                } catch {
                    evidence.record(error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func durationMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
    }
}
