import AVFAudio
import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

@MainActor
private final class TestSystemSpeech: TalkSystemSpeechProviding {
    var error: Error?
    var emitsStartCallback = true
    private(set) var spokenTexts: [String] = []
    private(set) var stopCount = 0

    func speak(text: String, language _: String?, onStart: (() -> Void)?) async throws {
        self.spokenTexts.append(text)
        if self.emitsStartCallback { onStart?() }
        if let error { throw error }
    }

    func stop() {
        self.stopCount += 1
    }
}

@MainActor
private final class SuspendedSystemSpeech: TalkSystemSpeechProviding {
    private var nextCallID = 0
    private var pendingCalls: [Int: CheckedContinuation<Void, Error>] = [:]
    private var callWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var stopCount = 0

    var callCount: Int {
        self.nextCallID
    }

    func speak(text _: String, language _: String?, onStart: (() -> Void)?) async throws {
        self.nextCallID += 1
        let callID = self.nextCallID
        onStart?()
        for target in Array(self.callWaiters.keys).filter({ $0 <= callID }) {
            self.callWaiters.removeValue(forKey: target)?.resume()
        }
        try await withCheckedThrowingContinuation { continuation in
            self.pendingCalls[callID] = continuation
        }
    }

    func stop() {
        // Intentionally leave admitted calls suspended to model a late completion callback.
        self.stopCount += 1
    }

    func waitForCallCount(_ expected: Int) async {
        guard self.nextCallID < expected else { return }
        await withCheckedContinuation { continuation in
            self.callWaiters[expected] = continuation
        }
    }

    func complete(callID: Int) {
        self.pendingCalls.removeValue(forKey: callID)?.resume()
    }
}

@MainActor
private final class SuspendedIncrementalPreSpeak {
    private var didSuspend = false
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendFirst(generation _: UInt64) async {
        guard !self.didSuspend else { return }
        self.didSuspend = true
        self.entered = true
        self.enteredContinuation?.resume()
        self.enteredContinuation = nil
        await withCheckedContinuation { continuation in
            self.releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !self.entered else { return }
        await withCheckedContinuation { continuation in
            self.enteredContinuation = continuation
        }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}

@MainActor
private final class TestPCMPlayer: PCMStreamingAudioPlaying {
    var result = StreamingPlaybackResult(finished: true, interruptedAt: nil)
    var stopResult: Double?
    var afterPlay: (() -> Void)?
    private(set) var playCount = 0
    private(set) var receivedBytes = 0
    private(set) var stopCount = 0

    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate _: Double) async -> StreamingPlaybackResult {
        self.playCount += 1
        do {
            for try await chunk in stream {
                self.receivedBytes += chunk.count
            }
        } catch {
            self.afterPlay?()
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
        self.afterPlay?()
        return self.result
    }

    func stop() -> Double? {
        self.stopCount += 1
        return self.stopResult
    }
}

private final class TestStreamingPlaybackObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StreamingPlaybackObservation] = []

    func record(_ observation: StreamingPlaybackObservation) {
        self.lock.lock()
        self.values.append(observation)
        self.lock.unlock()
    }

    func observations() -> [StreamingPlaybackObservation] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values
    }
}

private final class TestDiagnosticLineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        self.lock.lock()
        self.values.append(value)
        self.lock.unlock()
    }

    func lines() -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values
    }
}

private final class TestLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        self.lock.lock()
        self.value += 1
        self.lock.unlock()
    }

    func count() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

@MainActor
private final class TestTTSLifecycleObservationRecorder {
    private(set) var values: [TalkTTSLifecycleObservation] = []

    func record(_ observation: TalkTTSLifecycleObservation) {
        self.values.append(observation)
    }
}

@MainActor
private final class ObservedTestPCMPlayer: PCMStreamingAudioPlaying {
    private(set) var usedObserverOverload = false

    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate _: Double) async -> StreamingPlaybackResult {
        do {
            for try await _ in stream {}
        } catch {
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
        return StreamingPlaybackResult(finished: true, interruptedAt: nil)
    }

    func play(
        stream: AsyncThrowingStream<Data, Error>,
        sampleRate _: Double,
        observer: StreamingPlaybackObserver) async -> StreamingPlaybackResult
    {
        self.usedObserverOverload = true
        observer.record(StreamingPlaybackObservation(stage: .playerInstanceCreated, path: .pcm))
        observer.record(StreamingPlaybackObservation(stage: .playbackSubmissionStarted, path: .pcm))
        do {
            for try await _ in stream {}
        } catch {
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
        observer.record(StreamingPlaybackObservation(stage: .playbackSubmissionAccepted, path: .pcm))
        observer.record(StreamingPlaybackObservation(stage: .playbackCompleted, path: .pcm))
        return StreamingPlaybackResult(finished: true, interruptedAt: nil)
    }

    func stop() -> Double? { nil }
}

@MainActor
private final class LeakyStopPCMPlayer: PCMStreamingAudioPlaying {
    private var playbackContinuation: CheckedContinuation<StreamingPlaybackResult, Never>?
    private var readerStartedContinuation: CheckedContinuation<Void, Never>?
    private var readerFinishedContinuation: CheckedContinuation<Void, Never>?
    private var readerStarted = false
    private var readerFinished = false
    private(set) var receivedBytes = 0

    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate _: Double) async -> StreamingPlaybackResult {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await chunk in stream {
                    self.receivedBytes += chunk.count
                }
            } catch {}
            self.readerFinished = true
            self.readerFinishedContinuation?.resume()
            self.readerFinishedContinuation = nil
        }
        self.readerStarted = true
        self.readerStartedContinuation?.resume()
        self.readerStartedContinuation = nil
        return await withCheckedContinuation { continuation in
            self.playbackContinuation = continuation
        }
    }

    func stop() -> Double? {
        guard let continuation = self.playbackContinuation else { return nil }
        self.playbackContinuation = nil
        continuation.resume(returning: StreamingPlaybackResult(finished: false, interruptedAt: 0))
        return 0
    }

    func waitUntilReaderStarted() async {
        guard !self.readerStarted else { return }
        await withCheckedContinuation { continuation in
            self.readerStartedContinuation = continuation
        }
    }

    func waitUntilReaderFinished() async {
        guard !self.readerFinished else { return }
        await withCheckedContinuation { continuation in
            self.readerFinishedContinuation = continuation
        }
    }
}

