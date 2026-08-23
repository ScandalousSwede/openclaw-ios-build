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

struct TalkTTSProviderAttempt {
    let outputFormat: String?
    let makeStream: @MainActor () -> AsyncThrowingStream<Data, Error>
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

    init(
        pcmPlayer: PCMStreamingAudioPlaying,
        mp3Player: StreamingAudioPlaying,
        systemSpeech: TalkSystemSpeechProviding,
        prepareAudio: @escaping () throws -> TalkAudioRouteEvidence,
        isCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
        report: @escaping (TalkTTSProgress) -> Void)
    {
        self.pcmPlayer = pcmPlayer
        self.mp3Player = mp3Player
        self.systemSpeech = systemSpeech
        self.prepareAudio = prepareAudio
        self.isCurrent = isCurrent
        self.report = report
    }

    func speak(
        text: String,
        language: String?,
        providerAttempt: TalkTTSProviderAttempt?,
        mp3Retry: TalkTTSProviderAttempt?) async -> TalkTTSPlaybackResult
    {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            _ = try self.prepareAudio()
        } catch {
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
            return await self.speakSystem(
                text: text,
                language: language,
                startedAt: startedAt,
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
            return await self.speakSystem(text: text, language: language, startedAt: startedAt)
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
            self.stopProviderPlayer(for: mp3Retry)
            self.report(TalkTTSProgress(
                state: .systemFallback,
                providerAttemptOutcome: retryResult.outcome,
                userMessage: "ElevenLabs playback failed — using iOS voice."))
            return await self.speakSystem(
                text: text,
                language: language,
                startedAt: startedAt,
                providerFailure: retryResult.outcome)
        } else {
            self.report(TalkTTSProgress(
                state: .systemFallback,
                providerAttemptOutcome: firstResult.outcome,
                userMessage: "ElevenLabs playback failed — using iOS voice."))
            return await self.speakSystem(
                text: text,
                language: language,
                startedAt: startedAt,
                providerFailure: firstResult.outcome)
        }
    }

    private func playProviderAttempt(
        _ attempt: TalkTTSProviderAttempt,
        state: TalkTTSState) async -> (outcome: TalkTTSProviderOutcome, bytes: Int, sampleRate: Int?)
    {
        let evidence = TalkTTSStreamEvidenceBox()
        let sampleRate = TalkTTSValidation.pcmSampleRate(from: attempt.outputFormat).map(Int.init)
        let measured = Self.measuredStream(
            attempt.makeStream(),
            evidence: evidence,
            isCurrent: self.isCurrent,
            onFirstAudioByte: { [weak self] firstChunkBytes in
                guard let self, self.isCurrent(), !Task.isCancelled else { return }
                self.report(TalkTTSProgress(
                    state: .audioReceived,
                    firstAudioByteReceived: true,
                    totalAudioBytes: firstChunkBytes,
                    pcmSampleRate: sampleRate))
            })
        self.report(TalkTTSProgress(state: state, pcmSampleRate: sampleRate))
        let playback: StreamingPlaybackResult
        if let sampleRate {
            playback = await self.pcmPlayer.play(stream: measured, sampleRate: Double(sampleRate))
        } else {
            playback = await self.mp3Player.play(stream: measured)
        }
        // Some dependency players can resolve playback before their stream-reader Task exits.
        // Fence this attempt before any retry so late chunks cannot restart or overlap replacement audio.
        evidence.finish()
        let byteCount = evidence.byteCount
        let outcome = TalkTTSFailureClassification.outcome(
            error: evidence.error,
            byteCount: byteCount,
            playback: playback)
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
        do {
            try await self.systemSpeech.speak(text: text, language: language) { [report = self.report] in
                report(TalkTTSProgress(state: .speaking))
            }
            guard self.isCurrent(), !Task.isCancelled else {
                return TalkTTSPlaybackResult(
                    succeeded: false,
                    provider: .system,
                    textPreserved: true,
                    outcome: .interrupted)
            }
            self.report(TalkTTSProgress(
                state: .completed,
                finalProvider: .system,
                finalOutcome: .success,
                durationMilliseconds: Self.durationMilliseconds(since: startedAt),
                userMessage: successMessage ?? Self.systemSuccessMessage(providerFailure: providerFailure)))
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
            self.report(TalkTTSProgress(
                state: .failed,
                finalProvider: .system,
                finalOutcome: .playbackFailed,
                durationMilliseconds: Self.durationMilliseconds(since: startedAt),
                userMessage: "Speech failed — text reply preserved."))
            return TalkTTSPlaybackResult(
                succeeded: false,
                provider: .system,
                textPreserved: true,
                outcome: .playbackFailed)
        }
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

    private static func measuredStream(
        _ stream: AsyncThrowingStream<Data, Error>,
        evidence: TalkTTSStreamEvidenceBox,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        onFirstAudioByte: @escaping @MainActor @Sendable (Int) -> Void) -> AsyncThrowingStream<Data, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await chunk in stream {
                        guard isCurrent(), evidence.isAcceptingBytes, !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        if evidence.record(bytes: chunk.count) {
                            onFirstAudioByte(chunk.count)
                        }
                        continuation.yield(chunk)
                    }
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