@MainActor
private final class EarlyFailLeakyPCMPlayer: PCMStreamingAudioPlaying {
    private var readerFinishedContinuation: CheckedContinuation<Void, Never>?
    private var readerFinished = false
    private(set) var receivedBytes = 0
    private(set) var stopCount = 0

    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate _: Double) async -> StreamingPlaybackResult {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await chunk in stream {
                    self.receivedBytes += chunk.count
                }
            } catch {}
            self.readerFinished = true
            self.readerFinishedContinuation?.resume()
            self.readerFinishedContinuation = nil
        }
        return StreamingPlaybackResult(finished: false, interruptedAt: nil)
    }

    func stop() -> Double? {
        self.stopCount += 1
        return nil
    }

    func waitUntilReaderFinished() async {
        guard !self.readerFinished else { return }
        await withCheckedContinuation { continuation in
            self.readerFinishedContinuation = continuation
        }
    }
}

@MainActor
private final class ControlledAudioStream {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.stream = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.continuation = captured!
    }

    func yield(_ data: Data) {
        self.continuation.yield(data)
    }

    func finish() {
        self.continuation.finish()
    }
}

@MainActor
private final class TestMP3Player: StreamingAudioPlaying {
    var result = StreamingPlaybackResult(finished: true, interruptedAt: nil)
    var stopResult: Double?
    private(set) var playCount = 0
    private(set) var receivedBytes = 0
    private(set) var stopCount = 0

    func play(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult {
        self.playCount += 1
        do {
            for try await chunk in stream {
                self.receivedBytes += chunk.count
            }
        } catch {
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
        return self.result
    }

    func stop() -> Double? {
        self.stopCount += 1
        return self.stopResult
    }
}

@MainActor
private final class ObservedTestMP3Player: StreamingAudioPlaying {
    private(set) var usedObserverOverload = false

    func play(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult {
        do {
            for try await _ in stream {}
        } catch {
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
        return StreamingPlaybackResult(finished: true, interruptedAt: nil)
    }

    func play(
        stream: AsyncThrowingStream<Data, Error>,
        observer: StreamingPlaybackObserver) async -> StreamingPlaybackResult
    {
        self.usedObserverOverload = true
        observer.record(StreamingPlaybackObservation(stage: .playerInstanceCreated, path: .mp3))
        observer.record(StreamingPlaybackObservation(stage: .playbackSubmissionStarted, path: .mp3))
        do {
            for try await _ in stream {}
        } catch {
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
        observer.record(StreamingPlaybackObservation(stage: .playbackSubmissionAccepted, path: .mp3))
        observer.record(StreamingPlaybackObservation(stage: .playbackCompleted, path: .mp3))
        return StreamingPlaybackResult(finished: true, interruptedAt: nil)
    }

    func stop() -> Double? { nil }
}

@MainActor
private final class TestTTSProgressRecorder {
    var values: [TalkTTSProgress] = []
    var snapshot = TalkTTSDiagnosticSnapshot()

    func record(_ progress: TalkTTSProgress) {
        self.values.append(progress)
        self.snapshot.apply(progress)
    }
}

private struct TestTTSBreadcrumbBoundary: Equatable {
    let stage: TalkTTSBreadcrumbStage
    let detail: String?
    let byteCount: Int?
    let sampleRate: Int?
    let durationRecorded: Bool

    init(
        _ stage: TalkTTSBreadcrumbStage,
        detail: String? = nil,
        byteCount: Int? = nil,
        sampleRate: Int? = nil,
        durationRecorded: Bool = false)
    {
        self.stage = stage
        self.detail = detail
        self.byteCount = byteCount
        self.sampleRate = sampleRate
        self.durationRecorded = durationRecorded
    }

    init(_ breadcrumb: TalkTTSBreadcrumb) {
        self.init(
            breadcrumb.stage,
            detail: breadcrumb.detail,
            byteCount: breadcrumb.byteCount,
            sampleRate: breadcrumb.sampleRate,
            durationRecorded: breadcrumb.durationMilliseconds != nil)
    }
}

@MainActor
private final class TestTTSBreadcrumbRecorder {
    private(set) var values: [TalkTTSBreadcrumb] = []

    var boundaries: [TestTTSBreadcrumbBoundary] {
        self.values.map { TestTTSBreadcrumbBoundary($0) }
    }

    func record(_ breadcrumb: TalkTTSBreadcrumb) {
        self.values.append(breadcrumb)
    }
}

@MainActor
private final class TestGenerationState {
    var isCurrent = true
}

@MainActor
@Suite struct TalkTTSDiagnosticsTests {
    @Test func v2TTSAndRouteDiagnosticsDoNotRepurposeLegacyStreamField() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Voice/TalkModeManager.swift"),
            encoding: .utf8)
        for forbidden in [
            "stream: Self.sanitizedDiagnosticToken(self.ttsDiagnostics.config.provider",
            "stream: breadcrumb.detail",
            "stream: config.provider",
            "stream: evidence.outputPortTypes.first",
            "stream: self.ttsDiagnostics.route.outputPortTypes.first",
        ] {
            #expect(!source.contains(forbidden))
        }
    }

    @Test func structuredLifecycleRecorderBindsAttemptAndPlaybackGeneration() throws {
        let lines = TestDiagnosticLineRecorder()
        let flushes = TestLockedCounter()
        OpenClawDiagnosticRecorder.installSink { lines.append($0) }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        TalkModeManager.recordTTSLifecycleObservation(
            TalkTTSLifecycleObservation(
                stage: .providerResponseReceived,
                provider: "elevenlabs",
                codec: "pcm",
                playbackPath: "pcm",
                providerStage: "provider_response_received",
                byteCount: 4096,
                resultClass: "success"),
            generation: 42,
            flush: { flushes.increment() })
        TalkModeManager.recordTTSPlaybackObservation(
            StreamingPlaybackObservation(stage: .playbackSubmissionAccepted, path: .pcm),
            generation: 42,
            flush: { flushes.increment() })

        let records = lines.lines().compactMap(OpenClawDiagnosticRecorder.decodeRecord)
        #expect(records.count == 2)
        let response = try #require(records.first)
        #expect(response.state == "provider_response_received")
        #expect(response.processInstanceID != nil)
        #expect(response.launchInstanceID != nil)
        #expect(response.playbackGeneration == 42)
        #expect(response.cancellationGeneration == 42)
        #expect(response.operationID == response.diagnosticAttemptID)
        #expect(response.provider == "elevenlabs")
        #expect(response.codec == "pcm")
        #expect(response.playbackPath == "pcm")
        #expect(response.byteCount == 4096)
        #expect(response.resultClass == "success")
        let submission = try #require(records.last)
        #expect(submission.state == "tts_playback_submission_accepted")
        #expect(submission.playbackGeneration == 42)
        #expect(submission.cancellationGeneration == 42)
        #expect(submission.operationID == submission.diagnosticAttemptID)
        #expect(flushes.count() == 2)
    }

    @Test func diagnosticVoiceTestsUseFixedNonSensitivePhrases() {
        #expect(TalkTTSTestPhrase.system == "OpenClaw system voice test successful.")
        #expect(TalkTTSTestPhrase.elevenLabs == "OpenClaw ElevenLabs test successful.")
    }

    @Test func talkSecretScopeEvidenceNeverIncludesSecretValues() {
        let accepted = TalkTTSConfigEvidenceBuilder.build(
            loaded: true,
            secretsAccess: .accepted,
            provider: "elevenlabs",
            modelPresent: true,
            voiceIDPresent: true,
            apiKeyPresent: true,
            credentialSource: .gatewayConfig)
        let rejected = TalkTTSConfigEvidenceBuilder.build(
            loaded: true,
            secretsAccess: .rejected,
            provider: "elevenlabs",
            modelPresent: true,
            voiceIDPresent: true,
            apiKeyPresent: false,
            credentialSource: .gatewayRuntime)
        let redacted = TalkTTSConfigEvidenceBuilder.build(
            loaded: true,
            secretsAccess: .redacted,
            provider: "elevenlabs",
            modelPresent: true,
            voiceIDPresent: false,
            apiKeyPresent: false,
            credentialSource: .none)

        #expect(accepted.operatorTalkSecrets == .present)
        #expect(accepted.credentialOwnership == .gateway)
        #expect(accepted.credentialSource == .gatewayConfig)
        #expect(rejected.operatorTalkSecrets == .absent)
        #expect(rejected.credentialOwnership == .gateway)
        #expect(redacted.operatorTalkSecrets == .unknown)
        #expect(!redacted.apiKeyPresent)
        #expect(!redacted.voiceIDPresent)
    }

    @Test func credentialSourceTracksGatewayAndClientOrigins() {
        let gatewayConfig = TalkTTSCredentialSourceResolver.resolve(
            gatewayOwnedProvider: false,
            gatewayConfigKeyPresent: true,
            localOverrideKeyPresent: false,
            debugEnvironmentKeyPresent: false)
        let localOverride = TalkTTSCredentialSourceResolver.resolve(
            gatewayOwnedProvider: false,
            gatewayConfigKeyPresent: true,
            localOverrideKeyPresent: true,
            debugEnvironmentKeyPresent: false)
        let debugEnvironment = TalkTTSCredentialSourceResolver.resolve(
            gatewayOwnedProvider: false,
            gatewayConfigKeyPresent: false,
            localOverrideKeyPresent: false,
            debugEnvironmentKeyPresent: true)

        #expect(gatewayConfig == .gatewayConfig)
        #expect(gatewayConfig.ownership == .gateway)
        #expect(localOverride == .clientLocalOverride)
        #expect(localOverride.ownership == .client)
        #expect(debugEnvironment == .clientDebugEnvironment)
        #expect(debugEnvironment.ownership == .client)

        let missingVoiceMessage = TalkTTSAvailabilityMessage.elevenLabsUnavailable(
            permissionRequired: false,
            configLoaded: true,
            apiKeyPresent: debugEnvironment.clientAPIKeyPresent,
            voiceIDPresent: false)
        #expect(missingVoiceMessage.contains("voice ID unavailable"))
        #expect(!missingVoiceMessage.contains("API key unavailable"))
    }

    @Test func noAPIKeyOrVoiceUsesExplicitSystemFallback() async {
        let fixture = Self.makeFixture()
        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: nil,
            mp3Retry: nil)

        #expect(result.succeeded)
        #expect(result.provider == .system)
        #expect(result.textPreserved)
        #expect(fixture.system.spokenTexts == ["authoritative text"])
        #expect(fixture.progress.values.contains { $0.state == .systemFallback })
        #expect(fixture.progress.values.last?.state == .completed)
    }

    @Test func ElevenLabsAPIFailureFallsBackWithoutExposingErrorProse() async {
        let fixture = Self.makeFixture()
        let apiError = NSError(
            domain: "ElevenLabsTTS",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey: "private provider response body"])
        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100", error: apiError),
            mp3Retry: Self.attempt(format: "mp3_44100_128", error: apiError))

        #expect(result.succeeded)
        #expect(result.provider == .system)
        #expect(result.textPreserved)
        #expect(fixture.pcm.stopCount == 1)
        #expect(fixture.mp3.stopCount == 1)
        #expect(fixture.progress.values.contains { $0.providerAttemptOutcome == .http5xx })
        #expect(fixture.progress.values.allSatisfy { !($0.userMessage ?? "").contains("private") })
        #expect(fixture.progress.snapshot.providerAttemptOutcome == .http5xx)
        #expect(fixture.progress.snapshot.finalProvider == .system)
        #expect(fixture.progress.snapshot.finalOutcome == .success)
        #expect(fixture.progress.snapshot.userMessage.contains("ElevenLabs failed (http_5xx)"))
        #expect(fixture.progress.snapshot.userMessage.contains("iOS voice succeeded"))
    }

    @Test func zeroAudioBytesFallsBackToSystemVoice() async {
        let fixture = Self.makeFixture()
        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100", chunks: []),
            mp3Retry: nil)

        #expect(result.succeeded)
        #expect(result.provider == .system)
        #expect(fixture.progress.values.contains { $0.providerAttemptOutcome == .zeroAudio })
        #expect(fixture.progress.values.contains { $0.totalAudioBytes == 0 })
    }

    @Test func PCMFailureRetriesMP3AndDoesNotInvokeSystemVoice() async {
        let fixture = Self.makeFixture()
        fixture.pcm.result = StreamingPlaybackResult(finished: false, interruptedAt: nil)
        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100"),
            mp3Retry: Self.attempt(format: "mp3_44100_128"))

        #expect(result.succeeded)
        #expect(result.provider == .elevenLabs)
        #expect(fixture.pcm.playCount == 1)
        #expect(fixture.mp3.playCount == 1)
        #expect(fixture.pcm.stopCount == 1)
        #expect(fixture.mp3.stopCount == 0)
        #expect(fixture.system.spokenTexts.isEmpty)
        #expect(fixture.progress.values.contains { $0.state == .mp3Retry })
    }

    @Test func PCMAndMP3FailureFallsBackToSystemVoice() async {
        let fixture = Self.makeFixture()
        fixture.pcm.result = StreamingPlaybackResult(finished: false, interruptedAt: nil)
        fixture.mp3.result = StreamingPlaybackResult(finished: false, interruptedAt: nil)
        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100"),
            mp3Retry: Self.attempt(format: "mp3_44100_128"))

        #expect(result.succeeded)
        #expect(result.provider == .system)
        #expect(result.textPreserved)
        #expect(fixture.system.spokenTexts.count == 1)
        #expect(fixture.pcm.stopCount == 1)
        #expect(fixture.mp3.stopCount == 1)
        #expect(fixture.progress.snapshot.providerAttemptOutcome == .playbackFailed)
        #expect(fixture.progress.snapshot.finalProvider == .system)
        #expect(fixture.progress.snapshot.finalOutcome == .success)
        #expect(fixture.progress.snapshot.userMessage.contains("ElevenLabs failed (playback_failed)"))
        #expect(fixture.progress.snapshot.userMessage.contains("iOS voice succeeded"))
    }

    @Test func ElevenLabsAndSystemVoiceFailurePreservesTextAndReportsFailure() async {
        let fixture = Self.makeFixture()
        fixture.pcm.result = StreamingPlaybackResult(finished: false, interruptedAt: nil)
        fixture.system.error = NSError(domain: "SystemSpeech", code: 1)
        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100"),
            mp3Retry: nil)

        #expect(!result.succeeded)
        #expect(result.textPreserved)
        #expect(result.provider == .system)
        #expect(fixture.progress.values.last?.state == .failed)
        #expect(fixture.progress.values.last?.userMessage == "Speech failed — text reply preserved.")
        #expect(fixture.progress.snapshot.providerAttemptOutcome == .playbackFailed)
        #expect(fixture.progress.snapshot.finalProvider == .system)
        #expect(fixture.progress.snapshot.finalOutcome == .playbackFailed)
    }

    @Test func externalAudioRoutesAreNeverStolenBySpeakerphonePreference() {
        let externalPorts = [
            AVAudioSession.Port.bluetoothA2DP.rawValue,
            AVAudioSession.Port.bluetoothHFP.rawValue,
            AVAudioSession.Port.headphones.rawValue,
        ]
        for port in externalPorts {
            #expect(!TalkAudioRoutePolicy.shouldOverrideToSpeaker(
                speakerphonePreferred: true,
                outputPortTypes: [port]))
        }
    }

    @Test func builtInReceiverIsAvoidedWhenSpeakerphoneIsPreferred() {
        #expect(TalkAudioRoutePolicy.shouldOverrideToSpeaker(
            speakerphonePreferred: true,
            outputPortTypes: [AVAudioSession.Port.builtInReceiver.rawValue]))
        #expect(TalkAudioRoutePolicy.shouldOverrideToSpeaker(
            speakerphonePreferred: true,
            outputPortTypes: [AVAudioSession.Port.builtInSpeaker.rawValue]))
        #expect(!TalkAudioRoutePolicy.shouldOverrideToSpeaker(
            speakerphonePreferred: false,
            outputPortTypes: [AVAudioSession.Port.builtInReceiver.rawValue]))
    }

    @Test func incrementalAudioFinalizationRecordsAllBytesAndCompletes() async {
        let fixture = Self.makeFixture()
        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(
                format: "pcm_44100",
                chunks: [Data([1, 2]), Data([3, 4, 5])]),
            mp3Retry: nil)

        #expect(result.succeeded)
        #expect(result.provider == .elevenLabs)
        #expect(fixture.pcm.receivedBytes == 5)
        #expect(fixture.pcm.stopCount == 1)
        #expect(fixture.progress.values.contains { $0.firstAudioByteReceived == true && $0.totalAudioBytes == 5 })
        #expect(fixture.progress.values.last?.state == .completed)
    }

    @Test func successfulPCMBreadcrumbsRecordExactBoundaryOrderAndMetadata() async {
        let fixture = Self.makeFixture()

        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100"),
            mp3Retry: nil)

        #expect(result.succeeded)
        let expected = [
            TestTTSBreadcrumbBoundary(.playbackPipelineEntered),
            TestTTSBreadcrumbBoundary(.audioSessionPrepareStarted),
            TestTTSBreadcrumbBoundary(
                .audioSessionPrepared,
                detail: "playandrecord_spokenaudio_active_speaker"),
            TestTTSBreadcrumbBoundary(
                .providerRequestStarted,
                detail: "pcm_44100",
                sampleRate: 44100),
            TestTTSBreadcrumbBoundary(.decoderSelected, detail: "pcm", sampleRate: 44100),
            TestTTSBreadcrumbBoundary(.playerCallEntered, detail: "pcm", sampleRate: 44100),
            TestTTSBreadcrumbBoundary(
                .firstAudioByte,
                detail: "pcm",
                byteCount: 4,
                sampleRate: 44100),
            TestTTSBreadcrumbBoundary(.playerCallReturned, detail: "finished", sampleRate: 44100),
            TestTTSBreadcrumbBoundary(
                .providerResult,
                detail: "success",
                byteCount: 4,
                sampleRate: 44100),
            TestTTSBreadcrumbBoundary(
                .playbackCompleted,
                detail: "elevenlabs",
                byteCount: 4,
                sampleRate: 44100,
                durationRecorded: true),
        ]
        #expect(fixture.breadcrumbs.boundaries == expected)
    }

    @Test func providerPipelineForwardsTruthfulPCMPlaybackObservations() async {
        let pcm = ObservedTestPCMPlayer()
        let recorder = TestStreamingPlaybackObservationRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: pcm,
            mp3Player: TestMP3Player(),
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { Self.routeEvidence },
            report: { _ in },
            playbackObserver: StreamingPlaybackObserver { recorder.record($0) })

        let result = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100"),
            mp3Retry: nil)

        #expect(result.succeeded)
        #expect(pcm.usedObserverOverload)
        #expect(recorder.observations() == [
            StreamingPlaybackObservation(stage: .playerInstanceCreated, path: .pcm),
            StreamingPlaybackObservation(stage: .playbackSubmissionStarted, path: .pcm),
            StreamingPlaybackObservation(stage: .playbackSubmissionAccepted, path: .pcm),
            StreamingPlaybackObservation(stage: .playbackCompleted, path: .pcm),
        ])
        #expect(!recorder.observations().contains { $0.stage == .firstRenderCallbackObserved })
    }

    @Test func providerPipelineDoesNotFabricateMP3DecoderOrFirstRenderObservation() async {
        let mp3 = ObservedTestMP3Player()
        let recorder = TestStreamingPlaybackObservationRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: mp3,
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { Self.routeEvidence },
            report: { _ in },
            playbackObserver: StreamingPlaybackObserver { recorder.record($0) })

        let result = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "mp3_44100_128"),
            mp3Retry: nil)

        #expect(result.succeeded)
        #expect(mp3.usedObserverOverload)
        #expect(recorder.observations() == [
            StreamingPlaybackObservation(stage: .playerInstanceCreated, path: .mp3),
            StreamingPlaybackObservation(stage: .playbackSubmissionStarted, path: .mp3),
            StreamingPlaybackObservation(stage: .playbackSubmissionAccepted, path: .mp3),
            StreamingPlaybackObservation(stage: .playbackCompleted, path: .mp3),
        ])
        #expect(!recorder.observations().contains { $0.stage == .decoderCreated })
        #expect(!recorder.observations().contains { $0.stage == .firstRenderCallbackObserved })
    }

    @Test func genericProviderStreamDoesNotClaimPayloadValidation() async {
        let lifecycle = TestTTSLifecycleObservationRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: TestMP3Player(),
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { Self.routeEvidence },
            report: { _ in },
            lifecycleObserver: { lifecycle.record($0) })

        let result = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100"),
            mp3Retry: nil)

        #expect(result.succeeded)
        let stages = lifecycle.values.map(\.stage)
        #expect(stages.contains(.providerResponseReceived))
        #expect(stages.contains(.streamFirstChunkReceived))
        #expect(stages.contains(.streamCompleted))
        #expect(!stages.contains(.audioPayloadValidated))
    }

    @Test func providerValidatedNonemptyStreamRecordsPayloadValidation() async {
        let lifecycle = TestTTSLifecycleObservationRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: TestMP3Player(),
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { Self.routeEvidence },
            report: { _ in },
            lifecycleObserver: { lifecycle.record($0) })
        let attempt = TalkTTSProviderAttempt(
            outputFormat: "pcm_44100",
            payloadValidation: .providerContentTypeValidated) {
            Self.attempt(format: "pcm_44100").makeStream()
        }

        let result = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: attempt,
            mp3Retry: nil)

        #expect(result.succeeded)
        let validation = lifecycle.values.first { $0.stage == .audioPayloadValidated }
        #expect(validation?.byteCount == 4)
        #expect(validation?.resultClass == "provider_content_type_validated_nonempty")
    }

    @Test func zeroByteResponseCompletesWithoutPayloadValidation() async {
        let lifecycle = TestTTSLifecycleObservationRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: TestMP3Player(),
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { Self.routeEvidence },
            report: { _ in },
            lifecycleObserver: { lifecycle.record($0) })
        let attempt = TalkTTSProviderAttempt(
            outputFormat: "pcm_44100",
            payloadValidation: .providerContentTypeValidated) {
            Self.attempt(format: "pcm_44100", chunks: [Data()]).makeStream()
        }

        _ = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: attempt,
            mp3Retry: nil)

        let stages = lifecycle.values.map(\.stage)
        #expect(stages.contains(.providerResponseReceived))
        #expect(stages.contains(.streamCompleted))
        #expect(!stages.contains(.audioPayloadValidated))
    }

    @Test func HTTPFailureRecordsResponseWithoutSuccessfulStreamOrPayload() async {
        let lifecycle = TestTTSLifecycleObservationRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: TestMP3Player(),
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { Self.routeEvidence },
            report: { _ in },
            lifecycleObserver: { lifecycle.record($0) })
        let failure = NSError(domain: "ElevenLabsTTS", code: 503)
        let attempt = TalkTTSProviderAttempt(
            outputFormat: "pcm_44100",
            payloadValidation: .providerContentTypeValidated) {
            Self.attempt(format: "pcm_44100", error: failure).makeStream()
        }

        _ = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: attempt,
            mp3Retry: nil)

        let response = lifecycle.values.first { $0.stage == .providerResponseReceived }
        #expect(response?.resultClass == TalkTTSProviderOutcome.http5xx.rawValue)
        let stages = lifecycle.values.map(\.stage)
        #expect(!stages.contains(.streamCompleted))
        #expect(!stages.contains(.audioPayloadValidated))
    }

    @Test func audioSessionAndSystemFallbackLifecycleIsCausallyOrdered() async {
        let lifecycle = TestTTSLifecycleObservationRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: TestMP3Player(),
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { Self.routeEvidence },
            report: { _ in },
            lifecycleObserver: { lifecycle.record($0) })

        let result = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: nil,
            mp3Retry: nil)

        #expect(result.succeeded)
        #expect(lifecycle.values.map(\.stage) == [
            .audioSessionActivationStarted,
            .audioSessionActivationSucceeded,
            .outputRouteObserved,
            .fallbackSelected,
            .fallbackStarted,
            .firstRenderCallbackObserved,
            .fallbackCompleted,
        ])
    }

    @Test func systemFirstRenderObservationRequiresDelegateStartCallback() async {
        let lifecycle = TestTTSLifecycleObservationRecorder()
        let system = TestSystemSpeech()
        system.emitsStartCallback = false
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: TestMP3Player(),
            systemSpeech: system,
            prepareAudio: { Self.routeEvidence },
            report: { _ in },
            lifecycleObserver: { lifecycle.record($0) })

        let result = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: nil,
            mp3Retry: nil)

        #expect(result.succeeded)
        #expect(!lifecycle.values.contains { $0.stage == .firstRenderCallbackObserved })
    }

    @Test func failedSystemFallbackEmitsExplicitTerminalFailure() async {
        let lifecycle = TestTTSLifecycleObservationRecorder()
        let system = TestSystemSpeech()
        system.error = NSError(domain: "SystemSpeech", code: 1)
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: TestMP3Player(),
            systemSpeech: system,
            prepareAudio: { throw NSError(domain: "AudioSession", code: 1) },
            report: { _ in },
            lifecycleObserver: { lifecycle.record($0) })

        let result = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: nil,
            mp3Retry: nil)

        #expect(!result.succeeded)
        #expect(lifecycle.values.map(\.stage) == [
            .audioSessionActivationStarted,
            .audioSessionActivationFailed,
            .fallbackSelected,
            .fallbackStarted,
            .fallbackFailed,
        ])
        #expect(lifecycle.values.last?.resultClass == "failed")
    }

    @Test func PCMToMP3ToSystemBreadcrumbsRecordEachFallbackBoundary() async {
        let fixture = Self.makeFixture()
        fixture.pcm.result = StreamingPlaybackResult(finished: false, interruptedAt: nil)
        fixture.mp3.result = StreamingPlaybackResult(finished: false, interruptedAt: nil)

        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100"),
            mp3Retry: Self.attempt(format: "mp3_44100_128"))

        #expect(result.succeeded)
        #expect(result.provider == .system)
        let expected = [
            TestTTSBreadcrumbBoundary(.playbackPipelineEntered),
            TestTTSBreadcrumbBoundary(.audioSessionPrepareStarted),
            TestTTSBreadcrumbBoundary(
                .audioSessionPrepared,
                detail: "playandrecord_spokenaudio_active_speaker"),
            TestTTSBreadcrumbBoundary(
                .providerRequestStarted,
                detail: "pcm_44100",
                sampleRate: 44100),
            TestTTSBreadcrumbBoundary(.decoderSelected, detail: "pcm", sampleRate: 44100),
            TestTTSBreadcrumbBoundary(.playerCallEntered, detail: "pcm", sampleRate: 44100),
            TestTTSBreadcrumbBoundary(
                .firstAudioByte,
                detail: "pcm",
                byteCount: 4,
                sampleRate: 44100),
            TestTTSBreadcrumbBoundary(.playerCallReturned, detail: "incomplete", sampleRate: 44100),
            TestTTSBreadcrumbBoundary(
                .providerResult,
                detail: "playback_failed",
                byteCount: 4,
                sampleRate: 44100),
            TestTTSBreadcrumbBoundary(.fallbackTransition, detail: "pcm_to_mp3"),
            TestTTSBreadcrumbBoundary(.providerRequestStarted, detail: "mp3_44100_128"),
            TestTTSBreadcrumbBoundary(.decoderSelected, detail: "mp3"),
            TestTTSBreadcrumbBoundary(.playerCallEntered, detail: "mp3"),
            TestTTSBreadcrumbBoundary(.firstAudioByte, detail: "mp3", byteCount: 4),
            TestTTSBreadcrumbBoundary(.playerCallReturned, detail: "incomplete"),
            TestTTSBreadcrumbBoundary(
                .providerResult,
                detail: "playback_failed",
                byteCount: 4),
            TestTTSBreadcrumbBoundary(.fallbackTransition, detail: "mp3_to_system"),
            TestTTSBreadcrumbBoundary(.systemSpeechCallEntered, detail: "playback_failed"),
            TestTTSBreadcrumbBoundary(.playbackStarted, detail: "system"),
            TestTTSBreadcrumbBoundary(
                .playbackCompleted,
                detail: "system",
                durationRecorded: true),
        ]
        #expect(fixture.breadcrumbs.boundaries == expected)
    }

    @Test func audioPrepareFailureBreadcrumbsPrecedeSystemFallback() async {
        let breadcrumbs = TestTTSBreadcrumbRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: TestMP3Player(),
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { throw NSError(domain: "AudioSession", code: 1) },
            report: { _ in },
            breadcrumb: { breadcrumbs.record($0) })

        let result = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100"),
            mp3Retry: Self.attempt(format: "mp3_44100_128"))

        #expect(result.succeeded)
        #expect(result.provider == .system)
        let expected = [
            TestTTSBreadcrumbBoundary(.playbackPipelineEntered),
            TestTTSBreadcrumbBoundary(.audioSessionPrepareStarted),
            TestTTSBreadcrumbBoundary(.audioSessionPrepareFailed),
            TestTTSBreadcrumbBoundary(.fallbackTransition, detail: "audio_session_to_system"),
            TestTTSBreadcrumbBoundary(.systemSpeechCallEntered, detail: "direct"),
            TestTTSBreadcrumbBoundary(.playbackStarted, detail: "system"),
            TestTTSBreadcrumbBoundary(
                .playbackCompleted,
                detail: "system",
                durationRecorded: true),
        ]
        #expect(breadcrumbs.boundaries == expected)
    }

    @Test func systemSpeechFailureBreadcrumbsEndAtPlaybackFailure() async {
        let fixture = Self.makeFixture()
        fixture.system.error = NSError(domain: "SystemSpeech", code: 1)

        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: nil,
            mp3Retry: nil)

        #expect(!result.succeeded)
        #expect(result.outcome == .playbackFailed)
        let expected = [
            TestTTSBreadcrumbBoundary(.playbackPipelineEntered),
            TestTTSBreadcrumbBoundary(.audioSessionPrepareStarted),
            TestTTSBreadcrumbBoundary(
                .audioSessionPrepared,
                detail: "playandrecord_spokenaudio_active_speaker"),
            TestTTSBreadcrumbBoundary(.fallbackTransition, detail: "provider_unavailable_to_system"),
            TestTTSBreadcrumbBoundary(.systemSpeechCallEntered, detail: "direct"),
            TestTTSBreadcrumbBoundary(.playbackStarted, detail: "system"),
            TestTTSBreadcrumbBoundary(
                .playbackFailed,
                detail: "system",
                durationRecorded: true),
        ]
        #expect(fixture.breadcrumbs.boundaries == expected)
    }

    @Test func cancelledSystemSpeechDoesNotEmitFalseTerminalBreadcrumb() async {
        let system = SuspendedSystemSpeech()
        let breadcrumbs = TestTTSBreadcrumbRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: TestPCMPlayer(),
            mp3Player: TestMP3Player(),
            systemSpeech: system,
            prepareAudio: { Self.routeEvidence },
            report: { _ in },
            breadcrumb: { breadcrumbs.record($0) })
        let playback = Task { @MainActor in
            await pipeline.speak(
                text: "authoritative text",
                language: nil,
                providerAttempt: nil,
                mp3Retry: nil)
        }

        await system.waitForCallCount(1)
        playback.cancel()
        system.complete(callID: 1)
        let result = await playback.value

        #expect(!result.succeeded)
        #expect(result.outcome == .interrupted)
        let expected = [
            TestTTSBreadcrumbBoundary(.playbackPipelineEntered),
            TestTTSBreadcrumbBoundary(.audioSessionPrepareStarted),
            TestTTSBreadcrumbBoundary(
                .audioSessionPrepared,
                detail: "playandrecord_spokenaudio_active_speaker"),
            TestTTSBreadcrumbBoundary(.fallbackTransition, detail: "provider_unavailable_to_system"),
            TestTTSBreadcrumbBoundary(.systemSpeechCallEntered, detail: "direct"),
            TestTTSBreadcrumbBoundary(.playbackStarted, detail: "system"),
        ]
        #expect(breadcrumbs.boundaries == expected)
    }

    @Test func staleSuccessfulSpeechCannotCompleteOrOverwriteReplacement() async {
        let generation = TestGenerationState()
        let fixture = Self.makeFixture(isCurrent: { generation.isCurrent })
        fixture.pcm.afterPlay = { generation.isCurrent = false }
        let result = await fixture.pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: Self.attempt(format: "pcm_44100"),
            mp3Retry: Self.attempt(format: "mp3_44100_128"))

        #expect(!result.succeeded)
        #expect(result.outcome == .interrupted)
        #expect(result.textPreserved)
        #expect(fixture.mp3.playCount == 0)
        #expect(fixture.system.spokenTexts.isEmpty)
        #expect(!fixture.progress.values.contains { $0.state == .completed || $0.state == .failed })
    }

    @Test func staleManagerGenerationCannotFinalizeReplacementSpeech() async {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let system = SuspendedSystemSpeech()
        manager.systemSpeech = system
        manager.pcmPlayer = TestPCMPlayer()
        manager.mp3Player = TestMP3Player()
        var restoreCount = 0
        manager._test_setTTSAudioHooks(
            prepare: { Self.routeEvidence },
            restore: { restoreCount += 1 })

        let first = Task { @MainActor in
            await manager.speakSystemNotificationText("first")
        }
        await system.waitForCallCount(1)
        let firstGeneration = manager._test_ttsGeneration()

        let replacement = Task { @MainActor in
            await manager.speakSystemNotificationText("replacement")
        }
        await system.waitForCallCount(2)
        let replacementGeneration = manager._test_ttsGeneration()
        let replacementDescriptor = manager.gatewayTalkVoiceModeTitle

        #expect(replacementGeneration != firstGeneration)
        #expect(manager.isSpeaking)
        #expect(manager.ttsState == .speaking)

        system.complete(callID: 1)
        await first.value

        #expect(manager._test_ttsGeneration() == replacementGeneration)
        #expect(manager.isSpeaking)
        #expect(manager.ttsState == .speaking)
        #expect(manager.gatewayTalkVoiceModeTitle == replacementDescriptor)
        #expect(restoreCount == 0)

        system.complete(callID: 2)
        await replacement.value

        #expect(!manager.isSpeaking)
        #expect(manager.ttsState == .completed)
        #expect(restoreCount == 1)
    }

    @Test func replacedIncrementalTaskCannotStartOrTearDownReplacementSpeech() async throws {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let system = SuspendedSystemSpeech()
        let preSpeak = SuspendedIncrementalPreSpeak()
        manager.systemSpeech = system
        manager.pcmPlayer = TestPCMPlayer()
        manager.mp3Player = TestMP3Player()
        var restoreCount = 0
        manager._test_setTTSAudioHooks(
            prepare: { Self.routeEvidence },
            restore: { restoreCount += 1 })
        manager._test_setIncrementalSpeechBeforeSpeakHook { generation in
            await preSpeak.suspendFirst(generation: generation)
        }

        manager._test_startIncrementalSpeech("first")
        let firstTask = try #require(manager._test_incrementalSpeechTaskHandle())
        await preSpeak.waitUntilEntered()
        let firstTaskGeneration = manager._test_incrementalSpeechTaskGeneration()

        manager._test_startIncrementalSpeech("replacement")
        let replacementTask = try #require(manager._test_incrementalSpeechTaskHandle())
        await system.waitForCallCount(1)
        let replacementTaskGeneration = manager._test_incrementalSpeechTaskGeneration()
        let replacementTTSGeneration = manager._test_ttsGeneration()
        let stopCountAfterReplacementStarted = system.stopCount

        #expect(replacementTaskGeneration != firstTaskGeneration)
        #expect(manager.isSpeaking)
        #expect(manager._test_hasIncrementalSpeechTask())

        preSpeak.release()
        await firstTask.value

        #expect(system.callCount == 1)
        #expect(system.stopCount == stopCountAfterReplacementStarted)
        #expect(manager._test_incrementalSpeechTaskGeneration() == replacementTaskGeneration)
        #expect(manager._test_ttsGeneration() == replacementTTSGeneration)
        #expect(manager.isSpeaking)
        #expect(manager._test_hasIncrementalSpeechTask())
        #expect(restoreCount == 0)

        system.complete(callID: 1)
        await replacementTask.value

        #expect(!manager.isSpeaking)
        #expect(!manager._test_hasIncrementalSpeechTask())
        #expect(restoreCount == 1)
    }

    @Test func resettingIncrementalSpeechImmediatelyStopsOwnedPlayback() async throws {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let system = SuspendedSystemSpeech()
        let pcm = TestPCMPlayer()
        let mp3 = TestMP3Player()
        manager.systemSpeech = system
        manager.pcmPlayer = pcm
        manager.mp3Player = mp3
        var restoreCount = 0
        manager._test_setTTSAudioHooks(
            prepare: { Self.routeEvidence },
            restore: { restoreCount += 1 })

        manager._test_startIncrementalSpeech("first")
        let firstTask = try #require(manager._test_incrementalSpeechTaskHandle())
        await system.waitForCallCount(1)
        let firstTTSGeneration = manager._test_ttsGeneration()
        let systemStopsBeforeReset = system.stopCount
        let pcmStopsBeforeReset = pcm.stopCount
        let mp3StopsBeforeReset = mp3.stopCount

        manager._test_startIncrementalSpeech("replacement")
        let replacementTask = try #require(manager._test_incrementalSpeechTaskHandle())

        #expect(manager._test_ttsGeneration() != firstTTSGeneration)
        #expect(system.stopCount == systemStopsBeforeReset + 1)
        #expect(pcm.stopCount == pcmStopsBeforeReset + 1)
        #expect(mp3.stopCount == mp3StopsBeforeReset + 1)
        #expect(manager.ttsState == .failed)
        #expect(manager.ttsDiagnostics.finalProvider == .system)
        #expect(manager.ttsDiagnostics.finalOutcome == .interrupted)
        #expect(manager.ttsDiagnostics.userMessage == "Speech interrupted — text reply preserved.")
        #expect(restoreCount == 1)

        await system.waitForCallCount(2)
        let replacementTaskGeneration = manager._test_incrementalSpeechTaskGeneration()
        let replacementTTSGeneration = manager._test_ttsGeneration()
        let stopsAfterReplacementStarted = system.stopCount

        system.complete(callID: 1)
        await firstTask.value

        #expect(system.callCount == 2)
        #expect(system.stopCount == stopsAfterReplacementStarted)
        #expect(manager._test_incrementalSpeechTaskGeneration() == replacementTaskGeneration)
        #expect(manager._test_ttsGeneration() == replacementTTSGeneration)
        #expect(manager.isSpeaking)
        #expect(manager._test_hasIncrementalSpeechTask())
        #expect(restoreCount == 1)

        system.complete(callID: 2)
        await replacementTask.value

        #expect(!manager.isSpeaking)
        #expect(!manager._test_hasIncrementalSpeechTask())
        #expect(restoreCount == 2)
    }

    @Test func interruptionTimestampUsesAdmittedPCMPlayerAndRecordsOutcome() {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let pcm = TestPCMPlayer()
        let mp3 = TestMP3Player()
        pcm.stopResult = 12.5
        mp3.stopResult = 44
        manager.pcmPlayer = pcm
        manager.mp3Player = mp3
        manager.systemSpeech = TestSystemSpeech()

        manager._test_setSpeakingPlaybackFormat("pcm_44100")
        manager._test_stopSpeaking()

        #expect(manager._test_lastInterruptedAtSeconds() == 12.5)
        #expect(pcm.stopCount == 1)
        #expect(mp3.stopCount == 1)
        #expect(manager.ttsState == .failed)
        #expect(manager.ttsDiagnostics.providerAttemptOutcome == .interrupted)
        #expect(manager.ttsDiagnostics.finalProvider == .elevenLabs)
        #expect(manager.ttsDiagnostics.finalOutcome == .interrupted)
        #expect(manager.ttsDiagnostics.userMessage == "Speech interrupted — text reply preserved.")
    }

    @Test func interruptionTimestampUsesAdmittedMP3Player() {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let pcm = TestPCMPlayer()
        let mp3 = TestMP3Player()
        pcm.stopResult = 12.5
        mp3.stopResult = 44
        manager.pcmPlayer = pcm
        manager.mp3Player = mp3
        manager.systemSpeech = TestSystemSpeech()

        manager._test_setSpeakingPlaybackFormat("mp3_44100_128")
        manager._test_stopSpeaking()

        #expect(manager._test_lastInterruptedAtSeconds() == 44)
        #expect(pcm.stopCount == 1)
        #expect(mp3.stopCount == 1)
        #expect(manager.ttsDiagnostics.providerAttemptOutcome == .interrupted)
        #expect(manager.ttsDiagnostics.finalProvider == .elevenLabs)
        #expect(manager.ttsDiagnostics.finalOutcome == .interrupted)
    }

    @Test func systemInterruptionRecordsSystemProviderWithoutFakePlayerTimestamp() {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        let pcm = TestPCMPlayer()
        let mp3 = TestMP3Player()
        pcm.stopResult = 12.5
        mp3.stopResult = 44
        manager.pcmPlayer = pcm
        manager.mp3Player = mp3
        manager.systemSpeech = TestSystemSpeech()

        manager._test_setSpeakingPlaybackFormat(nil)
        manager._test_stopSpeaking()

        #expect(manager._test_lastInterruptedAtSeconds() == nil)
        #expect(pcm.stopCount == 1)
        #expect(mp3.stopCount == 1)
        #expect(manager.ttsDiagnostics.providerAttemptOutcome == .notAttempted)
        #expect(manager.ttsDiagnostics.finalProvider == .system)
        #expect(manager.ttsDiagnostics.finalOutcome == .interrupted)
    }

    @Test func stalePCMReaderDropsLateChunkAfterPlaybackStop() async {
        let generation = TestGenerationState()
        let pcm = LeakyStopPCMPlayer()
        let source = ControlledAudioStream()
        let progress = TestTTSProgressRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: pcm,
            mp3Player: TestMP3Player(),
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { Self.routeEvidence },
            isCurrent: { generation.isCurrent },
            report: { progress.record($0) })
        let playback = Task { @MainActor in
            await pipeline.speak(
                text: "authoritative text",
                language: nil,
                providerAttempt: TalkTTSProviderAttempt(outputFormat: "pcm_44100") { source.stream },
                mp3Retry: nil)
        }

        await pcm.waitUntilReaderStarted()
        generation.isCurrent = false
        _ = pcm.stop()
        let result = await playback.value

        source.yield(Data([1, 2, 3, 4]))
        source.finish()
        await pcm.waitUntilReaderFinished()

        #expect(result.outcome == .interrupted)
        #expect(pcm.receivedBytes == 0)
        #expect(!progress.values.contains { $0.firstAudioByteReceived == true })
    }

    @Test func failedPCMIsStoppedAndItsLateReaderCannotOverlapSystemFallback() async {
        let pcm = EarlyFailLeakyPCMPlayer()
        let source = ControlledAudioStream()
        let progress = TestTTSProgressRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: pcm,
            mp3Player: TestMP3Player(),
            systemSpeech: TestSystemSpeech(),
            prepareAudio: { Self.routeEvidence },
            report: { progress.record($0) })

        let result = await pipeline.speak(
            text: "authoritative text",
            language: nil,
            providerAttempt: TalkTTSProviderAttempt(outputFormat: "pcm_44100") { source.stream },
            mp3Retry: nil)

        #expect(result.succeeded)
        #expect(result.provider == .system)
        #expect(pcm.stopCount == 1)

        source.yield(Data([1, 2, 3, 4]))
        source.finish()
        await pcm.waitUntilReaderFinished()

        #expect(pcm.receivedBytes == 0)
        #expect(progress.snapshot.providerAttemptOutcome == .playbackFailed)
        #expect(progress.snapshot.finalProvider == .system)
        #expect(progress.snapshot.finalOutcome == .success)
    }

    private static func makeFixture(
        isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) -> (
            pipeline: TalkTTSPlaybackPipeline,
            pcm: TestPCMPlayer,
            mp3: TestMP3Player,
            system: TestSystemSpeech,
            progress: TestTTSProgressRecorder,
            breadcrumbs: TestTTSBreadcrumbRecorder)
    {
        let pcm = TestPCMPlayer()
        let mp3 = TestMP3Player()
        let system = TestSystemSpeech()
        let progress = TestTTSProgressRecorder()
        let breadcrumbs = TestTTSBreadcrumbRecorder()
        let pipeline = TalkTTSPlaybackPipeline(
            pcmPlayer: pcm,
            mp3Player: mp3,
            systemSpeech: system,
            prepareAudio: {
                TalkAudioRouteEvidence(
                    outputPortTypes: [AVAudioSession.Port.builtInSpeaker.rawValue],
                    outputNames: ["iPhone Speaker"],
                    speakerphonePreferred: true,
                    category: AVAudioSession.Category.playAndRecord.rawValue,
                    mode: AVAudioSession.Mode.spokenAudio.rawValue,
                    activation: .active)
            },
            isCurrent: isCurrent,
            report: { progress.record($0) },
            breadcrumb: { breadcrumbs.record($0) })
        return (pipeline, pcm, mp3, system, progress, breadcrumbs)
    }

    private static var routeEvidence: TalkAudioRouteEvidence {
        TalkAudioRouteEvidence(
            outputPortTypes: [AVAudioSession.Port.builtInSpeaker.rawValue],
            outputNames: ["iPhone Speaker"],
            speakerphonePreferred: true,
            category: AVAudioSession.Category.playAndRecord.rawValue,
            mode: AVAudioSession.Mode.spokenAudio.rawValue,
            activation: .active)
    }

    private static func attempt(
        format: String,
        chunks: [Data] = [Data([1, 2, 3, 4])],
        error: Error? = nil) -> TalkTTSProviderAttempt
    {
        TalkTTSProviderAttempt(outputFormat: format) {
            AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }
}
