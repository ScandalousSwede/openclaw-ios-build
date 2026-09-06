import AVFAudio
import Foundation
import Observation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import OSLog
import Speech

struct TalkDurableChatRequest: Equatable, Sendable {
    let rawCommandID: String
    let stableGatewayID: String
    let sessionKey: String
    let message: String
    let thinkingLevel: String
    let destructiveSessionAdmissionToken: UUID
    let captureRouteSnapshot: OpenClawChatOutboxRouteSnapshot
}

struct TalkDurableChatPersistence: Sendable {
    let request: TalkDurableChatRequest
    let ownerGeneration: UInt64
    let owner: OpenClawChatOutboxDeliveryOwner
    let gatewayEvents: AsyncStream<EventFrame>
    let incrementalEvents: AsyncStream<EventFrame>
    let outboxUpdates: AsyncStream<OpenClawChatOutboxDeliveryUpdate>
}

enum TalkGatewayConfigAvailabilityState: String, Equatable {
    case notRequested = "not_requested"
    case loading
    case loaded
    case missingOnServer = "missing_on_server"
    case scopeBlocked = "scope_blocked"
    case failed
}

// This file intentionally centralizes talk mode state + behavior.
// It's large, and splitting would force `private` -> `fileprivate` across many members.
// We'll refactor into smaller files when the surface stabilizes.
// swiftlint:disable type_body_length file_length
@MainActor
@Observable
final class TalkModeManager: NSObject {
    private typealias SpeechRequest = SFSpeechAudioBufferRecognitionRequest
    private typealias SpeechPresentationValidator = @MainActor @Sendable () async -> Bool
    private static let defaultModelIdFallback = "eleven_v3"
    private static let defaultRealtimeModelIdFallback = "gpt-realtime-2"
    private static let defaultTalkProvider = "elevenlabs"
    private static let defaultSilenceTimeoutMs = TalkDefaults.silenceTimeoutMs
    private static let redactedConfigSentinel = "__OPENCLAW_REDACTED__"
    private static let realtimePrefetchExpiryLeewaySeconds: TimeInterval = 30
    var isEnabled: Bool = false
    var isListening: Bool = false
    var isSpeaking: Bool = false
    var isUserSpeechDetected: Bool = false
    var isPushToTalkActive: Bool = false
    var statusText: String = "Off"
    /// 0..1-ish (not calibrated). Intended for UI feedback only.
    var micLevel: Double = 0
    var gatewayTalkConfigLoaded: Bool = false
    var gatewayTalkConfigAvailabilityState: TalkGatewayConfigAvailabilityState = .notRequested
    var gatewayTalkApiKeyConfigured: Bool = false
    var gatewayTalkDefaultModelId: String?
    var gatewayTalkDefaultVoiceId: String?
    var gatewayTalkProviderLabel: String = "Not loaded"
    var gatewayTalkTransportLabel: String = "Not loaded"
    var gatewayTalkUsesRealtime: Bool = false
    var gatewayTalkUsesRealtimeRelay: Bool = false
    var gatewayTalkRealtimeProviderLabel: String?
    var gatewayTalkRealtimeModelId: String?
    var gatewayTalkRealtimeVoiceId: String?
    var gatewayTalkVoiceModeTitle: String = "Not loaded"
    var gatewayTalkVoiceModeSubtitle: String?
    var gatewayTalkVoiceModeAccessibilityValue: String = "Not loaded"
    var gatewayTalkPermissionState: TalkGatewayPermissionState = .unknown
    var ttsDiagnostics = TalkTTSDiagnosticSnapshot()

    var ttsState: TalkTTSState {
        self.ttsDiagnostics.state
    }

    var currentAudioRouteEvidence: TalkAudioRouteEvidence {
        Self.audioRouteEvidence(
            speakerphonePreferred: TalkDefaults.speakerphoneEnabled(),
            activation: self.currentAudioActivation)
    }

    var isGatewayConnected: Bool {
        self.gatewayConnected
    }

    var hasActiveAudioCapture: Bool {
        self.isEnabled || self.isListening || self.isPushToTalkActive || self.realtimeRelaySession != nil
            || self.realtimeRelayStartInFlight || self.pttStartReservationID != nil
    }

    var canUseBackgroundTalkOptIn: Bool {
        !self.isStarting && self.pttStartReservationID == nil && self.pendingDurableChat == nil &&
            !self.isPushToTalkActive && self.activePTTCaptureId == nil && self.pttEndTask == nil &&
            self.durableResponseTask == nil && self.durableResponseSpeechGeneration == nil &&
            !self.isPersistingDurableMessage
    }

    private enum CaptureMode {
        case idle
        case continuous
        case pushToTalk
    }

    private var isStarting = false
    private var startAttemptID = 0
    private var captureMode: CaptureMode = .idle
    private var foregroundAudioCaptureAllowed = true
    private var resumeContinuousAfterPTT: Bool = false
    private var pttStartReservationID: UUID?
    private var activePTTCaptureId: String?
    private var pttAutoStopEnabled: Bool = false
    private var pttCompletion: CheckedContinuation<OpenClawTalkPTTStopPayload, Never>?
    private var pttTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var pttEndTask: Task<OpenClawTalkPTTStopPayload, Never>?
    private var pttEndID: UUID?
    private struct PTTEndAdmission {
        let endID: UUID
        let captureID: String
        let deliveryGeneration: UInt64
        let transcriptGeneration: UInt64
    }

    private let allowSimulatorCapture: Bool

    private let audioEngine = AVAudioEngine()
    private var inputTapInstalled = false
    private var audioTapDiagnostics: AudioTapDiagnostics?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionCallbackGeneration: UInt64 = 0
    private var silenceTask: Task<Void, Never>?
    private var silenceMonitorGeneration: UInt64 = 0
    private var pttTimeoutGeneration: UInt64 = 0
    private var realtimeSession: TalkRealtimeWebRTCSession?
    private var realtimeRelaySession: RealtimeTalkRelaySession?
    private var realtimeRelayGeneration: UInt64 = 0
    private var activeRealtimeRelayGeneration: UInt64?
    private var realtimeRelayStartInFlight = false
    private var prefetchedRealtimeSession: TalkRealtimeClientSession?
    private var realtimePrefetchTask: Task<Void, Never>?
    private var realtimePrefetchGeneration: UInt64 = 0

    private var lastHeard: Date?
    private var lastTranscript: String = ""
    private var transcriptGeneration: UInt64 = 0
    private var loggedPartialThisCycle: Bool = false
    private var lastSpokenText: String?
    private var lastInterruptedAtSeconds: Double?

    private var defaultVoiceId: String?
    private var currentVoiceId: String?
    private var defaultModelId: String?
    private var currentModelId: String?
    private var voiceOverrideActive = false
    private var modelOverrideActive = false
    private var defaultOutputFormat: String?
    private var activeTalkProvider: String = TalkModeManager.defaultTalkProvider
    private var executionMode: TalkModeExecutionMode = .native
    private var realtimeWebRTCEnabled: Bool = false
    private var realtimeProvider: String?
    private var realtimeModelId: String?
    private var realtimeVoiceId: String?
    private var configuredVoiceModeDescriptor = TalkVoiceModeDescriptor(
        title: "Not loaded",
        subtitle: nil,
        providerId: nil,
        modelId: nil,
        voiceId: nil,
        transport: nil,
        isRealtime: false)
    private var apiKey: String?
    private var voiceAliases: [String: String] = [:]
    private var interruptOnSpeech: Bool = true
    private var gatewaySpeechLocaleID: String?
    private var mainSessionKey: String = "main"
    private var fallbackVoiceId: String?
    private var lastPlaybackWasPCM: Bool = false
    private var currentPlaybackProvider: TalkTTSPlaybackProvider = .none
    /// Set when the ElevenLabs API rejects PCM format (e.g. 403 subscription_required).
    /// Once set, all subsequent requests in this session use MP3 instead of re-trying PCM.
    private var pcmFormatUnavailable: Bool = false
    var pcmPlayer: PCMStreamingAudioPlaying = PCMStreamingAudioPlayer.shared
    var mp3Player: StreamingAudioPlaying = StreamingAudioPlayer.shared
    var systemSpeech: TalkSystemSpeechProviding = TalkSystemSpeechSynthesizer.shared
    private var ttsGeneration: UInt64 = 0
    private var activeTTSGeneration: UInt64?
    private var currentAudioActivation: TalkAudioRouteEvidence.Activation = .unknown
    private var audioSessionOwnerGeneration: UInt64?
    private var audioRouteObserver: NSObjectProtocol?
    private var audioInterruptionObserver: NSObjectProtocol?
    private var audioMediaServicesLostObserver: NSObjectProtocol?
    private var audioMediaServicesResetObserver: NSObjectProtocol?
    private var durableChatGatewayOwnerID: (@MainActor () -> String?)?
    private var durableChatCaptureAdmission:
        (@MainActor () async throws -> OpenClawChatOutboxCaptureAdmission)?
    private var durableChatCaptureAdmissionToken: (@MainActor () async throws -> UUID)?
    private var durableChatCaptureAdmissionIsCurrent:
        (@MainActor (_ stableGatewayID: String, _ token: UUID) async -> Bool)?
    private var durableChatPersist: (@MainActor (TalkDurableChatRequest) async throws -> TalkDurableChatPersistence)?
    private struct DurableCaptureContext {
        let rawCommandID: String
        let stableGatewayID: String
        let sessionKey: String
        let deliveryGeneration: UInt64
        let responseAdmissionGeneration: UInt64
        let destructiveSessionAdmissionToken: UUID
        let captureRouteSnapshot: OpenClawChatOutboxRouteSnapshot
    }
    private struct ContinuousStartAdmission {
        let attemptID: Int
        let stableGatewayID: String
        let sessionKey: String
        let deliveryGeneration: UInt64
        let destructiveSessionAdmissionToken: UUID?
    }
    private struct PendingDurableChat {
        let request: TalkDurableChatRequest
        let transcript: String
        let captureGeneration: UInt64
        let deliveryGeneration: UInt64
        let responseAdmissionGeneration: UInt64
        let restartAfter: Bool
    }
    private struct PersistedDurableChat {
        let persistence: TalkDurableChatPersistence
        let responseAdmissionGeneration: UInt64
        let allowsPresentation: Bool
        let wasPurgedByCredentialReset: Bool
        let restartAfter: Bool
    }
    private var durableCaptureContext: DurableCaptureContext?
    private var pendingDurableChat: PendingDurableChat?
    var isPersistingDurableMessage = false
    private var durableDeliveryGeneration: UInt64 = 0
    private var durableResponseGeneration: UInt64 = 0
    private var durableResponseSpeechGeneration: UInt64?
    @ObservationIgnored private nonisolated(unsafe) var durableResponseTask: Task<Void, Never>?
    #if DEBUG
    private var pttMicrophonePermissionOverride: (() async -> Bool)?
    private var pttSpeechPermissionOverride: (() async -> Bool)?
    private var ttsPrepareAudioOverride: (() throws -> TalkAudioRouteEvidence)?
    private var ttsRestoreAudioOverride: (() -> Void)?
    private var incrementalSpeechBeforeSpeakOverride: ((UInt64) async -> Void)?
    private var durableEventObservedOverride: (@Sendable (_ runID: String?, _ matched: Bool) -> Void)?
    private var durableResponseExitedOverride: (@Sendable (_ generation: UInt64) -> Void)?
    private var pttEndBeforeBodyOverride: (() async -> Void)?
    private var durablePresentationBeforePlaybackOverride: (() async -> Void)?
    #endif

    private var gateway: GatewayNodeSession?
    private var gatewayConnected = false
    private var talkConfigLoadedAt: Date?
    private var silenceWindow: TimeInterval = .init(TalkModeManager.defaultSilenceTimeoutMs) / 1000
    private var lastAudioActivity: Date?
    private var noiseFloorSamples: [Double] = []
    private var noiseFloor: Double?
    private var noiseFloorReady: Bool = false

    private var chatSubscribedSessionKeys = Set<String>()
    private var incrementalSpeechQueue: [String] = []
    private var incrementalSpeechTask: Task<Void, Never>?
    private var incrementalSpeechTaskGeneration: UInt64 = 0
    private var incrementalSpeechPlaybackGeneration: UInt64?
    private var incrementalSpeechActive = false
    private var incrementalSpeechUsed = false
    private var incrementalSpeechLanguage: String?
    private var incrementalSpeechBuffer = IncrementalSpeechBuffer()
    private var incrementalSpeechContext: IncrementalSpeechContext?
    private var incrementalSpeechDirective: TalkDirective?
    private var incrementalSpeechPresentationValidator: SpeechPresentationValidator?
    private var incrementalSpeechPrefetch: IncrementalSpeechPrefetchState?
    private var incrementalSpeechPrefetchMonitorTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "ai.openclaw", category: "TalkMode")

    private static func nowSeconds() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        max(0, Int((self.nowSeconds() - start) * 1000))
    }

    init(allowSimulatorCapture: Bool = false) {
        self.allowSimulatorCapture = allowSimulatorCapture
        super.init()
        self.audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main,
            using: { [weak self] notification in
                let reasonValue =
                    (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
                let previousPortTypes = (
                    notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                        as? AVAudioSessionRouteDescription
                )?.outputs.map { $0.portType.rawValue }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handleAudioRouteChange(
                        reasonValue: reasonValue,
                        previousPortTypes: previousPortTypes,
                        // AVAudioSession does not expose the operation that emitted a
                        // notification. Preserve active/owner state separately, but do
                        // not fabricate a causal callback generation.
                        callbackGeneration: nil)
                }
            })
        self.audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main,
            using: { [weak self] notification in
                let typeValue =
                    (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 2
                let reasonValue =
                    notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                let optionValue =
                    (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handleAudioSessionInterruption(
                        typeValue: typeValue,
                        reasonValue: reasonValue,
                        optionValue: optionValue,
                        callbackGeneration: nil)
                }
            })
        self.audioMediaServicesLostObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil,
            queue: .main,
            using: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handleAudioMediaServicesNotification(
                        reset: false,
                        callbackGeneration: nil)
                }
            })
        self.audioMediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main,
            using: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handleAudioMediaServicesNotification(
                        reset: true,
                        callbackGeneration: nil)
                }
            })
    }

    @MainActor deinit {
        if let audioRouteObserver {
            NotificationCenter.default.removeObserver(audioRouteObserver)
        }
        if let audioInterruptionObserver {
            NotificationCenter.default.removeObserver(audioInterruptionObserver)
        }
        if let audioMediaServicesLostObserver {
            NotificationCenter.default.removeObserver(audioMediaServicesLostObserver)
        }
        if let audioMediaServicesResetObserver {
            NotificationCenter.default.removeObserver(audioMediaServicesResetObserver)
        }
    }

    func attachGateway(_ gateway: GatewayNodeSession) {
        self.gateway = gateway
    }

    func attachDurableChatOutbox(
        gatewayOwnerID: @escaping @MainActor () -> String?,
        captureAdmission:
            @escaping @MainActor () async throws -> OpenClawChatOutboxCaptureAdmission,
        captureAdmissionToken: (@MainActor () async throws -> UUID)? = nil,
        captureAdmissionIsCurrent:
            (@MainActor (_ stableGatewayID: String, _ token: UUID) async -> Bool)? = nil,
        persist: @escaping @MainActor (TalkDurableChatRequest) async throws -> TalkDurableChatPersistence)
    {
        self.durableChatGatewayOwnerID = gatewayOwnerID
        self.durableChatCaptureAdmission = captureAdmission
        self.durableChatCaptureAdmissionToken = captureAdmissionToken
        self.durableChatCaptureAdmissionIsCurrent = captureAdmissionIsCurrent
        self.durableChatPersist = persist
    }

    var hasPendingDurableMessage: Bool {
        self.pendingDurableChat != nil
    }

    var pendingDurableCommandID: String? {
        self.pendingDurableChat?.request.rawCommandID
    }

    func invalidateDurableChatDeliveryOwner() {
        self.cancelDurableResponse()
        if self.pendingDurableChat == nil, self.statusText.hasPrefix("Queued") {
            self.statusText = "Queued — reply will remain in Chat"
        }
    }

    func beginCredentialReset() {
        self.durableDeliveryGeneration &+= 1
        self.pttStartReservationID = nil
        self.cancelDurableResponse()
        self.statusText = "Off"
        self.isPersistingDurableMessage = false
        self.pendingDurableChat = nil
        self.isPushToTalkActive = false
        self.isListening = false
        self.isUserSpeechDetected = false
        self.captureMode = .idle
        self.stopRecognition()
        self.stopSilenceMonitor()
        self.cancelPTTTimeout()
        self.pttEndTask?.cancel()
        self.pttEndTask = nil
        self.pttEndID = nil
        self.pttAutoStopEnabled = false
        self.resumeContinuousAfterPTT = false
        self.durableCaptureContext = nil
        let captureID = self.activePTTCaptureId ?? UUID().uuidString
        self.activePTTCaptureId = nil
        self.finishPTTOnce(OpenClawTalkPTTStopPayload(
            captureId: captureID,
            transcript: nil,
            status: "cancelled"))
        self.lastTranscript = ""
        self.lastHeard = nil
        self.transcriptGeneration &+= 1
    }

    func updateGatewayConnected(_ connected: Bool) {
        self.gatewayConnected = connected
        if connected {
            // If talk mode is enabled before the gateway connects (common on cold start),
            // kick recognition once we're online so the UI doesn’t stay “Offline”.
            if self.isEnabled, !self.isListening, self.captureMode != .pushToTalk {
                Task { await self.start() }
            }
        } else {
            self.cancelPendingStart()
            self.cancelDurableResponse()
            self.stopRealtimeSession()
            if self.isEnabled, !self.isSpeaking {
                self.statusText = "Offline"
            }
            self.realtimePrefetchTask?.cancel()
            self.realtimePrefetchTask = nil
            self.prefetchedRealtimeSession = nil
        }
    }

    func updateMainSessionKey(_ sessionKey: String?) {
        let trimmed = (sessionKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == self.mainSessionKey { return }
        self.cancelDurableResponse()
        self.mainSessionKey = trimmed
        if self.gatewayConnected, self.isEnabled {
            Task { await self.subscribeChatIfNeeded(sessionKey: trimmed) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        if enabled {
            self.logger.info("enabled")
            GatewayDiagnostics.log("talk.timeline manager enabled")
            Task { await self.start() }
        } else {
            self.logger.info("disabled")
            GatewayDiagnostics.log("talk.timeline manager disabled")
            self.stop()
        }
    }

    func applyProviderSelectionChanged() {
        let shouldRestart = self.isEnabled
        if shouldRestart {
            self.stop()
            self.isEnabled = true
            Task { await self.start() }
        } else {
            Task { await self.reloadConfig() }
        }
    }

    func applyAudioRoutePreferenceChanged() {
        guard self.isEnabled || self.isListening || self.isSpeaking else { return }
        do {
            if self.realtimeRelaySession != nil {
                try Self.configureRealtimeAudioSession()
            } else {
                try Self.configureAudioSession()
            }
            self.currentAudioActivation = .active
        } catch {
            GatewayDiagnostics.log("talk audio route preference failed error=\(error.localizedDescription)")
        }
    }

    func start() async {
        GatewayDiagnostics.log(
            "talk.timeline manager start enter enabled=\(self.isEnabled) "
                + "listening=\(self.isListening) gatewayConnected=\(self.gatewayConnected)")
        guard self.isEnabled else { return }
        guard self.pendingDurableChat == nil else {
            self.statusText = "Retry the previous Talk message"
            GatewayDiagnostics.log("talk start blocked: pending durable message requires review")
            return
        }
        guard self.pttStartReservationID == nil else {
            GatewayDiagnostics.log("talk start ignored: explicit PTT is starting")
            return
        }
        guard self.captureMode != .pushToTalk else { return }
        guard self.foregroundAudioCaptureAllowed else {
            self.statusText = "Paused"
            GatewayDiagnostics.log("talk start ignored: app backgrounded")
            return
        }
        if self.isListening { return }
        guard !self.isStarting else {
            GatewayDiagnostics.log("talk start ignored: already starting")
            return
        }
        guard self.gatewayConnected else {
            self.statusText = "Offline"
            GatewayDiagnostics.log("talk.timeline manager start blocked gateway offline")
            return
        }

        self.isStarting = true
        self.startAttemptID += 1
        let attemptID = self.startAttemptID
        defer {
            if self.startAttemptID == attemptID {
                self.isStarting = false
            }
        }
        self.logger.info("start")
        self.statusText = "Requesting permissions…"
        let admittedDeliveryGeneration = self.durableDeliveryGeneration
        let admittedSessionKey = self.mainSessionKey
        let admittedStableGatewayID = self.durableChatGatewayOwnerID?()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let admittedDestructiveToken: UUID?
        do {
            admittedDestructiveToken = try await self.durableChatCaptureAdmissionToken?()
        } catch {
            guard self.isCurrentStartAttempt(attemptID) else { return }
            self.statusText = "Start failed: durable delivery unavailable"
            GatewayDiagnostics.log("talk start blocked: durable admission unavailable")
            return
        }
        let startAdmission = ContinuousStartAdmission(
            attemptID: attemptID,
            stableGatewayID: admittedStableGatewayID,
            sessionKey: admittedSessionKey,
            deliveryGeneration: admittedDeliveryGeneration,
            destructiveSessionAdmissionToken: admittedDestructiveToken)
        guard await self.isCurrentContinuousStart(startAdmission) else { return }
        let permissionStartedAt = Self.nowSeconds()
        let micOk = await self.requestPTTMicrophonePermission()
        GatewayDiagnostics.log(
            "talk.timeline microphone permission ok=\(micOk) "
                + "elapsedMs=\(Self.elapsedMs(since: permissionStartedAt))")
        guard micOk else {
            self.logger.warning("start blocked: microphone permission denied")
            self.statusText = "Microphone permission denied"
            return
        }
        guard await self.isCurrentContinuousStart(startAdmission) else { return }
        await self.ensureTalkConfigLoadedForStart()
        guard await self.isCurrentContinuousStart(startAdmission) else { return }
        if self.gatewayTalkPermissionState.requiresTalkPermissionAction {
            self.statusText = "Gateway permission required"
            GatewayDiagnostics.log("talk.timeline manager start blocked gateway permission")
            return
        }
        if self.realtimeWebRTCEnabled {
            guard await self.isCurrentContinuousStart(startAdmission) else { return }
            let started = self.executionMode == .realtimeRelay
                ? await self.startRealtimeRelayIfAvailable()
                : await self.startRealtimeIfAvailable()
            if started {
                guard await self.isCurrentContinuousStart(startAdmission) else {
                    self.stopRealtimeSession()
                    return
                }
                return
            }
        }

        let speechOk = await self.requestPTTSpeechPermission()
        guard speechOk else {
            self.logger.warning("start blocked: speech permission denied")
            self.statusText = Self.permissionMessage(
                kind: "Speech recognition",
                status: SFSpeechRecognizer.authorizationStatus())
            return
        }
        guard await self.isCurrentContinuousStart(startAdmission) else { return }

        do {
            GatewayDiagnostics.log("talk.timeline fallback speech pipeline start")
            let durableContext = try await self.makeDurableCaptureContext()
            guard await self.isCurrentContinuousStart(startAdmission) else { return }
            if let admittedDestructiveToken,
               durableContext.destructiveSessionAdmissionToken != admittedDestructiveToken
            {
                throw CancellationError()
            }
            guard await self.isCurrentContinuousStart(startAdmission) else { return }
            try Self.configureAudioSession()
            self.currentAudioActivation = .active
            // Set this before starting recognition so any early speech errors are classified correctly.
            self.captureMode = .continuous
            self.beginTranscriptCapture(context: durableContext)
            try self.startRecognition()
            self.isListening = true
            self.statusText = "Listening"
            self.startSilenceMonitor()
            await self.subscribeChatIfNeeded(sessionKey: self.mainSessionKey)
            self.logger.info("listening")
        } catch {
            self.isListening = false
            self.statusText = "Start failed: \(error.localizedDescription)"
            self.logger.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isCurrentStartAttempt(_ attemptID: Int) -> Bool {
        !Task.isCancelled && self.foregroundAudioCaptureAllowed && self.gatewayConnected &&
            self.pttStartReservationID == nil && self.startAttemptID == attemptID && self.isEnabled &&
            self.captureMode != .pushToTalk
    }

    private func isCurrentContinuousStart(_ admission: ContinuousStartAdmission) async -> Bool {
        guard self.isCurrentStartAttempt(admission.attemptID),
              self.durableDeliveryGeneration == admission.deliveryGeneration,
              self.mainSessionKey == admission.sessionKey,
              self.durableChatGatewayOwnerID?()?.trimmingCharacters(in: .whitespacesAndNewlines) ==
              admission.stableGatewayID
        else { return false }
        if let token = admission.destructiveSessionAdmissionToken,
           let durableChatCaptureAdmissionIsCurrent
        {
            let tokenIsCurrent = await durableChatCaptureAdmissionIsCurrent(
                admission.stableGatewayID,
                token)
            guard tokenIsCurrent else { return false }
        }
        return self.isCurrentStartAttempt(admission.attemptID) &&
            self.durableDeliveryGeneration == admission.deliveryGeneration &&
            self.mainSessionKey == admission.sessionKey &&
            self.durableChatGatewayOwnerID?()?.trimmingCharacters(in: .whitespacesAndNewlines) ==
            admission.stableGatewayID
    }

    private func cancelPendingStart() {
        self.startAttemptID += 1
        self.isStarting = false
    }

    private var talkProviderSelection: TalkModeProviderSelection {
        TalkModeProviderSelection.resolved(
            UserDefaults.standard.string(forKey: TalkModeProviderSelection.storageKey))
    }

    private var shouldForceRealtimeRelayFromSelection: Bool {
        self.talkProviderSelection == .openAIRealtime
    }

    private func applyOpenAIRealtimeSelectionDefaults() {
        self.activeTalkProvider = "openai"
        self.executionMode = .realtimeRelay
        self.realtimeWebRTCEnabled = true
        self.realtimeProvider = self.realtimeProvider ?? "openai"
        self.realtimeModelId = self.realtimeModelId ?? Self.defaultRealtimeModelIdFallback
        self.gatewayTalkProviderLabel = TalkModeProviderSelection.openAIRealtime.label
        self.gatewayTalkUsesRealtime = true
        self.gatewayTalkUsesRealtimeRelay = true
        self.gatewayTalkTransportLabel = "Gateway Relay"
        self.gatewayTalkRealtimeProviderLabel = Self.displayName(forProvider: self.realtimeProvider ?? "openai")
        self.gatewayTalkRealtimeModelId = self.realtimeModelId
        self.gatewayTalkRealtimeVoiceId = self.realtimeVoiceId
        self.gatewayTalkDefaultModelId = self.realtimeModelId
        self.gatewayTalkDefaultVoiceId = self.realtimeVoiceId
        self.gatewayTalkApiKeyConfigured = true
    }

    func stop() {
        let pttEnding = self.pttEndTask != nil
        self.pttStartReservationID = nil
        self.isEnabled = false
        self.cancelPendingStart()
        self.isListening = false
        self.isUserSpeechDetected = false
        if !pttEnding {
            self.isPushToTalkActive = false
            self.captureMode = .idle
        }
        self.statusText = "Off"
        if self.pendingDurableChat == nil, !pttEnding {
            self.lastTranscript = ""
            self.lastHeard = nil
            self.durableCaptureContext = nil
            self.transcriptGeneration &+= 1
        }
        self.stopSilenceMonitor()
        self.stopRealtimeSession()
        self.stopRecognition()
        self.stopSpeaking(origin: .lifecycleOrManagerStop)
        self.cancelDurableResponse()
        self.lastInterruptedAtSeconds = nil
        let pendingPTT = self.pttCompletion != nil
        let pendingCaptureId = self.activePTTCaptureId ?? UUID().uuidString
        self.cancelPTTTimeout()
        self.pttAutoStopEnabled = false
        if pendingPTT, self.pttEndTask == nil {
            let payload = OpenClawTalkPTTStopPayload(
                captureId: pendingCaptureId,
                transcript: nil,
                status: "cancelled")
            self.finishPTTOnce(payload)
        }
        self.resumeContinuousAfterPTT = false
        if !pttEnding {
            self.activePTTCaptureId = nil
        }
        self.cancelTTSGeneration()
        self.systemSpeech.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            self.currentAudioActivation = .inactive
        } catch {
            self.logger.warning("audio session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
        Task { await self.unsubscribeAllChats() }
    }

    /// Suspends microphone usage without disabling Talk Mode.
    /// Used when the app backgrounds (or when we need to temporarily release the mic).
    func suspendForBackground(keepActive: Bool = false) -> Bool {
        if keepActive {
            self.statusText = self.isListening ? "Listening" : self.statusText
            return false
        }
        let wasActive = self.isEnabled || self.isListening || self.isSpeaking ||
            self.pttStartReservationID != nil ||
            self.isPushToTalkActive || self.activePTTCaptureId != nil || self.isPersistingDurableMessage

        let pttEnding = self.pttEndTask != nil
        self.pttStartReservationID = nil
        self.cancelPendingStart()
        self.isListening = false
        if !pttEnding {
            self.isPushToTalkActive = false
            self.captureMode = .idle
        }
        self.statusText = "Paused"
        if self.pendingDurableChat == nil, !pttEnding {
            self.lastTranscript = ""
            self.lastHeard = nil
            self.durableCaptureContext = nil
            self.transcriptGeneration &+= 1
        }
        self.stopSilenceMonitor()
        self.cancelPTTTimeout()

        self.stopRealtimeSession()
        self.stopRecognition()
        self.stopSpeaking(origin: .lifecycleOrManagerStop)
        self.cancelDurableResponse()
        self.lastInterruptedAtSeconds = nil
        self.cancelTTSGeneration()
        self.systemSpeech.stop()
        let captureID = self.activePTTCaptureId ?? UUID().uuidString
        if !pttEnding {
            self.activePTTCaptureId = nil
        }
        if self.pttEndTask == nil {
            self.finishPTTOnce(OpenClawTalkPTTStopPayload(
                captureId: captureID,
                transcript: nil,
                status: "cancelled"))
        }

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            self.currentAudioActivation = .inactive
        } catch {
            self.logger.warning("audio session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }

        Task { await self.unsubscribeAllChats() }
        return wasActive
    }

    func setForegroundAudioCaptureAllowed(_ allowed: Bool) {
        self.foregroundAudioCaptureAllowed = allowed
        if !allowed {
            self.cancelPendingStart()
            self.cancelDurableResponse()
        }
    }

    func resumeAfterBackground(wasSuspended: Bool, wasKeptActive: Bool = false) async {
        if wasKeptActive { return }
        guard wasSuspended else { return }
        guard self.isEnabled else { return }
        await self.start()
    }

    func userTappedOrb() {
        if let realtimeSession {
            realtimeSession.cancelResponse()
        }
        self.realtimeRelaySession?.cancelOutput()
        self.stopSpeaking(origin: .userOrb)
    }

    func beginPushToTalk() async throws -> OpenClawTalkPTTStartPayload {
        guard self.pendingDurableChat == nil else {
            self.statusText = "Retry the previous Talk message"
            throw NSError(domain: "TalkMode", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Retry the previous Talk message before recording another",
            ])
        }
        guard self.gatewayConnected else {
            self.statusText = "Offline"
            throw NSError(domain: "TalkMode", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Gateway not connected",
            ])
        }
        guard self.foregroundAudioCaptureAllowed else {
            self.statusText = "Paused"
            throw CancellationError()
        }
        if self.isPushToTalkActive, let captureId = activePTTCaptureId {
            return OpenClawTalkPTTStartPayload(captureId: captureId)
        }
        guard self.pttStartReservationID == nil else {
            throw NSError(domain: "TalkMode", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Push to Talk is already starting",
            ])
        }
        let startReservationID = UUID()
        self.pttStartReservationID = startReservationID
        defer {
            if self.pttStartReservationID == startReservationID {
                self.pttStartReservationID = nil
            }
        }
        if self.isStarting {
            self.cancelPendingStart()
        }

        // A new explicit interaction owns the audio surface. Fence any older
        // exact-run observer/TTS without cancelling its durable FIFO delivery.
        self.cancelDurableResponse()
        let durableContext = try await self.makeDurableCaptureContext()
        guard self.pttStartReservationID == startReservationID,
              self.gatewayConnected,
              self.foregroundAudioCaptureAllowed,
              !Task.isCancelled
        else {
            throw CancellationError()
        }

        self.stopSpeaking(origin: .pttAdmission, storeInterruption: false)
        self.cancelPendingStart()
        self.cancelPTTTimeout()
        self.pttAutoStopEnabled = false

        self.resumeContinuousAfterPTT = self.isEnabled && self.captureMode == .continuous
        self.stopSilenceMonitor()
        self.stopRealtimeSession()
        self.stopRecognition()
        self.isListening = false
        self.isUserSpeechDetected = false

        let captureId = UUID().uuidString
        self.activePTTCaptureId = captureId
        self.beginTranscriptCapture(context: durableContext)
        var captureStarted = false
        defer {
            if !captureStarted {
                self.cancelPTTStartIfCurrent(captureID: captureId)
            }
        }

        self.statusText = "Requesting permissions…"
        if !self.allowSimulatorCapture {
            let micOk = await self.requestPTTMicrophonePermission()
            try await self.requireCurrentPTTStart(
                captureID: captureId,
                context: durableContext,
                startReservationID: startReservationID)
            guard micOk else {
                self.statusText = "Microphone permission denied"
                throw NSError(domain: "TalkMode", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Microphone permission denied",
                ])
            }
            let speechOk = await self.requestPTTSpeechPermission()
            try await self.requireCurrentPTTStart(
                captureID: captureId,
                context: durableContext,
                startReservationID: startReservationID)
            guard speechOk else {
                self.statusText = Self.permissionMessage(
                    kind: "Speech recognition",
                    status: SFSpeechRecognizer.authorizationStatus())
                throw NSError(domain: "TalkMode", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Speech recognition permission denied",
                ])
            }
        }

        do {
            try await self.requireCurrentPTTStart(
                captureID: captureId,
                context: durableContext,
                startReservationID: startReservationID)
            try Self.configureAudioSession()
            self.currentAudioActivation = .active
            self.captureMode = .pushToTalk
            try self.startRecognition()
            self.isListening = true
            self.isPushToTalkActive = true
            self.statusText = "Listening (PTT)"
        } catch {
            self.isListening = false
            self.isUserSpeechDetected = false
            self.isPushToTalkActive = false
            self.captureMode = .idle
            self.statusText = "Start failed: \(error.localizedDescription)"
            throw error
        }

        captureStarted = true
        return OpenClawTalkPTTStartPayload(captureId: captureId)
    }

    func endPushToTalk() async -> OpenClawTalkPTTStopPayload {
        self.pttStartReservationID = nil
        if let pttEndTask {
            return await pttEndTask.value
        }
        guard let captureID = self.activePTTCaptureId else {
            let payload = OpenClawTalkPTTStopPayload(
                captureId: UUID().uuidString,
                transcript: nil,
                status: "idle")
            self.finishPTTOnce(payload)
            return payload
        }
        let endID = UUID()
        let admission = PTTEndAdmission(
            endID: endID,
            captureID: captureID,
            deliveryGeneration: self.durableDeliveryGeneration,
            transcriptGeneration: self.transcriptGeneration)
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return OpenClawTalkPTTStopPayload(
                    captureId: admission.captureID,
                    transcript: nil,
                    status: "cancelled")
            }
            #if DEBUG
            await self.pttEndBeforeBodyOverride?()
            #endif
            guard self.isCurrentPTTEnd(admission) else {
                return OpenClawTalkPTTStopPayload(
                    captureId: admission.captureID,
                    transcript: nil,
                    status: "cancelled")
            }
            return await self.performEndPushToTalk(admission)
        }
        self.pttEndID = endID
        self.pttEndTask = task
        let payload = await task.value
        if self.pttEndID == endID {
            self.pttEndTask = nil
            self.pttEndID = nil
        }
        return payload
    }

    private func isCurrentPTTEnd(_ admission: PTTEndAdmission) -> Bool {
        !Task.isCancelled && self.pttEndID == admission.endID &&
            self.activePTTCaptureId == admission.captureID &&
            self.durableDeliveryGeneration == admission.deliveryGeneration &&
            self.transcriptGeneration == admission.transcriptGeneration
    }

    private func performEndPushToTalk(
        _ admission: PTTEndAdmission) async -> OpenClawTalkPTTStopPayload
    {
        guard self.isCurrentPTTEnd(admission) else {
            return OpenClawTalkPTTStopPayload(
                captureId: admission.captureID,
                transcript: nil,
                status: "cancelled")
        }
        let captureId = admission.captureID
        guard self.isPushToTalkActive else {
            let payload = OpenClawTalkPTTStopPayload(
                captureId: captureId,
                transcript: nil,
                status: "idle")
            self.finishPTTOnce(payload)
            return payload
        }

        self.isPushToTalkActive = false
        self.isListening = false
        self.isUserSpeechDetected = false
        self.captureMode = .idle
        self.stopRecognition()
        self.stopSilenceMonitor()
        self.cancelPTTTimeout()
        self.pttAutoStopEnabled = false

        let transcript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let captureGeneration = self.transcriptGeneration
        let captureContext = self.durableCaptureContext

        guard !transcript.isEmpty else {
            if self.transcriptGeneration == captureGeneration {
                self.lastTranscript = ""
                self.lastHeard = nil
                self.durableCaptureContext = nil
            }
            self.statusText = "Ready"
            if self.resumeContinuousAfterPTT {
                await self.start()
            }
            self.resumeContinuousAfterPTT = false
            self.activePTTCaptureId = nil
            let payload = OpenClawTalkPTTStopPayload(
                captureId: captureId,
                transcript: nil,
                status: "empty")
            self.finishPTTOnce(payload)
            return payload
        }

        let restartAfter = self.resumeContinuousAfterPTT
        self.resumeContinuousAfterPTT = false
        self.activePTTCaptureId = nil
        self.statusText = "Queueing…"
        do {
            let persisted = try await self.persistTranscript(
                transcript,
                captureGeneration: captureGeneration,
                captureContext: captureContext,
                restartAfter: restartAfter)
            if persisted.wasPurgedByCredentialReset {
                let payload = OpenClawTalkPTTStopPayload(
                    captureId: captureId,
                    transcript: nil,
                    status: "cancelled")
                self.finishPTTOnce(payload)
                return payload
            }
            let payload = OpenClawTalkPTTStopPayload(
                captureId: captureId,
                transcript: transcript,
                status: "queued")
            self.finishPTTOnce(payload)
            self.startDurableResponse(for: persisted)
            return payload
        } catch {
            if error is CancellationError {
                let payload = OpenClawTalkPTTStopPayload(
                    captureId: captureId,
                    transcript: nil,
                    status: "cancelled")
                self.finishPTTOnce(payload)
                return payload
            }
            self.statusText = "Talk message not queued — retry available"
            let nsError = error as NSError
            let errorDomain = IOSGatewayChatTransport.diagnosticToken(nsError.domain, maximumLength: 80)
            GatewayDiagnostics.log(
                "event=talk_outbox_persist_failed command_id=\(self.pendingDurableCommandID ?? "unavailable") "
                    + "error_domain=\(errorDomain) error_code=\(nsError.code)")
            let payload = OpenClawTalkPTTStopPayload(
                captureId: captureId,
                transcript: transcript,
                status: "not_queued")
            self.finishPTTOnce(payload)
            return payload
        }
    }

    func runPushToTalkOnce(maxDurationSeconds: TimeInterval = 12) async throws -> OpenClawTalkPTTStopPayload {
        if self.pttCompletion != nil {
            _ = await self.cancelPushToTalk()
        }

        if self.isPushToTalkActive {
            let captureId = self.activePTTCaptureId ?? UUID().uuidString
            return OpenClawTalkPTTStopPayload(
                captureId: captureId,
                transcript: nil,
                status: "busy")
        }

        _ = try await self.beginPushToTalk()

        return await withCheckedContinuation { cont in
            self.pttCompletion = cont
            self.pttAutoStopEnabled = true
            self.startSilenceMonitor()
            self.schedulePTTTimeout(seconds: maxDurationSeconds)
        }
    }

    func cancelPushToTalk() async -> OpenClawTalkPTTStopPayload {
        self.pttStartReservationID = nil
        if let pttEndTask {
            return await pttEndTask.value
        }
        let captureId = self.activePTTCaptureId ?? UUID().uuidString
        guard self.isPushToTalkActive else {
            let payload = OpenClawTalkPTTStopPayload(
                captureId: captureId,
                transcript: nil,
                status: "idle")
            self.finishPTTOnce(payload)
            self.pttAutoStopEnabled = false
            self.stopSilenceMonitor()
            self.cancelPTTTimeout()
            self.resumeContinuousAfterPTT = false
            self.activePTTCaptureId = nil
            self.durableCaptureContext = nil
            return payload
        }

        let shouldResume = self.resumeContinuousAfterPTT
        self.isPushToTalkActive = false
        self.isListening = false
        self.captureMode = .idle
        self.stopRecognition()
        self.lastTranscript = ""
        self.lastHeard = nil
        self.durableCaptureContext = nil
        self.transcriptGeneration &+= 1
        self.pttAutoStopEnabled = false
        self.stopSilenceMonitor()
        self.cancelPTTTimeout()
        self.resumeContinuousAfterPTT = false
        self.activePTTCaptureId = nil
        self.statusText = "Ready"

        let payload = OpenClawTalkPTTStopPayload(
            captureId: captureId,
            transcript: nil,
            status: "cancelled")
        self.finishPTTOnce(payload)

        if shouldResume {
            await self.start()
        }
        return payload
    }

    private func startRecognition() throws {
        self.stopRecognition()
        self.recognitionCallbackGeneration &+= 1
        let callbackGeneration = self.recognitionCallbackGeneration

        #if targetEnvironment(simulator)
        if self.allowSimulatorCapture {
            self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            self.recognitionRequest?.shouldReportPartialResults = true
            self.recordRecognitionEvent("speech_recognition_started", result: "success")
            return
        }
        if !self.allowSimulatorCapture {
            throw NSError(domain: "TalkMode", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Talk mode is not supported on the iOS simulator",
            ])
        }
        #endif

        let localSpeechLocale = UserDefaults.standard.string(forKey: TalkSpeechLocale.storageKey)
        let resolvedSpeech = TalkSpeechLocale.makeRecognizer(
            localSelection: localSpeechLocale,
            gatewaySelection: self.gatewaySpeechLocaleID)
        self.speechRecognizer = resolvedSpeech.recognizer
        guard let recognizer = speechRecognizer else {
            throw NSError(domain: "TalkMode", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognizer unavailable",
            ])
        }
        GatewayDiagnostics.log("talk speech: locale=\(resolvedSpeech.localeID ?? "default")")

        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest?.shouldReportPartialResults = true
        self.recognitionRequest?.taskHint = .dictation
        guard let request = recognitionRequest else { return }

        GatewayDiagnostics.log("talk audio: session \(Self.describeAudioSession())")

        let input = self.audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "TalkMode", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Invalid audio input format",
            ])
        }
        input.removeTap(onBus: 0)
        let tapDiagnostics = AudioTapDiagnostics(label: "talk") { [weak self] level in
            guard let self else { return }
            Task { @MainActor in
                guard self.recognitionCallbackGeneration == callbackGeneration else { return }
                // Smooth + clamp for UI, and keep it cheap.
                let raw = max(0, min(Double(level) * 10.0, 1.0))
                let next = (self.micLevel * 0.80) + (raw * 0.20)
                self.micLevel = next

                // Dynamic thresholding so background noise doesn’t prevent endpointing.
                if self.isListening, !self.isSpeaking, !self.noiseFloorReady {
                    self.noiseFloorSamples.append(raw)
                    if self.noiseFloorSamples.count >= 22 {
                        let sorted = self.noiseFloorSamples.sorted()
                        let take = max(6, sorted.count / 2)
                        let slice = sorted.prefix(take)
                        let avg = slice.reduce(0.0, +) / Double(slice.count)
                        self.noiseFloor = avg
                        self.noiseFloorReady = true
                        self.noiseFloorSamples.removeAll(keepingCapacity: true)
                        let threshold = min(0.35, max(0.12, avg + 0.10))
                        GatewayDiagnostics.log(
                            "talk audio: noiseFloor=\(String(format: "%.3f", avg)) "
                                + "threshold=\(String(format: "%.3f", threshold))")
                    }
                }

                let threshold: Double = if let floor = self.noiseFloor, self.noiseFloorReady {
                    min(0.35, max(0.12, floor + 0.10))
                } else {
                    0.18
                }
                if raw >= threshold {
                    self.lastAudioActivity = Date()
                }
            }
        }
        self.audioTapDiagnostics = tapDiagnostics
        let tapBlock = Self.makeAudioTapAppendCallback(request: request, diagnostics: tapDiagnostics)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: tapBlock)
        self.inputTapInstalled = true

        self.audioEngine.prepare()
        try self.audioEngine.start()
        self.loggedPartialThisCycle = false

        GatewayDiagnostics.log(
            "talk speech: recognition started mode=\(String(describing: self.captureMode)) "
                + "engineRunning=\(self.audioEngine.isRunning)")
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                await self?.handleRecognitionCallback(
                    transcript: transcript,
                    isFinal: isFinal,
                    errorMessage: errorMessage,
                    generation: callbackGeneration)
            }
        }
        self.recordRecognitionEvent("speech_recognition_started", result: "success")
    }

    private func recordRecognitionEvent(_ state: String, result: String) {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: state,
            operationGeneration: self.recognitionCallbackGeneration,
            sessionGeneration: self.transcriptGeneration,
            resultClass: result))
    }

    private func handleRecognitionCallback(
        transcript: String?,
        isFinal: Bool,
        errorMessage: String?,
        generation: UInt64) async
    {
        guard generation == self.recognitionCallbackGeneration else { return }
        if let msg = errorMessage {
            let lowered = msg.lowercased()
            let isCancellation = lowered.contains("cancelled") || lowered.contains("canceled")
            self.recordRecognitionEvent(
                isCancellation ? "speech_recognition_cancelled" : "speech_recognition_error",
                result: isCancellation ? "cancelled" : "failed")
            if isCancellation {
                GatewayDiagnostics.log("talk speech: cancelled")
                self.logger.debug("speech recognition cancelled")
                guard self.captureMode == .continuous, self.isEnabled, !self.isSpeechOutputActive else { return }
            } else {
                GatewayDiagnostics.log("talk speech: error=\(msg)")
            }
            if !self.isSpeaking, !isCancellation {
                if msg.localizedCaseInsensitiveContains("no speech detected") {
                    // Treat as transient silence. Don't scare users with an error banner.
                    self.statusText = self.isEnabled ? "Listening" : "Speech error: \(msg)"
                } else {
                    self.statusText = "Speech error: \(msg)"
                }
            }
            self.logger.debug("speech recognition error: \(msg, privacy: .public)")
            // Speech recognition can terminate on transient errors (e.g. no speech detected).
            // If talk mode is enabled and we're in continuous capture, try to restart.
            if self.captureMode == .continuous, self.isEnabled, !self.isSpeechOutputActive {
                // Intentional stop callbacks have an old generation and were rejected above.
                // A current-generation cancellation is terminal just like other recognition errors.
                self.stopRecognition()
                self.isListening = false
                self.statusText = !self.foregroundAudioCaptureAllowed ? "Paused"
                    : self.gatewayConnected ? "Reconnecting microphone…" : "Offline"
                let restartGeneration = self.recognitionCallbackGeneration
                Task { @MainActor [weak self] in
                    await self?.restartRecognitionAfterError(expectedGeneration: restartGeneration)
                }
            }
        }
        guard generation == self.recognitionCallbackGeneration,
              let transcript
        else { return }
        if !isFinal, !self.loggedPartialThisCycle {
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.loggedPartialThisCycle = true
                GatewayDiagnostics.log("talk speech: partial chars=\(trimmed.count)")
                self.recordRecognitionEvent("speech_transcript_partial_received", result: "success")
            }
        }
        await self.handleTranscript(transcript: transcript, isFinal: isFinal)
    }

    private func restartRecognitionAfterError(expectedGeneration: UInt64) async {
        guard !Task.isCancelled,
              expectedGeneration == self.recognitionCallbackGeneration,
              self.isEnabled,
              self.captureMode == .continuous,
              self.foregroundAudioCaptureAllowed,
              self.gatewayConnected,
              !self.isSpeechOutputActive
        else { return }
        // Avoid thrashing the audio engine if it’s already running.
        if self.recognitionTask != nil, self.audioEngine.isRunning { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled,
              expectedGeneration == self.recognitionCallbackGeneration,
              self.isEnabled,
              self.captureMode == .continuous,
              self.foregroundAudioCaptureAllowed,
              self.gatewayConnected,
              !self.isSpeechOutputActive
        else { return }
        do {
            try Self.configureAudioSession()
            self.currentAudioActivation = .active
            try self.startRecognition()
            self.isListening = true
            self.statusText = "Listening"
            self.recordRecognitionEvent("speech_recognition_restarted", result: "success")
            GatewayDiagnostics.log("talk speech: recognition restarted")
        } catch {
            self.stopRecognition()
            self.isListening = false
            self.statusText = "Microphone unavailable — turn Talk off and on to retry"
            self.recordRecognitionEvent("speech_recognition_restart_failed", result: "failed")
            let msg = error.localizedDescription
            GatewayDiagnostics.log("talk speech: restart failed error=\(msg)")
        }
    }

    private func stopRecognition() {
        self.recognitionCallbackGeneration &+= 1
        self.recognitionTask?.cancel()
        self.recognitionTask = nil
        self.recognitionRequest?.endAudio()
        self.recognitionRequest = nil
        self.micLevel = 0
        self.lastAudioActivity = nil
        self.noiseFloorSamples.removeAll(keepingCapacity: true)
        self.noiseFloor = nil
        self.noiseFloorReady = false
        self.audioTapDiagnostics = nil
        if self.inputTapInstalled {
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.inputTapInstalled = false
        }
        self.audioEngine.stop()
        self.speechRecognizer = nil
    }

    private nonisolated static func makeAudioTapAppendCallback(
        request: SpeechRequest,
        diagnostics: AudioTapDiagnostics) -> AVAudioNodeTapBlock
    {
        { buffer, _ in
            request.append(buffer)
            diagnostics.onBuffer(buffer)
        }
    }

    private func handleTranscript(transcript: String, isFinal: Bool) async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let ttsActive = self.isSpeechOutputActive
        if ttsActive, self.interruptOnSpeech {
            if self.shouldInterrupt(with: trimmed) {
                self.stopSpeaking(origin: .speechRecognitionBargeIn)
            }
            return
        }

        guard self.isListening else { return }
        if !trimmed.isEmpty {
            self.lastTranscript = trimmed
            self.lastHeard = Date()
        }
        if isFinal {
            self.lastTranscript = trimmed
            guard !trimmed.isEmpty else { return }
            GatewayDiagnostics.log("talk speech: final transcript chars=\(trimmed.count)")
            self.recordRecognitionEvent("speech_transcript_final_received", result: "success")
            self.loggedPartialThisCycle = false
            if self.captureMode == .pushToTalk, self.pttAutoStopEnabled, self.isPushToTalkActive {
                _ = await self.endPushToTalk()
                return
            }
            if self.captureMode == .continuous, !self.isSpeechOutputActive {
                await self.processTranscript(trimmed, restartAfter: true)
            }
        }
    }

    private func startSilenceMonitor() {
        self.stopSilenceMonitor()
        self.silenceMonitorGeneration &+= 1
        let generation = self.silenceMonitorGeneration
        let transcriptGeneration = self.transcriptGeneration
        let captureID = self.activePTTCaptureId
        self.silenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isCurrentSilenceMonitor(
                generation: generation,
                transcriptGeneration: transcriptGeneration,
                captureID: captureID),
                self.isEnabled || (self.isPushToTalkActive && self.pttAutoStopEnabled)
            {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
                guard self.isCurrentSilenceMonitor(
                    generation: generation,
                    transcriptGeneration: transcriptGeneration,
                    captureID: captureID)
                else { return }
                await self.checkSilence()
            }
        }
    }

    private func stopSilenceMonitor() {
        self.silenceMonitorGeneration &+= 1
        self.silenceTask?.cancel()
        self.silenceTask = nil
    }

    private func isCurrentSilenceMonitor(
        generation: UInt64,
        transcriptGeneration: UInt64,
        captureID: String?) -> Bool
    {
        !Task.isCancelled && self.silenceMonitorGeneration == generation &&
            self.transcriptGeneration == transcriptGeneration && self.activePTTCaptureId == captureID
    }

    private func checkSilence() async {
        if self.captureMode == .continuous {
            guard self.isListening, !self.isSpeechOutputActive else { return }
            let transcript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return }
            let lastActivity = [lastHeard, lastAudioActivity].compactMap(\.self).max()
            guard let lastActivity else { return }
            if Date().timeIntervalSince(lastActivity) < self.silenceWindow { return }
            await self.processTranscript(transcript, restartAfter: true)
            return
        }

        guard self.captureMode == .pushToTalk, self.pttAutoStopEnabled else { return }
        guard self.isListening, !self.isSpeaking, self.isPushToTalkActive else { return }
        let transcript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        let lastActivity = [lastHeard, lastAudioActivity].compactMap(\.self).max()
        guard let lastActivity else { return }
        if Date().timeIntervalSince(lastActivity) < self.silenceWindow { return }
        _ = await self.endPushToTalk()
    }

    /// Guardrail for PTT once so we don't stay open indefinitely.
    private func schedulePTTTimeout(seconds: TimeInterval) {
        guard seconds > 0, let captureID = self.activePTTCaptureId else { return }
        let nanos = UInt64(seconds * 1_000_000_000)
        self.cancelPTTTimeout()
        self.pttTimeoutGeneration &+= 1
        let generation = self.pttTimeoutGeneration
        self.pttTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return
            }
            await self?.handlePTTTimeout(generation: generation, captureID: captureID)
        }
    }

    private func cancelPTTTimeout() {
        self.pttTimeoutGeneration &+= 1
        self.pttTimeoutTask?.cancel()
        self.pttTimeoutTask = nil
    }

    private func handlePTTTimeout(generation: UInt64, captureID: String) async {
        guard !Task.isCancelled,
              generation == self.pttTimeoutGeneration,
              captureID == self.activePTTCaptureId,
              self.pttAutoStopEnabled,
              self.isPushToTalkActive
        else { return }
        _ = await self.endPushToTalk()
    }

    private func finishPTTOnce(_ payload: OpenClawTalkPTTStopPayload) {
        guard let continuation = pttCompletion else { return }
        self.pttCompletion = nil
        continuation.resume(returning: payload)
    }

    private func processTranscript(_ transcript: String, restartAfter: Bool) async {
        self.recordRecognitionEvent("speech_turn_finalizing", result: "requested")
        let captureContext = self.durableCaptureContext
        self.isListening = false
        self.isUserSpeechDetected = false
        self.captureMode = .idle
        self.statusText = "Queueing…"
        self.stopRecognition()

        GatewayDiagnostics.log("talk: process transcript chars=\(transcript.count) restartAfter=\(restartAfter)")
        do {
            let persisted = try await self.persistTranscript(
                transcript,
                captureGeneration: self.transcriptGeneration,
                captureContext: captureContext,
                restartAfter: restartAfter)
            guard !persisted.wasPurgedByCredentialReset else { return }
            self.startDurableResponse(for: persisted)
        } catch {
            if error is CancellationError { return }
            self.statusText = "Talk message not queued — retry available"
            let nsError = error as NSError
            let errorDomain = IOSGatewayChatTransport.diagnosticToken(nsError.domain, maximumLength: 80)
            GatewayDiagnostics.log(
                "event=talk_outbox_persist_failed command_id=\(self.pendingDurableCommandID ?? "unavailable") "
                    + "error_domain=\(errorDomain) error_code=\(nsError.code)")
        }
    }

    @discardableResult
    func retryPendingDurableMessage() async -> Bool {
        guard !self.isPersistingDurableMessage,
              let pending = self.pendingDurableChat
        else { return false }
        do {
            let refreshedPending = try await self.refreshPendingAdmissionForExplicitRetry(pending)
            self.statusText = "Queueing…"
            let persisted = try await self.persistPendingDurableChat(refreshedPending)
            guard !persisted.wasPurgedByCredentialReset else { return false }
            self.startDurableResponse(for: persisted)
            return true
        } catch {
            if error is CancellationError { return false }
            self.statusText = "Talk message not queued — retry available"
            return false
        }
    }

    @discardableResult
    func discardPendingDurableMessage() -> Bool {
        guard !self.isPersistingDurableMessage,
              let pending = self.pendingDurableChat
        else { return false }
        self.pendingDurableChat = nil
        if self.transcriptGeneration == pending.captureGeneration,
           self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines) == pending.transcript
        {
            self.lastTranscript = ""
            self.lastHeard = nil
            self.durableCaptureContext = nil
            self.transcriptGeneration &+= 1
        }
        self.statusText = self.gatewayConnected ? "Ready" : "Offline"
        GatewayDiagnostics.log(
            "event=talk_outbox_pending_discarded command_id=\(pending.request.rawCommandID)")
        return true
    }

    private func refreshPendingAdmissionForExplicitRetry(
        _ pending: PendingDurableChat) async throws -> PendingDurableChat
    {
        let admittedDeliveryGeneration = self.durableDeliveryGeneration
        let admittedRawCommandID = pending.request.rawCommandID
        guard pending.deliveryGeneration == admittedDeliveryGeneration,
              self.pendingDurableChat?.request.rawCommandID == admittedRawCommandID,
              !Task.isCancelled
        else {
            throw CancellationError()
        }
        let currentGatewayID = self.durableChatGatewayOwnerID?()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard currentGatewayID == pending.request.stableGatewayID else {
            throw OpenClawChatOutboxError.routeSnapshotChanged
        }
        guard let durableChatCaptureAdmission else {
            throw OpenClawChatOutboxError.routeSnapshotUnavailable
        }
        let admission = try await durableChatCaptureAdmission()
        guard !Task.isCancelled,
              self.durableDeliveryGeneration == admittedDeliveryGeneration,
              self.pendingDurableChat?.request.rawCommandID == admittedRawCommandID,
              self.pendingDurableChat?.deliveryGeneration == admittedDeliveryGeneration,
              self.durableChatGatewayOwnerID?()?
                .trimmingCharacters(in: .whitespacesAndNewlines) == pending.request.stableGatewayID
        else {
            throw CancellationError()
        }
        let refreshedRequest = TalkDurableChatRequest(
            rawCommandID: pending.request.rawCommandID,
            stableGatewayID: pending.request.stableGatewayID,
            sessionKey: pending.request.sessionKey,
            message: pending.request.message,
            thinkingLevel: pending.request.thinkingLevel,
            destructiveSessionAdmissionToken: admission.destructiveSessionAdmissionToken,
            captureRouteSnapshot: admission.routeSnapshot)
        let refreshed = PendingDurableChat(
            request: refreshedRequest,
            transcript: pending.transcript,
            captureGeneration: pending.captureGeneration,
            deliveryGeneration: pending.deliveryGeneration,
            // Explicit retry changes only the pre-effect destructive admission
            // token. A session/lifecycle switch that fenced presentation must
            // not be undone merely because delivery is retried.
            responseAdmissionGeneration: pending.responseAdmissionGeneration,
            restartAfter: pending.restartAfter)
        if self.pendingDurableChat?.request.rawCommandID == pending.request.rawCommandID {
            self.pendingDurableChat = refreshed
        }
        return refreshed
    }

    private func persistTranscript(
        _ transcript: String,
        captureGeneration: UInt64,
        captureContext: DurableCaptureContext?,
        restartAfter: Bool) async throws -> PersistedDurableChat
    {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "TalkMode", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Talk transcript is empty",
            ])
        }
        let pending: PendingDurableChat
        if let existing = self.pendingDurableChat {
            guard existing.transcript == trimmed else {
                throw NSError(domain: "TalkMode", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "Retry the previous Talk message before recording another",
                ])
            }
            pending = existing
        } else {
            guard let captureContext else {
                throw OpenClawChatOutboxError.routeSnapshotUnavailable
            }
            let request = TalkDurableChatRequest(
                rawCommandID: captureContext.rawCommandID,
                stableGatewayID: captureContext.stableGatewayID,
                sessionKey: captureContext.sessionKey,
                message: self.buildPrompt(transcript: trimmed),
                thinkingLevel: "low",
                destructiveSessionAdmissionToken: captureContext.destructiveSessionAdmissionToken,
                captureRouteSnapshot: captureContext.captureRouteSnapshot)
            pending = PendingDurableChat(
                request: request,
                transcript: trimmed,
                captureGeneration: captureGeneration,
                deliveryGeneration: captureContext.deliveryGeneration,
                responseAdmissionGeneration: captureContext.responseAdmissionGeneration,
                restartAfter: restartAfter)
            self.pendingDurableChat = pending
        }
        return try await self.persistPendingDurableChat(pending)
    }

    private func persistPendingDurableChat(
        _ pending: PendingDurableChat) async throws -> PersistedDurableChat
    {
        guard !self.isPersistingDurableMessage else {
            throw NSError(domain: "TalkMode", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Talk message persistence is already in progress",
            ])
        }
        guard let durableChatPersist = self.durableChatPersist else {
            throw NSError(domain: "TalkMode", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Durable Talk delivery is unavailable",
            ])
        }
        let startLogMessage =
            "event=talk_outbox_persist_start command_id=\(pending.request.rawCommandID) "
                + "message_length=\(pending.request.message.count)"
        GatewayDiagnostics.log(startLogMessage)
        self.isPersistingDurableMessage = true
        defer {
            if pending.deliveryGeneration == self.durableDeliveryGeneration {
                self.isPersistingDurableMessage = false
            }
        }
        let persistence: TalkDurableChatPersistence
        do {
            persistence = try await durableChatPersist(pending.request)
        } catch {
            guard pending.deliveryGeneration == self.durableDeliveryGeneration else {
                throw CancellationError()
            }
            throw error
        }
        let deliveryIsCurrent = pending.deliveryGeneration == self.durableDeliveryGeneration

        // The enqueue return is proof that SQLite committed. A concurrent new
        // capture owns a newer generation and must never be erased here.
        if deliveryIsCurrent,
           self.transcriptGeneration == pending.captureGeneration,
           self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines) == pending.transcript
        {
            self.lastTranscript = ""
            self.lastHeard = nil
            self.durableCaptureContext = nil
        }
        if deliveryIsCurrent,
           self.pendingDurableChat?.request.rawCommandID == pending.request.rawCommandID
        {
            self.pendingDurableChat = nil
        }
        if deliveryIsCurrent {
            self.statusText = "Queued"
        }
        GatewayDiagnostics.log(
            "event=talk_outbox_persisted command_id=\(pending.request.rawCommandID)")
        return PersistedDurableChat(
            persistence: persistence,
            responseAdmissionGeneration: pending.responseAdmissionGeneration,
            allowsPresentation: deliveryIsCurrent,
            wasPurgedByCredentialReset: !deliveryIsCurrent,
            restartAfter: pending.restartAfter)
    }

    private func startDurableResponse(for persisted: PersistedDurableChat) {
        guard persisted.allowsPresentation else { return }
        guard persisted.responseAdmissionGeneration == self.durableResponseGeneration,
              self.foregroundAudioCaptureAllowed
        else {
            self.statusText = "Queued — reply will remain in Chat"
            return
        }
        self.cancelDurableResponse()
        self.durableResponseGeneration &+= 1
        let responseGeneration = self.durableResponseGeneration
        #if DEBUG
        let durableResponseExited = self.durableResponseExitedOverride
        #endif
        self.durableResponseTask = Task { @MainActor [weak self] in
            #if DEBUG
            defer { durableResponseExited?(responseGeneration) }
            #endif
            guard let self else { return }
            await self.handleDurableResponse(
                persisted.persistence,
                restartAfter: persisted.restartAfter,
                responseGeneration: responseGeneration)
            guard self.durableResponseGeneration == responseGeneration else { return }
            self.durableResponseTask = nil
        }
    }

    private func handleDurableResponse(
        _ persistence: TalkDurableChatPersistence,
        restartAfter: Bool,
        responseGeneration: UInt64) async
    {
        let rawCommandID = persistence.request.rawCommandID
        let outcome: OpenClawChatOutboxOutcome?
        do {
            try await persistence.owner.wake()
            let streamedOutcome = await self.waitForDurableOutcome(
                persistence,
                timeoutSeconds: 35)
            if let streamedOutcome {
                outcome = streamedOutcome
            } else {
                outcome = try await persistence.owner.currentOutcome(rawCommandID: rawCommandID)
            }
        } catch {
            guard self.isCurrentDurableResponse(responseGeneration) else { return }
            self.statusText = "Queued — delivery pending"
            GatewayDiagnostics.log(
                "event=talk_outbox_process_deferred command_id=\(rawCommandID)")
            await self.restartAfterDurableResponseIfNeeded(
                responseGeneration,
                restartAfter: restartAfter)
            return
        }
        guard self.isCurrentDurableResponse(responseGeneration) else { return }
        guard let outcome else {
            self.statusText = "Queued — delivery pending"
            await self.restartAfterDurableResponseIfNeeded(
                responseGeneration,
                restartAfter: restartAfter)
            return
        }

        switch outcome {
        case .accepted, .ambiguous, .canonicalHistoryConfirmed:
            break
        case .notDispatched:
            self.statusText = "Queued — waiting for connection"
            await self.restartAfterDurableResponseIfNeeded(
                responseGeneration,
                restartAfter: restartAfter)
            return
        case .dispatchRejected, .blockedRouteChanged:
            self.statusText = "Queued — review required"
            await self.restartAfterDurableResponseIfNeeded(
                responseGeneration,
                restartAfter: restartAfter)
            return
        case .expired, .cancelled:
            self.statusText = "Talk delivery ended — text preserved"
            await self.restartAfterDurableResponseIfNeeded(
                responseGeneration,
                restartAfter: restartAfter)
            return
        }

        guard self.gatewayConnected else {
            self.statusText = "Queued — reply will remain in Chat"
            return
        }
        await self.reloadConfig()
        guard self.isCurrentDurableResponse(responseGeneration) else { return }
        let diagnosticRunID = IOSGatewayChatTransport.diagnosticToken(rawCommandID)
        GatewayDiagnostics.log(
            "event=talk_chat_send_admitted command_id=\(rawCommandID) run_id=\(diagnosticRunID)")
        let admissionUpdates = await persistence.owner.destructiveSessionAdmissionUpdates()
        guard self.isCurrentDurableResponse(responseGeneration) else { return }
        let expectedAdmissionToken = persistence.request.destructiveSessionAdmissionToken
        let admissionMonitor = Task { @MainActor [weak self] in
            guard let self else { return }
            for await token in admissionUpdates {
                if Task.isCancelled { return }
                guard token == expectedAdmissionToken else {
                    guard self.isCurrentDurableResponse(responseGeneration) else { return }
                    self.cancelDurableResponse()
                    return
                }
            }
            guard self.isCurrentDurableResponse(responseGeneration) else { return }
            self.cancelDurableResponse()
        }
        defer { admissionMonitor.cancel() }
        let shouldIncremental = self.shouldUseIncrementalTTS()
        let presentationValidator: SpeechPresentationValidator = { [weak self] in
            guard let self else { return false }
            return await self.isDurablePresentationAuthorized(
                persistence,
                responseGeneration: responseGeneration)
        }
        var streamingTask: Task<Void, Never>?
        if shouldIncremental {
            self.resetIncrementalSpeech()
            self.incrementalSpeechPresentationValidator = presentationValidator
            let incrementalEvents = persistence.incrementalEvents
            streamingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.streamAssistant(
                    runId: rawCommandID,
                    stream: incrementalEvents,
                    presentationValidator: presentationValidator)
            }
        }
        let completion = await self.waitForChatCompletion(
            runId: rawCommandID,
            stream: persistence.gatewayEvents,
            timeoutSeconds: 120)
        // Delivery confirmation belongs to the shared owner, not the Talk UI
        // lifetime. An exact final is also a useful immediate history wake.
        try? await persistence.owner.wake()
        guard self.isCurrentDurableResponse(responseGeneration) else {
            streamingTask?.cancel()
            self.cancelIncrementalSpeech()
            return
        }

        if completion.state == .aborted || completion.state == .error {
            self.statusText = completion.state == .aborted ? "Aborted" : "Chat error"
            streamingTask?.cancel()
            await self.finishIncrementalSpeech()
            await self.restartAfterDurableResponseIfNeeded(
                responseGeneration,
                restartAfter: restartAfter)
            return
        }

        var assistantText = completion.assistantText
        if assistantText == nil, shouldIncremental {
            let exactRunText = self.incrementalSpeechBuffer.latestText
            if !exactRunText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                assistantText = exactRunText
            }
        }
        guard let assistantText else {
            self.statusText = "No audible reply — text preserved in Chat"
            streamingTask?.cancel()
            await self.finishIncrementalSpeech()
            GatewayDiagnostics.log("talk: exact assistant text unavailable run_id=\(diagnosticRunID)")
            await self.restartAfterDurableResponseIfNeeded(
                responseGeneration,
                restartAfter: restartAfter)
            return
        }

        streamingTask?.cancel()
        guard self.isCurrentDurableResponse(responseGeneration) else { return }
        guard await self.isDurablePresentationAuthorized(
            persistence,
            responseGeneration: responseGeneration)
        else {
            self.cancelIncrementalSpeech()
            guard self.isCurrentDurableResponse(responseGeneration) else { return }
            self.statusText = "No audible reply — session changed"
            await self.restartAfterDurableResponseIfNeeded(
                responseGeneration,
                restartAfter: restartAfter)
            return
        }
        if shouldIncremental {
            await self.handleIncrementalAssistantFinal(
                text: assistantText,
                presentationValidator: presentationValidator,
                durableResponseGeneration: responseGeneration)
        } else {
            await self.playAssistant(
                text: assistantText,
                presentationValidator: presentationValidator,
                durableResponseGeneration: responseGeneration)
        }
        await self.restartAfterDurableResponseIfNeeded(
            responseGeneration,
            restartAfter: restartAfter)
    }

    private func waitForDurableOutcome(
        _ persistence: TalkDurableChatPersistence,
        timeoutSeconds: Int) async -> OpenClawChatOutboxOutcome?
    {
        let rawCommandID = persistence.request.rawCommandID
        let updates = persistence.outboxUpdates
        return await withTaskGroup(of: OpenClawChatOutboxOutcome?.self) { group in
            group.addTask {
                for await update in updates {
                    if Task.isCancelled { return nil }
                    if let receipt = update.terminalReceipts.first(where: {
                        $0.rawCommandID == rawCommandID
                    }) {
                        return receipt.outcome
                    }
                    if let commandIndex = update.unresolvedCommands.firstIndex(where: {
                        $0.rawCommandID == rawCommandID
                    }) {
                        let command = update.unresolvedCommands[commandIndex]
                        if command.outcome != .notDispatched || commandIndex == 0 {
                            return command.outcome
                        }
                    }
                    if let transition = update.transitions.first(where: {
                        $0.rawCommandID == rawCommandID
                    }) {
                        switch transition {
                        case .dispatched:
                            return .accepted
                        case .canonicalHistoryConfirmed:
                            return .canonicalHistoryConfirmed
                        case .blocked:
                            return .blockedRouteChanged
                        }
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                return nil
            }
            let outcome = await group.next() ?? nil
            group.cancelAll()
            return outcome
        }
    }

    private func restartAfterDurableResponseIfNeeded(
        _ responseGeneration: UInt64,
        restartAfter: Bool) async
    {
        guard restartAfter,
              self.isCurrentDurableResponse(responseGeneration),
              self.isEnabled,
              self.gatewayConnected
        else { return }
        await self.start()
    }

    private func isCurrentDurableResponse(_ generation: UInt64) -> Bool {
        !Task.isCancelled && self.foregroundAudioCaptureAllowed && self.durableResponseGeneration == generation
    }

    private func isDurablePresentationAuthorized(
        _ persistence: TalkDurableChatPersistence,
        responseGeneration: UInt64) async -> Bool
    {
        guard self.isCurrentDurableResponse(responseGeneration) else { return false }
        let tokenIsCurrent: Bool
        if let durableChatCaptureAdmissionIsCurrent {
            tokenIsCurrent = await durableChatCaptureAdmissionIsCurrent(
                persistence.request.stableGatewayID,
                persistence.request.destructiveSessionAdmissionToken)
        } else {
            tokenIsCurrent = (try? await persistence.owner.destructiveSessionAdmissionToken()) ==
                persistence.request.destructiveSessionAdmissionToken
        }
        return tokenIsCurrent && self.isCurrentDurableResponse(responseGeneration)
    }

    private func cancelDurableResponse() {
        self.durableResponseGeneration &+= 1
        self.durableResponseTask?.cancel()
        self.durableResponseTask = nil
        let speechGeneration = self.durableResponseSpeechGeneration
        self.durableResponseSpeechGeneration = nil
        if let speechGeneration, speechGeneration == self.ttsGeneration {
            self.stopSpeaking(origin: .durableResponseOwner, storeInterruption: false)
        } else {
            // Incremental Talk playback already carries exact generation ownership.
            // Retiring its worker cannot stop a newer manual generation.
            self.cancelIncrementalSpeech()
        }
    }

    private func beginTranscriptCapture(context: DurableCaptureContext) {
        self.transcriptGeneration &+= 1
        self.lastTranscript = ""
        self.lastHeard = nil
        self.durableCaptureContext = context
    }

    private func makeDurableCaptureContext() async throws -> DurableCaptureContext {
        let admittedDeliveryGeneration = self.durableDeliveryGeneration
        let admittedResponseGeneration = self.durableResponseGeneration
        let admittedSessionKey = self.mainSessionKey
        let stableGatewayID = self.durableChatGatewayOwnerID?()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stableGatewayID.isEmpty,
              self.gatewayConnected,
              self.foregroundAudioCaptureAllowed,
              !Task.isCancelled
        else {
            throw OpenClawChatOutboxError.routeSnapshotUnavailable
        }
        guard let durableChatCaptureAdmission else {
            throw OpenClawChatOutboxError.routeSnapshotUnavailable
        }
        let admission = try await durableChatCaptureAdmission()
        let currentGatewayID = self.durableChatGatewayOwnerID?()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !Task.isCancelled,
              self.gatewayConnected,
              self.foregroundAudioCaptureAllowed,
              self.durableDeliveryGeneration == admittedDeliveryGeneration,
              self.durableResponseGeneration == admittedResponseGeneration,
              self.mainSessionKey == admittedSessionKey,
              currentGatewayID == stableGatewayID
        else {
            throw CancellationError()
        }
        return DurableCaptureContext(
            rawCommandID: "talk-\(UUID().uuidString.lowercased())",
            stableGatewayID: stableGatewayID,
            sessionKey: admittedSessionKey,
            deliveryGeneration: admittedDeliveryGeneration,
            responseAdmissionGeneration: admittedResponseGeneration,
            destructiveSessionAdmissionToken: admission.destructiveSessionAdmissionToken,
            captureRouteSnapshot: admission.routeSnapshot)
    }

    private func requireCurrentPTTStart(
        captureID: String,
        context: DurableCaptureContext,
        startReservationID: UUID) async throws
    {
        try self.requireLocallyCurrentPTTStart(
            captureID: captureID,
            context: context,
            startReservationID: startReservationID)
        if let durableChatCaptureAdmissionIsCurrent {
            guard await durableChatCaptureAdmissionIsCurrent(
                context.stableGatewayID,
                context.destructiveSessionAdmissionToken)
            else {
                throw CancellationError()
            }
        }
        try self.requireLocallyCurrentPTTStart(
            captureID: captureID,
            context: context,
            startReservationID: startReservationID)
    }

    private func requireLocallyCurrentPTTStart(
        captureID: String,
        context: DurableCaptureContext,
        startReservationID: UUID) throws
    {
        guard self.foregroundAudioCaptureAllowed,
              !Task.isCancelled,
              self.gatewayConnected,
              self.pttStartReservationID == startReservationID,
              self.activePTTCaptureId == captureID,
              self.durableCaptureContext?.rawCommandID == context.rawCommandID,
              self.durableDeliveryGeneration == context.deliveryGeneration,
              self.durableChatGatewayOwnerID?() == context.stableGatewayID,
              self.mainSessionKey == context.sessionKey
        else {
            throw CancellationError()
        }
    }

    private func requestPTTMicrophonePermission() async -> Bool {
        #if DEBUG
        if let pttMicrophonePermissionOverride {
            return await pttMicrophonePermissionOverride()
        }
        #endif
        return await Self.requestMicrophonePermission()
    }

    private func requestPTTSpeechPermission() async -> Bool {
        #if DEBUG
        if let pttSpeechPermissionOverride {
            return await pttSpeechPermissionOverride()
        }
        #endif
        return await Self.requestSpeechPermission()
    }

    private func cancelPTTStartIfCurrent(captureID: String) {
        guard self.activePTTCaptureId == captureID else { return }
        self.stopSilenceMonitor()
        self.cancelPTTTimeout()
        self.activePTTCaptureId = nil
        self.durableCaptureContext = nil
        self.isPushToTalkActive = false
        self.isListening = false
        self.captureMode = .idle
        self.stopRecognition()
        self.lastTranscript = ""
        self.lastHeard = nil
        self.transcriptGeneration &+= 1
    }

    private func startRealtimeIfAvailable() async -> Bool {
        guard let gateway else { return false }
        let startedAt = Self.nowSeconds()
        if self.prefetchedRealtimeSession == nil, let prefetchTask = self.realtimePrefetchTask {
            GatewayDiagnostics.log("talk.timeline realtime awaiting in-flight prefetch")
            await prefetchTask.value
        }
        let prefetchedSession = self.consumePrefetchedRealtimeSession()
        GatewayDiagnostics.log("talk.timeline realtime start attempt sessionKey=\(self.mainSessionKey)")
        let session = TalkRealtimeWebRTCSession(
            gateway: gateway,
            sessionKey: mainSessionKey,
            delegate: self)
        self.realtimeSession = session
        do {
            try await session.start(
                provider: self.realtimeProvider,
                model: self.realtimeModelId,
                voice: self.realtimeVoiceId,
                prefetchedSession: prefetchedSession)
            guard self.realtimeSession === session, self.isEnabled else {
                session.stop()
                return true
            }
            self.isListening = true
            self.captureMode = .continuous
            self.statusText = "Listening"
            GatewayDiagnostics.log(
                "talk.timeline realtime start ready elapsedMs=\(Self.elapsedMs(since: startedAt))")
            GatewayDiagnostics.log("talk realtime: started direct OpenAI WebRTC session")
            return true
        } catch {
            guard self.realtimeSession === session, self.isEnabled else {
                session.stop()
                return true
            }
            self.stopRealtimeSession()
            GatewayDiagnostics
                .log("talk realtime: unavailable; falling back to speech pipeline error=\(error.localizedDescription)")
            GatewayDiagnostics.log(
                "talk.timeline realtime start failed elapsedMs=\(Self.elapsedMs(since: startedAt)) "
                    + "error=\(error.localizedDescription)")
            return false
        }
    }

    private func startRealtimeRelayIfAvailable() async -> Bool {
        guard let gateway else { return false }
        guard self.foregroundAudioCaptureAllowed else {
            self.statusText = "Paused"
            GatewayDiagnostics.log("talk realtime ignored: app backgrounded")
            return true
        }
        if self.realtimeRelaySession != nil {
            self.captureMode = .continuous
            self.isListening = true
            GatewayDiagnostics.log("talk realtime ignored: already active")
            return true
        }
        guard !self.realtimeRelayStartInFlight else {
            GatewayDiagnostics.log("talk realtime ignored: already starting")
            return true
        }
        self.realtimeRelayStartInFlight = true
        defer { self.realtimeRelayStartInFlight = false }
        self.realtimeRelayGeneration &+= 1
        let relayGeneration = self.realtimeRelayGeneration
        self.activeRealtimeRelayGeneration = relayGeneration
        GatewayDiagnostics.log("talk.timeline realtime relay start attempt sessionKey=\(self.mainSessionKey)")
        let startedAt = Self.nowSeconds()
        let relaySession = RealtimeTalkRelaySession(
            gateway: gateway,
            options: RealtimeTalkRelaySession.Options(
                sessionKey: self.mainSessionKey,
                provider: self.realtimeProvider,
                model: self.realtimeModelId,
                voice: self.realtimeVoiceId),
            pcmPlayer: self.pcmPlayer,
            onStatus: { [weak self] status in
                self?.handleRealtimeRelayStatus(status, generation: relayGeneration)
            },
            onSpeakingChanged: { [weak self] speaking in
                self?.handleRealtimeRelaySpeakingChanged(speaking, generation: relayGeneration)
            })
        self.realtimeRelaySession = relaySession
        do {
            try Self.configureRealtimeAudioSession()
            self.currentAudioActivation = .active
            try await relaySession.start()
            guard self.realtimeRelaySession === relaySession, self.isEnabled else {
                relaySession.stop()
                return true
            }
            self.isListening = true
            self.captureMode = .continuous
            GatewayDiagnostics.log(
                "talk.timeline realtime relay start ready elapsedMs=\(Self.elapsedMs(since: startedAt))")
            return true
        } catch {
            guard self.realtimeRelaySession === relaySession, self.isEnabled else {
                relaySession.stop()
                return true
            }
            self.stopRealtimeSession()
            GatewayDiagnostics.log(
                "talk.timeline realtime relay start failed elapsedMs=\(Self.elapsedMs(since: startedAt)) "
                    + "error=\(error.localizedDescription)")
            return false
        }
    }

    func prefetchRealtimeSessionIfReady(
        reason: String,
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute? = nil,
        shouldApply: @escaping @MainActor @Sendable () -> Bool = { true }) async
    {
        guard self.gatewayConnected,
              self.realtimeSession == nil,
              self.realtimeRelaySession == nil,
              !self.isEnabled
        else { return }
        guard self.realtimeWebRTCEnabled, self.executionMode != .realtimeRelay else { return }
        guard self.gatewayTalkPermissionState == .ready else { return }
        guard self.consumePrefetchedRealtimeSession(peekOnly: true) == nil else { return }
        guard self.realtimePrefetchTask == nil else { return }
        guard shouldApply() else { return }

        GatewayDiagnostics.log("talk.timeline realtime prefetch scheduled reason=\(reason)")
        self.realtimePrefetchGeneration &+= 1
        let prefetchGeneration = self.realtimePrefetchGeneration
        self.realtimePrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.realtimePrefetchGeneration == prefetchGeneration {
                    self.realtimePrefetchTask = nil
                }
            }
            let startedAt = Self.nowSeconds()
            do {
                guard !Task.isCancelled, shouldApply(), let gateway = self.gateway else { return }
                let route: GatewayNodeSessionRoute
                if let expectedRoute {
                    route = expectedRoute
                } else {
                    guard let currentRoute = await gateway.currentRoute() else { return }
                    route = currentRoute
                }
                guard !Task.isCancelled,
                      shouldApply(),
                      await gateway.isCurrentRoute(route)
                else { return }
                let session = try await self.createRealtimeClientSession(
                    gateway: gateway,
                    route: route,
                    provider: self.realtimeProvider,
                    model: self.realtimeModelId,
                    voice: self.realtimeVoiceId)
                guard !Task.isCancelled,
                      shouldApply(),
                      await gateway.isCurrentRoute(route)
                else { return }
                self.prefetchedRealtimeSession = session
                GatewayDiagnostics.log(
                    "talk.timeline realtime prefetch ready elapsedMs=\(Self.elapsedMs(since: startedAt)) "
                        + "model=\(session.model ?? "unknown") voice=\(session.voice ?? "unknown")")
            } catch {
                guard !Task.isCancelled, shouldApply() else { return }
                GatewayDiagnostics.log(
                    "talk.timeline realtime prefetch failed elapsedMs=\(Self.elapsedMs(since: startedAt)) "
                        + "error=\(error.localizedDescription)")
            }
        }
    }

    private func createRealtimeClientSession(
        gateway: GatewayNodeSession,
        route: GatewayNodeSessionRoute,
        provider: String?,
        model: String?,
        voice: String?) async throws -> TalkRealtimeClientSession
    {
        let params = TalkRealtimeClientCreateParams(provider: provider, model: model, voice: voice)
        let data = try JSONEncoder().encode(params)
        let json = String(data: data, encoding: .utf8)
        let res = try await gateway.request(
            method: "talk.client.create",
            paramsJSON: json,
            timeoutSeconds: 12,
            ifCurrentRoute: route)
        return try JSONDecoder().decode(TalkRealtimeClientSession.self, from: res)
    }

    private func consumePrefetchedRealtimeSession(peekOnly: Bool = false) -> TalkRealtimeClientSession? {
        guard let session = self.prefetchedRealtimeSession else { return nil }
        if let expiresAt = session.expiresAt {
            let usableUntil = expiresAt - Self.realtimePrefetchExpiryLeewaySeconds
            if Date().timeIntervalSince1970 >= usableUntil {
                GatewayDiagnostics.log("talk.timeline realtime prefetched session expired")
                self.prefetchedRealtimeSession = nil
                return nil
            }
        }
        if !peekOnly {
            self.prefetchedRealtimeSession = nil
            GatewayDiagnostics.log(
                "talk.timeline realtime using prefetched session model=\(session.model ?? "unknown") "
                    + "voice=\(session.voice ?? "unknown")")
        }
        return session
    }

    private func stopRealtimeSession() {
        let realtimeSession = self.realtimeSession
        self.realtimeSession = nil
        self.realtimeRelayGeneration &+= 1
        self.activeRealtimeRelayGeneration = nil
        let realtimeRelaySession = self.realtimeRelaySession
        self.realtimeRelaySession = nil
        realtimeSession?.stop()
        realtimeRelaySession?.stop()
    }

    private func handleRealtimeRelayStatus(_ status: String, generation: UInt64) {
        guard self.activeRealtimeRelayGeneration == generation else { return }
        self.statusText = status
        self.isListening = status.localizedCaseInsensitiveContains("listening")
        if status.localizedCaseInsensitiveContains("thinking") {
            self.isListening = false
            self.isSpeaking = false
            self.isUserSpeechDetected = false
        }
    }

    private func handleRealtimeRelaySpeakingChanged(_ speaking: Bool, generation: UInt64) {
        guard self.activeRealtimeRelayGeneration == generation else { return }
        self.isSpeaking = speaking
        if speaking {
            self.isListening = false
        }
    }

    private func subscribeChatIfNeeded(sessionKey: String) async {
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard !self.chatSubscribedSessionKeys.contains(key) else { return }

        // Operator clients receive chat events without node-style subscriptions.
        self.chatSubscribedSessionKeys.insert(key)
    }

    private func unsubscribeAllChats() async {
        self.chatSubscribedSessionKeys.removeAll()
    }

    private func buildPrompt(transcript: String) -> String {
        let interrupted = self.lastInterruptedAtSeconds
        self.lastInterruptedAtSeconds = nil
        return TalkPromptBuilder.build(
            transcript: transcript,
            interruptedAtSeconds: interrupted,
            includeVoiceDirectiveHint: false)
    }

    private enum ChatCompletionState: CustomStringConvertible {
        case final
        case aborted
        case error
        case timeout

        var description: String {
            switch self {
            case .final: "final"
            case .aborted: "aborted"
            case .error: "error"
            case .timeout: "timeout"
            }
        }
    }

    private struct ChatCompletionResult {
        var state: ChatCompletionState
        var assistantText: String?
    }

    private func waitForChatCompletion(
        runId: String,
        stream: AsyncStream<EventFrame>,
        timeoutSeconds: Int = 120) async -> ChatCompletionResult
    {
        #if DEBUG
        let durableEventObserved = self.durableEventObservedOverride
        #endif
        return await withTaskGroup(of: ChatCompletionResult.self) { group in
            group.addTask { [runId] in
                var latestAssistantText: String?
                for await evt in stream {
                    if Task.isCancelled {
                        return ChatCompletionResult(state: .timeout, assistantText: latestAssistantText)
                    }
                    guard let payload = evt.payload else { continue }
                    if evt.event == "chat" {
                        guard let chatEvent = try? GatewayPayloadDecoding.decode(
                            payload,
                            as: OpenClawChatEventPayload.self)
                        else {
                            continue
                        }
                        #if DEBUG
                        durableEventObserved?(chatEvent.runId, chatEvent.runId == runId)
                        #endif
                        guard chatEvent.runId == runId else { continue }
                        if let text = OpenClawChatEventText.assistantText(from: chatEvent) {
                            latestAssistantText = text
                        }
                        switch chatEvent.state {
                        case "final":
                            return ChatCompletionResult(state: .final, assistantText: latestAssistantText)
                        case "aborted":
                            return ChatCompletionResult(state: .aborted, assistantText: nil)
                        case "error":
                            return ChatCompletionResult(state: .error, assistantText: nil)
                        default:
                            break
                        }
                    } else if evt.event == "agent" {
                        guard let agentEvent = try? GatewayPayloadDecoding.decode(
                            payload,
                            as: OpenClawAgentEventPayload.self)
                        else {
                            continue
                        }
                        #if DEBUG
                        durableEventObserved?(agentEvent.runId, agentEvent.runId == runId)
                        #endif
                        guard agentEvent.runId == runId else { continue }
                        if agentEvent.stream == "assistant",
                           let text = agentEvent.data["text"]?.value as? String
                        {
                            latestAssistantText = text
                        } else if agentEvent.stream == "lifecycle" {
                            let phase = (agentEvent.data["phase"]?.value as? String)?.lowercased()
                            let status = (agentEvent.data["status"]?.value as? String)?.lowercased()
                            if phase == "end" || status == "ok" || status == "completed" || status == "success" {
                                return ChatCompletionResult(state: .final, assistantText: latestAssistantText)
                            }
                            if phase == "error" || status == "error" || status == "failed" {
                                return ChatCompletionResult(state: .error, assistantText: nil)
                            }
                            if phase == "aborted" || status == "aborted" || status == "cancelled" {
                                return ChatCompletionResult(state: .aborted, assistantText: nil)
                            }
                        }
                    }
                }
                return ChatCompletionResult(state: .timeout, assistantText: latestAssistantText)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                return ChatCompletionResult(state: .timeout, assistantText: nil)
            }
            let result = await group.next() ?? ChatCompletionResult(state: .timeout, assistantText: nil)
            group.cancelAll()
            return result
        }
    }

    private func playAssistant(
        text: String,
        presentationValidator: @escaping SpeechPresentationValidator,
        durableResponseGeneration: UInt64? = nil) async
    {
        guard await self.isSpeechPresentationAuthorized(presentationValidator) else { return }
        let parsed = TalkDirectiveParser.parse(text)
        let directive = parsed.directive
        let cleaned = parsed.stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let language = ElevenLabsTTSClient.validatedLanguage(directive?.language)
        let requestedVoice = directive?.voiceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVoice = self.resolveVoiceAlias(requestedVoice)
        if requestedVoice?.isEmpty == false, resolvedVoice == nil {
            self.logger.warning("unknown voice alias requested")
        }
        let apiKey = self.resolvedElevenLabsAPIKey()
        let preferredVoice = resolvedVoice ?? self.currentVoiceId ?? self.defaultVoiceId
        let voiceID: String? = if let apiKey, !apiKey.isEmpty {
            await self.resolveVoiceId(preferred: preferredVoice, apiKey: apiKey)
        } else {
            nil
        }
        #if DEBUG
        await self.durablePresentationBeforePlaybackOverride?()
        #endif
        guard await self.isSpeechPresentationAuthorized(presentationValidator) else { return }
        self.applyDirective(directive)
        self.statusText = "Generating voice…"
        self.isSpeaking = true
        self.lastSpokenText = cleaned
        let modelID = directive?.modelId ?? self.currentModelId ?? self.defaultModelId
        let desiredOutputFormat = (directive?.outputFormat ?? self.defaultOutputFormat)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outputFormat = ElevenLabsTTSClient.validatedOutputFormat(
            desiredOutputFormat?.isEmpty == false ? desiredOutputFormat : self.effectiveDefaultOutputFormat)
        let attempts = self.makeTTSProviderAttempts(
            text: cleaned,
            directive: directive,
            language: language,
            apiKey: apiKey,
            voiceID: voiceID,
            modelID: modelID,
            outputFormat: outputFormat)

        if attempts.initial != nil {
            self.applyVoiceModeDescriptor(TalkVoiceModeDescriptorBuilder.build(
                providerId: "elevenlabs",
                providerLabel: Self.displayName(forProvider: "elevenlabs"),
                modelId: modelID,
                voiceId: voiceID,
                transport: "native",
                isRealtime: false))
        } else {
            self.applyVoiceModeDescriptor(TalkVoiceModeDescriptorBuilder.build(
                providerId: "system",
                providerLabel: Self.displayName(forProvider: "system"),
                modelId: nil,
                voiceId: language,
                transport: "native",
                isRealtime: false))
        }
        self.startSpeechInterruptionRecognitionIfNeeded()
        let generation = self.beginTTSGeneration()
        if durableResponseGeneration != nil {
            self.durableResponseSpeechGeneration = generation
        }
        defer {
            if self.durableResponseSpeechGeneration == generation {
                self.durableResponseSpeechGeneration = nil
            }
        }
        self.currentPlaybackProvider = attempts.initial == nil ? .system : .elevenLabs
        self.lastPlaybackWasPCM = attempts.initial.flatMap {
            TalkTTSValidation.pcmSampleRate(from: $0.outputFormat)
        } != nil
        let result = await self.makeTTSPlaybackPipeline(generation: generation).speak(
            text: cleaned,
            language: language,
            providerAttempt: attempts.initial,
            mp3Retry: attempts.mp3)
        if attempts.initial == nil, result.succeeded {
            self.updateTTSDiagnostics(TalkTTSProgress(
                state: .completed,
                userMessage: self.elevenLabsUnavailableMessage(
                    apiKeyPresent: apiKey?.isEmpty == false,
                    voiceIDPresent: voiceID?.isEmpty == false)), generation: generation)
        }
        self.finalizeTTSGeneration(
            generation,
            statusText: result.succeeded ? "Ready" : "Speech failed — text reply preserved",
            stopRecognition: true)
    }

    private func resolvedElevenLabsAPIKey() -> String? {
        let configuredKey = self.apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false ? self.apiKey : nil
        #if DEBUG
        let resolvedKey = configuredKey ?? ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
        #else
        let resolvedKey = configuredKey
        #endif
        return resolvedKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeElevenLabsTTSRequest(
        text: String,
        directive: TalkDirective?,
        modelId: String?,
        outputFormat: String?,
        language: String?) -> ElevenLabsTTSRequest
    {
        ElevenLabsTTSRequest(
            text: text,
            modelId: modelId,
            outputFormat: outputFormat,
            speed: TalkTTSValidation.resolveSpeed(speed: directive?.speed, rateWPM: directive?.rateWPM),
            stability: TalkTTSValidation.validatedStability(directive?.stability, modelId: modelId),
            similarity: TalkTTSValidation.validatedUnit(directive?.similarity),
            style: TalkTTSValidation.validatedUnit(directive?.style),
            speakerBoost: directive?.speakerBoost,
            seed: TalkTTSValidation.validatedSeed(directive?.seed),
            normalize: ElevenLabsTTSClient.validatedNormalize(directive?.normalize),
            language: language,
            latencyTier: TalkTTSValidation.validatedLatencyTier(directive?.latencyTier))
    }

    func testSystemVoice() async {
        let generation = self.beginTTSGeneration()
        self.currentPlaybackProvider = .system
        self.lastPlaybackWasPCM = false
        self.isSpeaking = true
        let result = await self.makeTTSPlaybackPipeline(generation: generation).speak(
            text: TalkTTSTestPhrase.system,
            language: nil,
            providerAttempt: nil,
            mp3Retry: nil)
        self.finalizeTTSGeneration(
            generation,
            statusText: result.succeeded
                ? "System voice test completed"
                : "Speech failed — text reply preserved")
    }

    func testElevenLabsVoice() async {
        if !self.gatewayTalkConfigLoaded {
            await self.reloadConfig()
        }
        let text = TalkTTSTestPhrase.elevenLabs
        let apiKey = self.resolvedElevenLabsAPIKey()
        let voiceID: String? = if let apiKey, !apiKey.isEmpty {
            await self.resolveVoiceId(preferred: self.currentVoiceId ?? self.defaultVoiceId, apiKey: apiKey)
        } else {
            nil
        }
        let outputFormat = ElevenLabsTTSClient.validatedOutputFormat(self.effectiveDefaultOutputFormat)
        let attempts = self.makeTTSProviderAttempts(
            text: text,
            directive: nil,
            language: nil,
            apiKey: apiKey,
            voiceID: voiceID,
            modelID: self.currentModelId ?? self.defaultModelId,
            outputFormat: outputFormat)
        let generation = self.beginTTSGeneration()
        self.currentPlaybackProvider = attempts.initial == nil ? .system : .elevenLabs
        self.lastPlaybackWasPCM = attempts.initial.flatMap {
            TalkTTSValidation.pcmSampleRate(from: $0.outputFormat)
        } != nil
        self.isSpeaking = true
        let result = await self.makeTTSPlaybackPipeline(generation: generation).speak(
            text: text,
            language: nil,
            providerAttempt: attempts.initial,
            mp3Retry: attempts.mp3)
        if attempts.initial == nil, result.succeeded {
            self.updateTTSDiagnostics(TalkTTSProgress(
                state: .completed,
                userMessage: self.elevenLabsUnavailableMessage(
                    apiKeyPresent: apiKey?.isEmpty == false,
                    voiceIDPresent: voiceID?.isEmpty == false)), generation: generation)
        }
        self.finalizeTTSGeneration(
            generation,
            statusText: result.succeeded ? "Voice test completed" : "Speech failed — text reply preserved")
    }

    func speakSystemNotificationText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let generation = self.beginTTSGeneration()
        self.currentPlaybackProvider = .system
        self.lastPlaybackWasPCM = false
        self.isSpeaking = true
        _ = await self.makeTTSPlaybackPipeline(generation: generation).speak(
            text: trimmed,
            language: nil,
            providerAttempt: nil,
            mp3Retry: nil)
        self.finalizeTTSGeneration(generation)
    }

    private func makeTTSProviderAttempts(
        text: String,
        directive: TalkDirective?,
        language: String?,
        apiKey: String?,
        voiceID: String?,
        modelID: String?,
        outputFormat: String?) -> TTSProviderAttempts
    {
        guard let apiKey, !apiKey.isEmpty, let voiceID, !voiceID.isEmpty else {
            return TTSProviderAttempts(initial: nil, mp3: nil)
        }
        let client = ElevenLabsTTSClient(apiKey: apiKey)
        let initialRequest = self.makeElevenLabsTTSRequest(
            text: text,
            directive: directive,
            modelId: modelID,
            outputFormat: outputFormat,
            language: language)
        let initialResponseEvidence = ElevenLabsTTSResponseEvidence()
        let initial = TalkTTSProviderAttempt(
            outputFormat: outputFormat,
            responseEvidence: initialResponseEvidence) {
            client.streamSynthesize(
                voiceId: voiceID,
                request: initialRequest,
                responseEvidence: initialResponseEvidence)
        }
        guard TalkTTSValidation.pcmSampleRate(from: outputFormat) != nil else {
            return TTSProviderAttempts(initial: initial, mp3: nil)
        }
        let mp3Format = ElevenLabsTTSClient.validatedOutputFormat("mp3_44100_128")
        let mp3Request = self.makeElevenLabsTTSRequest(
            text: text,
            directive: directive,
            modelId: modelID,
            outputFormat: mp3Format,
            language: language)
        let mp3ResponseEvidence = ElevenLabsTTSResponseEvidence()
        let mp3 = TalkTTSProviderAttempt(
            outputFormat: mp3Format,
            responseEvidence: mp3ResponseEvidence) {
            client.streamSynthesize(
                voiceId: voiceID,
                request: mp3Request,
                responseEvidence: mp3ResponseEvidence)
        }
        return TTSProviderAttempts(initial: initial, mp3: mp3)
    }

    private func elevenLabsUnavailableMessage(apiKeyPresent: Bool, voiceIDPresent: Bool) -> String {
        let permissionRequired: Bool
        if case .missingScope = self.gatewayTalkPermissionState {
            permissionRequired = true
        } else {
            permissionRequired = false
        }
        return TalkTTSAvailabilityMessage.elevenLabsUnavailable(
            permissionRequired: permissionRequired,
            configLoaded: self.gatewayTalkConfigLoaded,
            apiKeyPresent: apiKeyPresent,
            voiceIDPresent: voiceIDPresent)
    }

    private func makeTTSPlaybackPipeline(generation: UInt64) -> TalkTTSPlaybackPipeline {
        TalkTTSPlaybackPipeline(
            pcmPlayer: self.pcmPlayer,
            mp3Player: self.mp3Player,
            systemSpeech: self.systemSpeech,
            prepareAudio: { [weak self] in
                guard let self else {
                    throw NSError(domain: "TalkTTS", code: 1)
                }
                return try self.prepareAudioSessionForLocalSpeech(ownerGeneration: generation)
            },
            isCurrent: { [weak self] in self?.ttsGeneration == generation },
            report: { [weak self] progress in
                self?.updateTTSDiagnostics(progress, generation: generation)
            },
            breadcrumb: { [weak self] breadcrumb in
                self?.recordTTSBreadcrumb(breadcrumb, generation: generation)
            },
            playbackObserver: StreamingPlaybackObserver { observation in
                Self.recordTTSPlaybackObservation(observation, generation: generation)
            },
            lifecycleObserver: { observation in
                Self.recordTTSLifecycleObservation(observation, generation: generation)
            })
    }

    private func beginTTSGeneration() -> UInt64 {
        if let activeTTSGeneration {
            TalkAudioSessionDiagnostics.recordStopRequested(
                origin: .providerReplacement,
                generation: activeTTSGeneration,
                activeGeneration: self.activeTTSGeneration,
                ownerGeneration: self.audioSessionOwnerGeneration,
                currentPortTypes: self.currentAudioPortTypes)
            self.recordTTSBreadcrumb(
                TalkTTSBreadcrumb(stage: .generationCancelled, detail: "replaced"),
                generation: activeTTSGeneration)
        }
        _ = self.pcmPlayer.stop()
        _ = self.mp3Player.stop()
        self.systemSpeech.stop()
        self.ttsGeneration &+= 1
        self.activeTTSGeneration = self.ttsGeneration
        self.currentPlaybackProvider = .none
        self.ttsDiagnostics.providerAttemptOutcome = .notAttempted
        self.ttsDiagnostics.finalProvider = .none
        self.ttsDiagnostics.finalOutcome = .notAttempted
        self.ttsDiagnostics.firstAudioByteReceived = false
        self.ttsDiagnostics.totalAudioBytes = 0
        self.ttsDiagnostics.pcmSampleRate = nil
        self.ttsDiagnostics.durationMilliseconds = nil
        self.recordTTSBreadcrumb(
            TalkTTSBreadcrumb(stage: .requestAdmitted),
            generation: self.ttsGeneration)
        return self.ttsGeneration
    }

    private func cancelTTSGeneration() {
        if let activeTTSGeneration {
            self.recordTTSBreadcrumb(
                TalkTTSBreadcrumb(stage: .generationCancelled),
                generation: activeTTSGeneration)
        }
        self.activeTTSGeneration = nil
        self.ttsGeneration &+= 1
    }

    /// Only the generation that still owns speech may tear down its audio/session UI state.
    /// A replaced task can resume late after cancellation; letting it finalize would stop its replacement.
    private func finalizeTTSGeneration(
        _ generation: UInt64,
        statusText: String? = nil,
        stopRecognition: Bool = false,
        keepSpeaking: Bool = false)
    {
        guard self.ttsGeneration == generation else { return }
        if let statusText {
            self.statusText = statusText
        }
        if stopRecognition {
            self.stopRecognition()
        }
        if !keepSpeaking {
            self.isSpeaking = false
        }
        self.recordTTSBreadcrumb(
            TalkTTSBreadcrumb(stage: .audioSessionRestoreStarted),
            generation: generation)
        self.restoreAudioSessionAfterLocalSpeech(ownerGeneration: generation)
        self.restoreConfiguredVoiceModeDescriptor()
        self.recordTTSBreadcrumb(
            TalkTTSBreadcrumb(stage: .generationFinalized),
            generation: generation)
        self.activeTTSGeneration = nil
    }

    private func updateTTSDiagnostics(_ progress: TalkTTSProgress, generation: UInt64? = nil) {
        if let generation, generation != self.ttsGeneration { return }
        self.ttsDiagnostics.apply(progress)
        if progress.pcmFormatRejected == true { self.pcmFormatUnavailable = true }
        if progress.state == .mp3Retry { self.lastPlaybackWasPCM = false }
        if progress.state == .systemFallback {
            self.currentPlaybackProvider = .system
            self.lastPlaybackWasPCM = false
            self.applyVoiceModeDescriptor(TalkVoiceModeDescriptorBuilder.build(
                providerId: "system",
                providerLabel: Self.displayName(forProvider: "system"),
                modelId: nil,
                voiceId: nil,
                transport: "native",
                isRealtime: false))
        }

        let providerOutcome = self.ttsDiagnostics.providerAttemptOutcome.rawValue
        let finalOutcome = self.ttsDiagnostics.finalOutcome.rawValue
        let finalProvider = self.ttsDiagnostics.finalProvider.rawValue
        let bytes = self.ttsDiagnostics.totalAudioBytes
        let sampleRate = self.ttsDiagnostics.pcmSampleRate ?? 0
        let duration = self.ttsDiagnostics.durationMilliseconds ?? 0
        GatewayDiagnostics.log(
            "talk tts state=\(progress.state.rawValue) providerOutcome=\(providerOutcome) "
                + "finalProvider=\(finalProvider) finalOutcome=\(finalOutcome) bytes=\(bytes) "
                + "sampleRate=\(sampleRate) durationMs=\(duration)")
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: "tts_\(progress.state.rawValue)",
            playbackGeneration: generation,
            cancellationGeneration: generation,
            operationIdentifier: generation.map { "tts-generation-\($0)" },
            operationGeneration: generation,
            diagnosticAttemptID: generation.map { "tts-generation-\($0)" },
            provider: Self.sanitizedDiagnosticToken(
                self.currentPlaybackProvider.rawValue,
                fallback: "unknown"),
            providerStage: progress.state.rawValue,
            codec: self.currentPlaybackProvider == .elevenLabs
                ? (self.lastPlaybackWasPCM ? "pcm" : "mp3")
                : "system_speech",
            playbackPath: self.currentPlaybackProvider == .elevenLabs
                ? (self.lastPlaybackWasPCM ? "pcm" : "mp3")
                : "system",
            resultClass: progress.finalOutcome?.rawValue ?? progress.providerAttemptOutcome?.rawValue,
            byteCount: progress.totalAudioBytes,
            sampleRate: progress.pcmSampleRate,
            durationMilliseconds: progress.durationMilliseconds))
    }

    private func recordTTSBreadcrumb(_ breadcrumb: TalkTTSBreadcrumb, generation: UInt64) {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: breadcrumb.stage.rawValue,
            playbackGeneration: generation,
            cancellationGeneration: generation,
            operationIdentifier: "tts-generation-\(generation)",
            operationGeneration: generation,
            diagnosticAttemptID: "tts-generation-\(generation)",
            provider: Self.providerToken(for: breadcrumb),
            providerStage: breadcrumb.stage.rawValue,
            codec: Self.codecToken(for: breadcrumb),
            playbackPath: Self.playbackPathToken(for: breadcrumb),
            resultClass: Self.resultClassToken(for: breadcrumb),
            byteCount: breadcrumb.byteCount,
            sampleRate: breadcrumb.sampleRate,
            durationMilliseconds: breadcrumb.durationMilliseconds))
        if breadcrumb.stage.requestsDurableWrite {
            GatewayDiagnostics.requestFlush()
        }
    }

    nonisolated static func recordTTSPlaybackObservation(
        _ observation: StreamingPlaybackObservation,
        generation: UInt64,
        flush: @Sendable () -> Void = { GatewayDiagnostics.requestFlush() })
    {
        let resultClass: String? = switch observation.stage {
        case .playbackCompleted: "success"
        case .playbackFailed: "failed"
        case .playbackCancelled: "cancelled"
        case .decoderCreated,
             .playerInstanceCreated,
             .playerInstanceDeallocated,
             .playbackSubmissionStarted,
             .playbackSubmissionAccepted,
             .firstRenderCallbackObserved:
            nil
        }
        let attempt = "tts-generation-\(generation)"
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: "tts_\(observation.stage.rawValue)",
            playbackGeneration: generation,
            cancellationGeneration: generation,
            operationIdentifier: attempt,
            operationGeneration: generation,
            diagnosticAttemptID: attempt,
            provider: "elevenlabs",
            providerStage: observation.stage.rawValue,
            codec: observation.path.rawValue,
            playbackPath: observation.path.rawValue,
            resultClass: resultClass))
        flush()
    }

    nonisolated static func recordTTSLifecycleObservation(
        _ observation: TalkTTSLifecycleObservation,
        generation: UInt64,
        flush: @Sendable () -> Void = { GatewayDiagnostics.requestFlush() })
    {
        let attempt = "tts-generation-\(generation)"
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: observation.stage.rawValue,
            playbackGeneration: generation,
            cancellationGeneration: generation,
            operationIdentifier: attempt,
            operationGeneration: generation,
            diagnosticAttemptID: attempt,
            provider: observation.provider,
            providerStage: observation.providerStage,
            codec: observation.codec,
            playbackPath: observation.playbackPath,
            resultClass: observation.resultClass,
            requestedOutputFormat: observation.requestedOutputFormat,
            httpStatus: observation.httpStatus,
            contentType: observation.contentType,
            contentEncoding: observation.contentEncoding,
            declaredByteCount: observation.declaredByteCount,
            receivedByteCount: observation.receivedByteCount,
            byteCountParity: observation.byteCountParity.flatMap {
                OpenClawDiagnosticAudioByteParity(rawValue: $0.rawValue)
            },
            audioMagicType: observation.audioMagicType.flatMap {
                OpenClawDiagnosticAudioMagicType(rawValue: $0.rawValue)
            },
            byteCount: observation.byteCount))
        flush()
    }

    private nonisolated static func providerToken(for breadcrumb: TalkTTSBreadcrumb) -> String? {
        switch breadcrumb.stage {
        case .providerRequestStarted,
             .decoderSelected,
             .playerCallEntered,
             .firstAudioByte,
             .playerCallReturned,
             .providerResult:
            "elevenlabs"
        case .systemSpeechCallEntered,
             .playbackStarted:
            "system"
        case .playbackCompleted,
             .playbackFailed:
            breadcrumb.detail == "system" ? "system" : "elevenlabs"
        case .requestAdmitted,
             .playbackPipelineEntered,
             .audioSessionPrepareStarted,
             .audioSessionPrepared,
             .audioSessionPrepareFailed,
             .fallbackTransition,
             .audioSessionRestoreStarted,
             .generationCancelled,
             .generationFinalized:
            nil
        }
    }

    private nonisolated static func codecToken(for breadcrumb: TalkTTSBreadcrumb) -> String? {
        switch breadcrumb.stage {
        case .providerRequestStarted:
            breadcrumb.detail
        case .decoderSelected,
             .playerCallEntered,
             .firstAudioByte:
            breadcrumb.detail
        case .systemSpeechCallEntered,
             .playbackStarted:
            "system_speech"
        case .requestAdmitted,
             .playbackPipelineEntered,
             .audioSessionPrepareStarted,
             .audioSessionPrepared,
             .audioSessionPrepareFailed,
             .playerCallReturned,
             .providerResult,
             .fallbackTransition,
             .playbackCompleted,
             .playbackFailed,
             .audioSessionRestoreStarted,
             .generationCancelled,
             .generationFinalized:
            nil
        }
    }

    private nonisolated static func playbackPathToken(for breadcrumb: TalkTTSBreadcrumb) -> String? {
        let token = breadcrumb.detail?.lowercased()
        if token == "pcm" || token?.hasPrefix("pcm_") == true { return "pcm" }
        if token == "mp3" || token?.hasPrefix("mp3_") == true { return "mp3" }
        if token == "system" || breadcrumb.stage == .systemSpeechCallEntered { return "system" }
        return nil
    }

    private nonisolated static func resultClassToken(for breadcrumb: TalkTTSBreadcrumb) -> String? {
        switch breadcrumb.stage {
        case .providerResult:
            breadcrumb.detail
        case .playbackCompleted:
            "success"
        case .playbackFailed:
            "failed"
        case .generationCancelled:
            "cancelled"
        case .requestAdmitted,
             .playbackPipelineEntered,
             .audioSessionPrepareStarted,
             .audioSessionPrepared,
             .audioSessionPrepareFailed,
             .providerRequestStarted,
             .decoderSelected,
             .playerCallEntered,
             .firstAudioByte,
             .playerCallReturned,
             .fallbackTransition,
             .systemSpeechCallEntered,
             .playbackStarted,
             .audioSessionRestoreStarted,
             .generationFinalized:
            nil
        }
    }

    private func recordTTSConfigEvidence() {
        let config = self.ttsDiagnostics.config
        GatewayDiagnostics.log(
            "talk tts config loaded=\(config.loaded) secrets=\(config.secretsAccess.rawValue) "
                + "provider=\(config.provider) modelPresent=\(config.modelPresent) "
                + "voiceIdPresent=\(config.voiceIDPresent) apiKeyPresent=\(config.apiKeyPresent) "
                + "credentialSource=\(config.credentialSource.rawValue) "
                + "credentialOwner=\(config.credentialOwnership.rawValue) "
                + "operatorTalkSecrets=\(config.operatorTalkSecrets.rawValue)")
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: "tts_config_\(config.secretsAccess.rawValue)",
            provider: Self.diagnosticProviderToken(config.provider)))
    }

    private func prepareAudioSessionForLocalSpeech(ownerGeneration: UInt64) throws -> TalkAudioRouteEvidence {
        self.audioSessionOwnerGeneration = ownerGeneration
        #if DEBUG
        if let ttsPrepareAudioOverride {
            do {
                return try ttsPrepareAudioOverride()
            } catch {
                if self.audioSessionOwnerGeneration == ownerGeneration {
                    self.audioSessionOwnerGeneration = nil
                }
                throw error
            }
        }
        #endif
        do {
            try Self.configureLocalSpeechAudioSession()
        } catch {
            if self.audioSessionOwnerGeneration == ownerGeneration {
                self.audioSessionOwnerGeneration = nil
            }
            throw error
        }
        self.currentAudioActivation = .active
        let evidence = self.currentAudioRouteEvidence
        self.ttsDiagnostics.route = evidence
        GatewayDiagnostics.log(
            "talk tts route category=\(evidence.category) mode=\(evidence.mode) "
                + "activation=\(evidence.activation.rawValue) speakerphone=\(evidence.speakerphonePreferred) "
                + "outputs=\(evidence.outputPortTypes.joined(separator: ","))")
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .route,
            state: "tts_route_prepared",
            connectionRole: .operator))
        return evidence
    }

    private func restoreAudioSessionAfterLocalSpeech(ownerGeneration: UInt64) {
        TalkAudioSessionDiagnostics.recordRestore(
            .requested,
            ownerGeneration: ownerGeneration,
            activeGeneration: self.activeTTSGeneration,
            currentPortTypes: self.currentAudioPortTypes)
        #if DEBUG
        if let ttsRestoreAudioOverride {
            ttsRestoreAudioOverride()
            TalkAudioSessionDiagnostics.recordRestore(
                .completed,
                ownerGeneration: ownerGeneration,
                activeGeneration: self.activeTTSGeneration,
                currentPortTypes: self.currentAudioPortTypes)
            if self.audioSessionOwnerGeneration == ownerGeneration {
                self.audioSessionOwnerGeneration = nil
            }
            return
        }
        #endif
        var restoreSucceeded = true
        if self.hasActiveAudioCapture {
            do {
                try Self.configureAudioSession()
                self.currentAudioActivation = .active
            } catch {
                restoreSucceeded = false
                self.currentAudioActivation = .unknown
                GatewayDiagnostics.log("talk tts capture restore failed")
            }
        } else {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                self.currentAudioActivation = .inactive
            } catch {
                restoreSucceeded = false
                self.currentAudioActivation = .unknown
                GatewayDiagnostics.log("talk tts audio deactivation failed")
            }
        }
        self.ttsDiagnostics.route = self.currentAudioRouteEvidence
        TalkAudioSessionDiagnostics.recordRestore(
            restoreSucceeded ? .completed : .failed,
            ownerGeneration: ownerGeneration,
            activeGeneration: self.activeTTSGeneration,
            currentPortTypes: self.currentAudioPortTypes)
        if self.audioSessionOwnerGeneration == ownerGeneration {
            self.audioSessionOwnerGeneration = nil
        }
    }

    private var currentAudioPortTypes: [String] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
    }

    private func audioSessionCallbackContext(
        callbackGeneration: UInt64?
    ) -> TalkAudioSessionDiagnostics.CallbackContext {
        TalkAudioSessionDiagnostics.CallbackContext(
            callbackGeneration: callbackGeneration,
            activeGeneration: self.activeTTSGeneration,
            ownerGeneration: self.audioSessionOwnerGeneration)
    }

    private func handleAudioRouteChange(
        reasonValue: UInt,
        previousPortTypes: [String]?,
        callbackGeneration: UInt64?)
    {
        if self.isSpeechOutputActive {
            self.ttsDiagnostics.route = self.currentAudioRouteEvidence
        }
        TalkAudioSessionDiagnostics.recordRouteChange(
            reasonValue: reasonValue,
            previousPortTypes: previousPortTypes,
            currentPortTypes: self.currentAudioPortTypes,
            context: self.audioSessionCallbackContext(callbackGeneration: callbackGeneration))
    }

    private func handleAudioSessionInterruption(
        typeValue: UInt,
        reasonValue: UInt?,
        optionValue: UInt,
        callbackGeneration: UInt64?)
    {
        TalkAudioSessionDiagnostics.recordInterruption(
            typeValue: typeValue,
            reasonValue: reasonValue,
            optionValue: optionValue,
            currentPortTypes: self.currentAudioPortTypes,
            context: self.audioSessionCallbackContext(callbackGeneration: callbackGeneration))
    }

    private func handleAudioMediaServicesNotification(
        reset: Bool,
        callbackGeneration: UInt64?)
    {
        TalkAudioSessionDiagnostics.recordMediaServices(
            reset: reset,
            currentPortTypes: self.currentAudioPortTypes,
            context: self.audioSessionCallbackContext(callbackGeneration: callbackGeneration))
    }

    private static func diagnosticProviderToken(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "elevenlabs": "elevenlabs"
        case "system": "system"
        default: "unknown"
        }
    }

    private static func sanitizedDiagnosticToken(_ raw: String, fallback: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safe = normalized.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "_"
        }
        let token = String(safe.prefix(48))
        return token.isEmpty ? fallback : token
    }

    private func startSpeechInterruptionRecognitionIfNeeded() {
        guard self.interruptOnSpeech else { return }
        do {
            try self.startRecognition()
        } catch {
            self.logger.warning("startRecognition during speak failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopSpeaking(
        origin: OpenClawDiagnosticTTSCancellationOrigin,
        storeInterruption: Bool = true)
    {
        let stoppedGeneration = self.activeTTSGeneration
        let stoppedGenerationOwnedAudioSession = stoppedGeneration != nil &&
            self.audioSessionOwnerGeneration == stoppedGeneration
        TalkAudioSessionDiagnostics.recordStopRequested(
            origin: origin,
            generation: self.activeTTSGeneration,
            activeGeneration: self.activeTTSGeneration,
            ownerGeneration: self.audioSessionOwnerGeneration,
            currentPortTypes: self.currentAudioPortTypes)
        let hasIncremental = self.incrementalSpeechActive ||
            self.incrementalSpeechTask != nil ||
            !self.incrementalSpeechQueue.isEmpty
        if self.isSpeaking {
            let interruptedAt: Double?
            if self.currentPlaybackProvider == .elevenLabs {
                interruptedAt = self.lastPlaybackWasPCM
                    ? self.pcmPlayer.stop()
                    : self.mp3Player.stop()
                _ = self.lastPlaybackWasPCM
                    ? self.mp3Player.stop()
                    : self.pcmPlayer.stop()
            } else {
                interruptedAt = nil
                _ = self.pcmPlayer.stop()
                _ = self.mp3Player.stop()
            }
            if storeInterruption {
                self.lastInterruptedAtSeconds = interruptedAt
            }
            self.recordSpeechInterruption(generation: self.ttsGeneration)
        } else if !hasIncremental {
            return
        }
        self.cancelTTSGeneration()
        self.systemSpeech.stop()
        self.cancelIncrementalSpeech()
        self.isSpeaking = false
        if let stoppedGeneration, stoppedGenerationOwnedAudioSession {
            self.restoreAudioSessionAfterLocalSpeech(ownerGeneration: stoppedGeneration)
        }
        self.restoreConfiguredVoiceModeDescriptor()
    }

    private func shouldInterrupt(with transcript: String) -> Bool {
        guard self.shouldAllowSpeechInterruptForCurrentRoute() else { return false }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        if let spoken = lastSpokenText?.lowercased(), spoken.contains(trimmed.lowercased()) {
            return false
        }
        return true
    }

    private func shouldAllowSpeechInterruptForCurrentRoute() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        // Built-in speaker/receiver often feeds TTS back into STT, causing false interrupts.
        // Allow barge-in for isolated outputs (headphones/Bluetooth/USB/CarPlay/AirPlay).
        return !route.outputs.contains { output in
            switch output.portType {
            case .builtInSpeaker, .builtInReceiver:
                true
            default:
                false
            }
        }
    }

    private func shouldUseIncrementalTTS() -> Bool {
        true
    }

    private var isSpeechOutputActive: Bool {
        self.isSpeaking ||
            self.incrementalSpeechActive ||
            self.incrementalSpeechTask != nil ||
            !self.incrementalSpeechQueue.isEmpty
    }

    private func applyDirective(_ directive: TalkDirective?) {
        let requestedVoice = directive?.voiceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVoice = resolveVoiceAlias(requestedVoice)
        if requestedVoice?.isEmpty == false, resolvedVoice == nil {
            self.logger.warning("unknown voice alias \(requestedVoice ?? "?", privacy: .public)")
        }
        if let voice = resolvedVoice {
            if directive?.once != true {
                self.currentVoiceId = voice
                self.voiceOverrideActive = true
            }
        }
        if let model = directive?.modelId {
            if directive?.once != true {
                self.currentModelId = model
                self.modelOverrideActive = true
            }
        }
    }

    private func resetIncrementalSpeech() {
        self.incrementalSpeechQueue.removeAll()
        self.incrementalSpeechTaskGeneration &+= 1
        self.incrementalSpeechTask?.cancel()
        self.incrementalSpeechTask = nil
        self.stopIncrementalSpeechPlaybackIfOwned()
        self.cancelIncrementalPrefetch()
        self.incrementalSpeechActive = true
        self.incrementalSpeechUsed = false
        self.incrementalSpeechLanguage = nil
        self.incrementalSpeechBuffer = IncrementalSpeechBuffer()
        self.incrementalSpeechContext = nil
        self.incrementalSpeechDirective = nil
        self.incrementalSpeechPresentationValidator = nil
    }

    private func cancelIncrementalSpeech() {
        self.incrementalSpeechQueue.removeAll()
        self.incrementalSpeechTaskGeneration &+= 1
        self.incrementalSpeechTask?.cancel()
        self.incrementalSpeechTask = nil
        self.stopIncrementalSpeechPlaybackIfOwned()
        self.cancelIncrementalPrefetch()
        self.incrementalSpeechActive = false
        self.incrementalSpeechContext = nil
        self.incrementalSpeechDirective = nil
        self.incrementalSpeechPresentationValidator = nil
    }

    private func enqueueIncrementalSpeech(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.incrementalSpeechQueue.append(trimmed)
        self.incrementalSpeechUsed = true
        if self.incrementalSpeechTask == nil {
            self.startIncrementalSpeechTask()
        }
    }

    private func startIncrementalSpeechTask() {
        if self.interruptOnSpeech {
            do {
                try self.startRecognition()
            } catch {
                self.logger.warning(
                    "startRecognition during incremental speak failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        self.incrementalSpeechTaskGeneration &+= 1
        let taskGeneration = self.incrementalSpeechTaskGeneration
        self.incrementalSpeechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.isCurrentIncrementalSpeechTask(taskGeneration) {
                    self.cancelIncrementalPrefetch()
                    self.isSpeaking = false
                    self.stopRecognition()
                    self.incrementalSpeechTask = nil
                }
            }
            while !Task.isCancelled, self.isCurrentIncrementalSpeechTask(taskGeneration) {
                guard !self.incrementalSpeechQueue.isEmpty else { break }
                guard await self.isIncrementalSpeechPresentationAuthorized() else {
                    self.cancelIncrementalSpeech()
                    return
                }
                let segment = self.incrementalSpeechQueue.removeFirst()
                self.statusText = "Speaking…"
                self.isSpeaking = true
                self.lastSpokenText = segment
                await self.updateIncrementalContextIfNeeded(taskGeneration: taskGeneration)
                guard !Task.isCancelled, self.isCurrentIncrementalSpeechTask(taskGeneration) else { break }
                let context = self.incrementalSpeechContext
                let prefetchedAudio = await self.consumeIncrementalPrefetchedAudioIfAvailable(
                    for: segment,
                    context: context,
                    taskGeneration: taskGeneration)
                guard !Task.isCancelled, self.isCurrentIncrementalSpeechTask(taskGeneration) else { break }
                if let context {
                    self.startIncrementalPrefetchMonitor(context: context, taskGeneration: taskGeneration)
                }
                #if DEBUG
                if let beforeSpeak = self.incrementalSpeechBeforeSpeakOverride {
                    await beforeSpeak(taskGeneration)
                }
                #endif
                guard !Task.isCancelled, self.isCurrentIncrementalSpeechTask(taskGeneration) else { break }
                guard await self.isIncrementalSpeechPresentationAuthorized() else {
                    self.cancelIncrementalSpeech()
                    return
                }
                await self.speakIncrementalSegment(
                    segment,
                    context: context,
                    prefetchedAudio: prefetchedAudio,
                    taskGeneration: taskGeneration)
                guard !Task.isCancelled, self.isCurrentIncrementalSpeechTask(taskGeneration) else { break }
                self.cancelIncrementalPrefetchMonitor()
            }
        }
    }

    private func isCurrentIncrementalSpeechTask(_ generation: UInt64) -> Bool {
        self.incrementalSpeechTaskGeneration == generation
    }

    private func isSpeechPresentationAuthorized(
        _ presentationValidator: SpeechPresentationValidator) async -> Bool
    {
        guard !Task.isCancelled else { return false }
        let isAuthorized = await presentationValidator()
        return isAuthorized && !Task.isCancelled
    }

    private func isIncrementalSpeechPresentationAuthorized() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let incrementalSpeechPresentationValidator else { return true }
        return await self.isSpeechPresentationAuthorized(incrementalSpeechPresentationValidator)
    }

    private func stopIncrementalSpeechPlaybackIfOwned() {
        guard let playbackGeneration = self.incrementalSpeechPlaybackGeneration else { return }
        self.incrementalSpeechPlaybackGeneration = nil
        guard playbackGeneration == self.ttsGeneration else { return }
        self.recordSpeechInterruption(generation: playbackGeneration)
        self.cancelTTSGeneration()
        _ = self.pcmPlayer.stop()
        _ = self.mp3Player.stop()
        self.systemSpeech.stop()
        self.isSpeaking = false
        self.restoreAudioSessionAfterLocalSpeech(ownerGeneration: playbackGeneration)
        self.restoreConfiguredVoiceModeDescriptor()
    }

    private func recordSpeechInterruption(generation: UInt64) {
        self.updateTTSDiagnostics(TalkTTSProgress(
            state: .failed,
            providerAttemptOutcome: self.currentPlaybackProvider == .elevenLabs ? .interrupted : nil,
            finalProvider: self.currentPlaybackProvider,
            finalOutcome: .interrupted,
            userMessage: "Speech interrupted — text reply preserved."), generation: generation)
    }

    private func cancelIncrementalPrefetch() {
        self.cancelIncrementalPrefetchMonitor()
        self.incrementalSpeechPrefetch?.task.cancel()
        self.incrementalSpeechPrefetch = nil
    }

    private func cancelIncrementalPrefetchMonitor() {
        self.incrementalSpeechPrefetchMonitorTask?.cancel()
        self.incrementalSpeechPrefetchMonitorTask = nil
    }

    private func startIncrementalPrefetchMonitor(
        context: IncrementalSpeechContext,
        taskGeneration: UInt64)
    {
        self.cancelIncrementalPrefetchMonitor()
        self.incrementalSpeechPrefetchMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isCurrentIncrementalSpeechTask(taskGeneration) {
                if self.ensureIncrementalPrefetchForUpcomingSegment(context: context) {
                    return
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    private func ensureIncrementalPrefetchForUpcomingSegment(context: IncrementalSpeechContext) -> Bool {
        guard context.canUseElevenLabs else {
            self.cancelIncrementalPrefetch()
            return false
        }
        guard let nextSegment = incrementalSpeechQueue.first else { return false }
        if let existing = incrementalSpeechPrefetch {
            if existing.segment == nextSegment, existing.context == context {
                return true
            }
            existing.task.cancel()
            self.incrementalSpeechPrefetch = nil
        }
        self.startIncrementalPrefetch(segment: nextSegment, context: context)
        return self.incrementalSpeechPrefetch != nil
    }

    private func startIncrementalPrefetch(segment: String, context: IncrementalSpeechContext) {
        guard context.canUseElevenLabs, let apiKey = context.apiKey, let voiceId = context.voiceId else { return }
        let prefetchOutputFormat = self.resolveIncrementalPrefetchOutputFormat(context: context)
        let request = self.makeIncrementalTTSRequest(
            text: segment,
            context: context,
            outputFormat: prefetchOutputFormat)
        let id = UUID()
        let responseEvidence = ElevenLabsTTSResponseEvidence()
        let task = Task { [weak self] in
            let stream = ElevenLabsTTSClient(apiKey: apiKey).streamSynthesize(
                voiceId: voiceId,
                request: request,
                responseEvidence: responseEvidence)
            var chunks: [Data] = []
            do {
                for try await chunk in stream {
                    try Task.checkCancellation()
                    chunks.append(chunk)
                }
                self?.completeIncrementalPrefetch(id: id, chunks: chunks)
            } catch is CancellationError {
                self?.clearIncrementalPrefetch(id: id)
            } catch {
                self?.failIncrementalPrefetch(id: id, error: error)
            }
        }
        self.incrementalSpeechPrefetch = IncrementalSpeechPrefetchState(
            id: id,
            segment: segment,
            context: context,
            outputFormat: prefetchOutputFormat,
            responseEvidence: responseEvidence,
            chunks: nil,
            task: task)
    }

    private func completeIncrementalPrefetch(id: UUID, chunks: [Data]) {
        guard var prefetch = incrementalSpeechPrefetch, prefetch.id == id else { return }
        prefetch.chunks = chunks
        self.incrementalSpeechPrefetch = prefetch
    }

    private func clearIncrementalPrefetch(id: UUID) {
        guard let prefetch = incrementalSpeechPrefetch, prefetch.id == id else { return }
        prefetch.task.cancel()
        self.incrementalSpeechPrefetch = nil
    }

    private func failIncrementalPrefetch(id: UUID, error: any Error) {
        guard let prefetch = incrementalSpeechPrefetch, prefetch.id == id else { return }
        self.logger.debug("incremental prefetch failed: \(error.localizedDescription, privacy: .public)")
        prefetch.task.cancel()
        self.incrementalSpeechPrefetch = nil
    }

    private func consumeIncrementalPrefetchedAudioIfAvailable(
        for segment: String,
        context: IncrementalSpeechContext?,
        taskGeneration: UInt64) async -> IncrementalPrefetchedAudio?
    {
        guard self.isCurrentIncrementalSpeechTask(taskGeneration), !Task.isCancelled else { return nil }
        guard let context else {
            self.cancelIncrementalPrefetch()
            return nil
        }
        guard let prefetch = incrementalSpeechPrefetch else {
            return nil
        }
        guard prefetch.context == context else {
            prefetch.task.cancel()
            self.incrementalSpeechPrefetch = nil
            return nil
        }
        guard prefetch.segment == segment else {
            return nil
        }
        if let chunks = prefetch.chunks, !chunks.isEmpty {
            let prefetched = IncrementalPrefetchedAudio(
                chunks: chunks,
                outputFormat: prefetch.outputFormat,
                responseEvidence: prefetch.responseEvidence)
            self.incrementalSpeechPrefetch = nil
            return prefetched
        }
        await prefetch.task.value
        guard self.isCurrentIncrementalSpeechTask(taskGeneration), !Task.isCancelled else { return nil }
        guard let completed = incrementalSpeechPrefetch else { return nil }
        guard completed.context == context, completed.segment == segment else { return nil }
        guard let chunks = completed.chunks, !chunks.isEmpty else { return nil }
        let prefetched = IncrementalPrefetchedAudio(
            chunks: chunks,
            outputFormat: completed.outputFormat,
            responseEvidence: completed.responseEvidence)
        self.incrementalSpeechPrefetch = nil
        return prefetched
    }

    private func resolveIncrementalPrefetchOutputFormat(context: IncrementalSpeechContext) -> String? {
        if TalkTTSValidation.pcmSampleRate(from: context.outputFormat) != nil {
            return ElevenLabsTTSClient.validatedOutputFormat("mp3_44100_128")
        }
        return context.outputFormat
    }

    private func finishIncrementalSpeech() async {
        guard self.incrementalSpeechActive else { return }
        let leftover = self.incrementalSpeechBuffer.flush()
        if let leftover {
            self.enqueueIncrementalSpeech(leftover)
        }
        if let task = incrementalSpeechTask {
            _ = await task.result
        }
        self.incrementalSpeechActive = false
    }

    private func handleIncrementalAssistantFinal(
        text: String,
        presentationValidator: @escaping SpeechPresentationValidator,
        durableResponseGeneration: UInt64) async
    {
        guard await self.isSpeechPresentationAuthorized(presentationValidator) else {
            self.cancelIncrementalSpeech()
            return
        }
        let parsed = TalkDirectiveParser.parse(text)
        if let lang = parsed.directive?.language {
            self.incrementalSpeechLanguage = ElevenLabsTTSClient.validatedLanguage(lang)
        }
        await self.updateIncrementalContextIfNeeded()
        #if DEBUG
        await self.durablePresentationBeforePlaybackOverride?()
        #endif
        guard await self.isSpeechPresentationAuthorized(presentationValidator) else {
            self.cancelIncrementalSpeech()
            return
        }
        self.applyDirective(parsed.directive)
        let segments = self.incrementalSpeechBuffer.ingest(text: text, isFinal: true)
        for segment in segments {
            self.enqueueIncrementalSpeech(segment)
        }
        await self.finishIncrementalSpeech()
        guard await self.isSpeechPresentationAuthorized(presentationValidator) else {
            self.cancelIncrementalSpeech()
            return
        }
        if !self.incrementalSpeechUsed {
            await self.playAssistant(
                text: text,
                presentationValidator: presentationValidator,
                durableResponseGeneration: durableResponseGeneration)
        }
    }

    private func streamAssistant(
        runId: String,
        stream: AsyncStream<EventFrame>,
        presentationValidator: @escaping SpeechPresentationValidator) async
    {
        #if DEBUG
        let durableEventObserved = self.durableEventObservedOverride
        #endif
        for await evt in stream {
            if Task.isCancelled { return }
            guard evt.event == "agent", let payload = evt.payload else { continue }
            guard let agentEvent = try? GatewayPayloadDecoding.decode(
                payload,
                as: OpenClawAgentEventPayload.self)
            else {
                continue
            }
            #if DEBUG
            durableEventObserved?(agentEvent.runId, agentEvent.runId == runId)
            #endif
            guard agentEvent.runId == runId, agentEvent.stream == "assistant" else { continue }
            guard let text = agentEvent.data["text"]?.value as? String else { continue }
            guard await self.isSpeechPresentationAuthorized(presentationValidator) else {
                self.cancelIncrementalSpeech()
                return
            }
            let segments = self.incrementalSpeechBuffer.ingest(text: text, isFinal: false)
            if let lang = incrementalSpeechBuffer.directive?.language {
                self.incrementalSpeechLanguage = ElevenLabsTTSClient.validatedLanguage(lang)
            }
            await self.updateIncrementalContextIfNeeded()
            guard await self.isSpeechPresentationAuthorized(presentationValidator) else {
                self.cancelIncrementalSpeech()
                return
            }
            for segment in segments {
                self.enqueueIncrementalSpeech(segment)
            }
        }
    }

    private func updateIncrementalContextIfNeeded(taskGeneration: UInt64? = nil) async {
        guard !Task.isCancelled else { return }
        if let taskGeneration, !self.isCurrentIncrementalSpeechTask(taskGeneration) { return }
        let directive = self.incrementalSpeechBuffer.directive
        if let existing = incrementalSpeechContext, directive == incrementalSpeechDirective {
            if let taskGeneration, !self.isCurrentIncrementalSpeechTask(taskGeneration) { return }
            if existing.language != self.incrementalSpeechLanguage {
                self.incrementalSpeechContext = IncrementalSpeechContext(
                    apiKey: existing.apiKey,
                    voiceId: existing.voiceId,
                    modelId: existing.modelId,
                    outputFormat: existing.outputFormat,
                    language: self.incrementalSpeechLanguage,
                    directive: existing.directive,
                    canUseElevenLabs: existing.canUseElevenLabs)
            }
            return
        }
        let context = await buildIncrementalSpeechContext(directive: directive)
        guard !Task.isCancelled else { return }
        if let taskGeneration, !self.isCurrentIncrementalSpeechTask(taskGeneration) { return }
        self.incrementalSpeechContext = context
        self.incrementalSpeechDirective = directive
    }

    private func buildIncrementalSpeechContext(directive: TalkDirective?) async -> IncrementalSpeechContext {
        let requestedVoice = directive?.voiceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVoice = resolveVoiceAlias(requestedVoice)
        if requestedVoice?.isEmpty == false, resolvedVoice == nil {
            self.logger.warning("unknown voice alias \(requestedVoice ?? "?", privacy: .public)")
        }
        let preferredVoice = resolvedVoice ?? self.currentVoiceId ?? self.defaultVoiceId
        let modelId = directive?.modelId ?? self.currentModelId ?? self.defaultModelId
        let desiredOutputFormat = (directive?.outputFormat ?? self.defaultOutputFormat)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedOutputFormat = (desiredOutputFormat?.isEmpty == false) ? desiredOutputFormat : nil
        let outputFormat = ElevenLabsTTSClient.validatedOutputFormat(
            requestedOutputFormat ?? self.effectiveDefaultOutputFormat)
        if outputFormat == nil, let requestedOutputFormat {
            self.logger.warning(
                "talk output_format unsupported for local playback: \(requestedOutputFormat, privacy: .public)")
        }

        let configuredKey = self.apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false ? self.apiKey : nil
        #if DEBUG
        let resolvedKey = configuredKey ?? ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
        #else
        let resolvedKey = configuredKey
        #endif
        let apiKey = resolvedKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceId: String? = if let apiKey, !apiKey.isEmpty {
            await resolveVoiceId(preferred: preferredVoice, apiKey: apiKey)
        } else {
            nil
        }
        let canUseElevenLabs = (voiceId?.isEmpty == false) && (apiKey?.isEmpty == false)
        return IncrementalSpeechContext(
            apiKey: apiKey,
            voiceId: voiceId,
            modelId: modelId,
            outputFormat: outputFormat,
            language: self.incrementalSpeechLanguage,
            directive: directive,
            canUseElevenLabs: canUseElevenLabs)
    }

    private func makeIncrementalTTSRequest(
        text: String,
        context: IncrementalSpeechContext,
        outputFormat: String?) -> ElevenLabsTTSRequest
    {
        ElevenLabsTTSRequest(
            text: text,
            modelId: context.modelId,
            outputFormat: outputFormat,
            speed: TalkTTSValidation.resolveSpeed(
                speed: context.directive?.speed,
                rateWPM: context.directive?.rateWPM),
            stability: TalkTTSValidation.validatedStability(
                context.directive?.stability,
                modelId: context.modelId),
            similarity: TalkTTSValidation.validatedUnit(context.directive?.similarity),
            style: TalkTTSValidation.validatedUnit(context.directive?.style),
            speakerBoost: context.directive?.speakerBoost,
            seed: TalkTTSValidation.validatedSeed(context.directive?.seed),
            normalize: ElevenLabsTTSClient.validatedNormalize(context.directive?.normalize),
            language: context.language,
            latencyTier: TalkTTSValidation.validatedLatencyTier(context.directive?.latencyTier))
    }

    /// Returns `mp3_44100_128` when the API has already rejected PCM, otherwise `pcm_44100`.
    private var effectiveDefaultOutputFormat: String {
        self.pcmFormatUnavailable ? "mp3_44100_128" : "pcm_44100"
    }

    private static func makeBufferedAudioStream(chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    private func speakIncrementalSegment(
        _ text: String,
        context preferredContext: IncrementalSpeechContext? = nil,
        prefetchedAudio: IncrementalPrefetchedAudio? = nil,
        taskGeneration: UInt64) async
    {
        guard self.isCurrentIncrementalSpeechTask(taskGeneration), !Task.isCancelled else { return }
        let context: IncrementalSpeechContext?
        if let preferredContext {
            context = preferredContext
        } else {
            await self.updateIncrementalContextIfNeeded(taskGeneration: taskGeneration)
            guard self.isCurrentIncrementalSpeechTask(taskGeneration), !Task.isCancelled else { return }
            context = self.incrementalSpeechContext
        }

        var initialAttempt: TalkTTSProviderAttempt?
        var mp3Attempt: TalkTTSProviderAttempt?
        if let context,
           context.canUseElevenLabs,
           let apiKey = context.apiKey,
           let voiceID = context.voiceId
        {
            let client = ElevenLabsTTSClient(apiKey: apiKey)
            let playbackFormat = prefetchedAudio?.outputFormat ?? context.outputFormat
            let initialRequest = self.makeIncrementalTTSRequest(
                text: text,
                context: context,
                outputFormat: playbackFormat)
            let initialResponseEvidence = prefetchedAudio?.responseEvidence
                ?? ElevenLabsTTSResponseEvidence()
            initialAttempt = TalkTTSProviderAttempt(
                outputFormat: playbackFormat,
                responseEvidence: initialResponseEvidence) {
                if let prefetchedAudio, !prefetchedAudio.chunks.isEmpty {
                    return Self.makeBufferedAudioStream(chunks: prefetchedAudio.chunks)
                }
                return client.streamSynthesize(
                    voiceId: voiceID,
                    request: initialRequest,
                    responseEvidence: initialResponseEvidence)
            }
            if TalkTTSValidation.pcmSampleRate(from: playbackFormat) != nil {
                let mp3Format = ElevenLabsTTSClient.validatedOutputFormat("mp3_44100_128")
                let mp3Request = self.makeIncrementalTTSRequest(
                    text: text,
                    context: context,
                    outputFormat: mp3Format)
                let mp3ResponseEvidence = ElevenLabsTTSResponseEvidence()
                mp3Attempt = TalkTTSProviderAttempt(
                    outputFormat: mp3Format,
                    responseEvidence: mp3ResponseEvidence) {
                    client.streamSynthesize(
                        voiceId: voiceID,
                        request: mp3Request,
                        responseEvidence: mp3ResponseEvidence)
                }
            }
        }

        guard self.isCurrentIncrementalSpeechTask(taskGeneration), !Task.isCancelled else { return }
        let generation = self.beginTTSGeneration()
        self.currentPlaybackProvider = initialAttempt == nil ? .system : .elevenLabs
        self.incrementalSpeechPlaybackGeneration = generation
        self.lastPlaybackWasPCM = initialAttempt.flatMap {
            TalkTTSValidation.pcmSampleRate(from: $0.outputFormat)
        } != nil
        let result = await self.makeTTSPlaybackPipeline(generation: generation).speak(
            text: text,
            language: self.incrementalSpeechLanguage,
            providerAttempt: initialAttempt,
            mp3Retry: mp3Attempt)
        if self.incrementalSpeechPlaybackGeneration == generation {
            self.incrementalSpeechPlaybackGeneration = nil
        }
        let failureStatus = !result.succeeded && result.outcome != .interrupted
            ? "Speech failed — text reply preserved"
            : nil
        self.finalizeTTSGeneration(
            generation,
            statusText: failureStatus,
            keepSpeaking: true)
    }
}

private struct IncrementalSpeechBuffer {
    private static let softBoundaryMinChars = 72

    private(set) var latestText: String = ""
    private(set) var directive: TalkDirective?
    private var spokenOffset: Int = 0
    private var inCodeBlock = false
    private var directiveParsed = false

    mutating func ingest(text: String, isFinal: Bool) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let usable = stripDirectiveIfReady(from: normalized) else { return [] }
        self.updateText(usable)
        return self.extractSegments(isFinal: isFinal)
    }

    mutating func flush() -> String? {
        guard !self.latestText.isEmpty else { return nil }
        let segments = self.extractSegments(isFinal: true)
        return segments.first
    }

    private mutating func stripDirectiveIfReady(from text: String) -> String? {
        guard !self.directiveParsed else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") {
            guard let newlineRange = text.range(of: "\n") else { return nil }
            let firstLine = text[..<newlineRange.lowerBound]
            let head = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.hasSuffix("}") else { return nil }
            let parsed = TalkDirectiveParser.parse(text)
            if let directive = parsed.directive {
                self.directive = directive
            }
            self.directiveParsed = true
            return parsed.stripped
        }
        self.directiveParsed = true
        return text
    }

    private mutating func updateText(_ newText: String) {
        if newText.hasPrefix(self.latestText) {
            self.latestText = newText
        } else if self.latestText.hasPrefix(newText) {
            // Stream reset or correction; prefer the newer prefix.
            self.latestText = newText
            self.spokenOffset = min(self.spokenOffset, newText.count)
        } else {
            // Diverged text means chunks arrived out of order or stream restarted.
            let commonPrefix = Self.commonPrefixCount(self.latestText, newText)
            self.latestText = newText
            if self.spokenOffset > commonPrefix {
                self.spokenOffset = commonPrefix
            }
        }
        if self.spokenOffset > self.latestText.count {
            self.spokenOffset = self.latestText.count
        }
    }

    private static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        let limit = min(left.count, right.count)
        var idx = 0
        while idx < limit, left[idx] == right[idx] {
            idx += 1
        }
        return idx
    }

    private mutating func extractSegments(isFinal: Bool) -> [String] {
        let chars = Array(latestText)
        guard self.spokenOffset < chars.count else { return [] }
        var idx = self.spokenOffset
        var lastBoundary: Int?
        var inCodeBlock = self.inCodeBlock
        var buffer = ""
        var bufferAtBoundary = ""
        var inCodeBlockAtBoundary = inCodeBlock

        while idx < chars.count {
            if idx + 2 < chars.count,
               chars[idx] == "`",
               chars[idx + 1] == "`",
               chars[idx + 2] == "`"
            {
                inCodeBlock.toggle()
                idx += 3
                continue
            }

            if !inCodeBlock {
                let currentChar = chars[idx]
                buffer.append(currentChar)
                if Self.isBoundary(currentChar) || Self.isSoftBoundary(currentChar, bufferedChars: buffer.count) {
                    lastBoundary = idx + 1
                    bufferAtBoundary = buffer
                    inCodeBlockAtBoundary = inCodeBlock
                }
            }

            idx += 1
        }

        if let boundary = lastBoundary {
            self.spokenOffset = boundary
            self.inCodeBlock = inCodeBlockAtBoundary
            let trimmed = bufferAtBoundary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        guard isFinal else { return [] }
        self.spokenOffset = chars.count
        self.inCodeBlock = inCodeBlock
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    private static func isBoundary(_ ch: Character) -> Bool {
        ch == "." || ch == "!" || ch == "?" || ch == "\n"
    }

    private static func isSoftBoundary(_ ch: Character, bufferedChars: Int) -> Bool {
        bufferedChars >= self.softBoundaryMinChars && ch.isWhitespace
    }
}

extension TalkModeManager {
    func resolveVoiceAlias(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        if let mapped = voiceAliases[normalized] { return mapped }
        if self.voiceAliases.values.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return trimmed
        }
        return Self.isLikelyVoiceId(trimmed) ? trimmed : nil
    }

    func resolveVoiceId(preferred: String?, apiKey: String) async -> String? {
        let trimmed = preferred?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            // Config / directives can provide a raw ElevenLabs voiceId (not an alias).
            // Accept it directly to avoid unnecessary listVoices calls (and accidental fallback selection).
            if Self.isLikelyVoiceId(trimmed) {
                return trimmed
            }
            if let resolved = resolveVoiceAlias(trimmed) { return resolved }
            self.logger.warning("unknown voice alias \(trimmed, privacy: .public)")
        }
        if let fallbackVoiceId { return fallbackVoiceId }

        do {
            let voices = try await ElevenLabsTTSClient(apiKey: apiKey).listVoices()
            guard !Task.isCancelled else { return nil }
            guard let first = voices.first else {
                self.logger.warning("elevenlabs voices list empty")
                return nil
            }
            fallbackVoiceId = first.voiceId
            if self.defaultVoiceId == nil {
                self.defaultVoiceId = first.voiceId
            }
            if !self.voiceOverrideActive {
                self.currentVoiceId = first.voiceId
            }
            let name = first.name ?? "unknown"
            self.logger
                .info("default voice selected \(name, privacy: .public) (\(first.voiceId, privacy: .public))")
            return first.voiceId
        } catch {
            self.logger.error("elevenlabs list voices failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func isLikelyVoiceId(_ value: String) -> Bool {
        guard value.count >= 10 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func normalizedTalkApiKey(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != Self.redactedConfigSentinel else { return nil }
        // Config values may be env placeholders (for example `${ELEVENLABS_API_KEY}`).
        if trimmed.hasPrefix("${"), trimmed.hasSuffix("}") { return nil }
        return trimmed
    }

    private static func displayName(forProvider provider: String) -> String {
        switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "elevenlabs":
            "ElevenLabs"
        case "openai":
            "OpenAI"
        case "google":
            "Google"
        case "system":
            "iOS System Voice"
        case "realtime":
            "Realtime Voice"
        case let provider where !provider.isEmpty:
            provider
        default:
            "Gateway Default"
        }
    }

    private func applyVoiceModeDescriptor(_ descriptor: TalkVoiceModeDescriptor, persistAsConfigured: Bool = false) {
        if persistAsConfigured {
            self.configuredVoiceModeDescriptor = descriptor
        }
        self.gatewayTalkVoiceModeTitle = descriptor.title
        self.gatewayTalkVoiceModeSubtitle = descriptor.subtitle
        self.gatewayTalkVoiceModeAccessibilityValue = descriptor.accessibilityValue
    }

    private func restoreConfiguredVoiceModeDescriptor() {
        self.applyVoiceModeDescriptor(self.configuredVoiceModeDescriptor)
    }

    private func buildConfiguredVoiceModeDescriptor(
        provider: String,
        providerLabel: String,
        modelId: String?,
        voiceId: String?,
        transport: String,
        isRealtime: Bool) -> TalkVoiceModeDescriptor
    {
        TalkVoiceModeDescriptorBuilder.build(
            providerId: provider,
            providerLabel: providerLabel,
            modelId: modelId,
            voiceId: voiceId,
            transport: transport,
            isRealtime: isRealtime)
    }

    private func ensureTalkConfigLoadedForStart() async {
        if self.gatewayTalkConfigLoaded || self.gatewayTalkPermissionState.isApprovalRequestInProgress {
            GatewayDiagnostics.log(
                "talk.timeline config cached permission=\(self.gatewayTalkPermissionState.statusLabel) "
                    + "loadedAt=\(self.talkConfigLoadedAt?.timeIntervalSince1970 ?? 0)")
            return
        }

        let configStartedAt = Self.nowSeconds()
        await self.reloadConfig()
        GatewayDiagnostics.log(
            "talk.timeline config reload elapsedMs=\(Self.elapsedMs(since: configStartedAt)) "
                + "permission=\(self.gatewayTalkPermissionState.statusLabel)")
    }

    func reloadConfig(
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute? = nil,
        shouldApply: @MainActor @Sendable () -> Bool = { true }) async
    {
        guard let gateway else { return }
        guard shouldApply() else { return }
        if let expectedRoute {
            guard await gateway.isCurrentRoute(expectedRoute), shouldApply() else { return }
        }
        self.gatewayTalkConfigAvailabilityState = .loading
        self.updateTTSDiagnostics(TalkTTSProgress(
            state: .configLoading,
            userMessage: "Loading Talk voice configuration…"))
        self.pcmFormatUnavailable = false
        self.prefetchedRealtimeSession = nil
        do {
            let loaded = try await self.loadTalkConfig(
                from: gateway,
                ifCurrentRoute: expectedRoute)
            if let expectedRoute {
                guard await gateway.isCurrentRoute(expectedRoute) else { return }
            }
            guard shouldApply() else { return }
            guard let loaded else {
                self.gatewayTalkConfigLoaded = false
                self.talkConfigLoadedAt = nil
                self.gatewayTalkConfigAvailabilityState = .missingOnServer
                return
            }
            let parsed = TalkModeGatewayConfigParser.parse(
                config: loaded.config,
                defaultProvider: Self.defaultTalkProvider,
                defaultModelIdFallback: Self.defaultModelIdFallback,
                defaultRealtimeModelIdFallback: Self.defaultRealtimeModelIdFallback,
                defaultSilenceTimeoutMs: Self.defaultSilenceTimeoutMs)
            if parsed.missingResolvedPayload {
                GatewayDiagnostics.log(
                    "talk config ignored: normalized payload missing talk.resolved")
            }
            self.applyLoadedTalkConfig(
                parsed,
                redactedFallbackMissingScope: loaded.redactedFallbackMissingScope,
                secretsAccess: loaded.secretsAccess)
            if case .missingScope = self.gatewayTalkPermissionState {
                self.gatewayTalkConfigAvailabilityState = .scopeBlocked
            } else {
                self.gatewayTalkConfigAvailabilityState = .loaded
            }
        } catch {
            if let expectedRoute {
                guard await gateway.isCurrentRoute(expectedRoute) else { return }
            }
            guard shouldApply() else { return }
            self.applyTalkConfigLoadFailure(error)
            self.gatewayTalkConfigAvailabilityState = Self.missingTalkScope(from: error) == nil
                ? .failed
                : .scopeBlocked
        }
    }

    private func loadTalkConfig(
        from gateway: GatewayNodeSession,
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute? = nil) async throws
        -> (config: [String: Any], redactedFallbackMissingScope: String?, secretsAccess: TalkTTSSecretsAccess)?
    {
        func fetchConfig(includeSecrets: Bool) async throws -> [String: Any]? {
            let paramsJSON = includeSecrets ? "{\"includeSecrets\":true}" : "{}"
            let res: Data
            if let expectedRoute {
                res = try await gateway.request(
                    method: "talk.config",
                    paramsJSON: paramsJSON,
                    timeoutSeconds: 8,
                    ifCurrentRoute: expectedRoute)
            } else {
                res = try await gateway.request(
                    method: "talk.config",
                    paramsJSON: paramsJSON,
                    timeoutSeconds: 8)
            }
            guard let json = try JSONSerialization.jsonObject(with: res) as? [String: Any] else {
                return nil
            }
            return json["config"] as? [String: Any]
        }

        do {
            if let config = try await fetchConfig(includeSecrets: true) {
                return (config, nil, .accepted)
            }
            guard let config = try await fetchConfig(includeSecrets: false) else { return nil }
            GatewayDiagnostics.log("talk config secrets unavailable; loaded redacted config")
            return (config, nil, .redacted)
        } catch {
            let missingScope = Self.missingTalkScope(from: error)
            guard let config = try await fetchConfig(includeSecrets: false) else {
                throw error
            }
            GatewayDiagnostics.log("talk config secrets unavailable; loaded redacted config")
            return (config, missingScope, missingScope == nil ? .redacted : .rejected)
        }
    }

    private func applyLoadedTalkConfig(
        _ parsed: TalkModeGatewayConfigState,
        redactedFallbackMissingScope: String?,
        secretsAccess: TalkTTSSecretsAccess)
    {
        let providerSelection = self.talkProviderSelection
        var activeProvider = parsed.activeProvider
        var executionMode = parsed.executionMode
        var realtimeProvider = parsed.realtimeProvider
        var realtimeModelId = parsed.realtimeModelId
        let realtimeVoiceOverride = TalkModeRealtimeVoiceSelection.resolvedOverride(
            UserDefaults.standard.string(forKey: TalkModeRealtimeVoiceSelection.storageKey))
        let realtimeVoiceId = realtimeVoiceOverride ?? parsed.realtimeVoiceId
        switch providerSelection {
        case .gatewayDefault:
            break
        case .nativeElevenLabs:
            activeProvider = Self.defaultTalkProvider
            executionMode = .native
        case .openAIRealtime:
            activeProvider = "openai"
            executionMode = .realtimeRelay
            realtimeProvider = realtimeProvider ?? "openai"
            realtimeModelId = realtimeModelId ?? Self.defaultRealtimeModelIdFallback
        }
        if activeProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "openai" {
            executionMode = .realtimeRelay
            realtimeProvider = realtimeProvider ?? "openai"
            realtimeModelId = realtimeModelId ?? Self.defaultRealtimeModelIdFallback
        }

        let usesRealtimeConfig = activeProvider != Self.defaultTalkProvider || executionMode != .native
        self.activeTalkProvider = activeProvider
        self.executionMode = executionMode
        self.realtimeWebRTCEnabled = usesRealtimeConfig
        self.realtimeProvider = realtimeProvider
        self.realtimeModelId = realtimeModelId
        self.realtimeVoiceId = realtimeVoiceId
        self.defaultVoiceId = parsed.defaultVoiceId
        self.voiceAliases = parsed.voiceAliases
        if !self.voiceOverrideActive {
            self.currentVoiceId = self.defaultVoiceId
        }
        self.defaultModelId = parsed.defaultModelId
        if !self.modelOverrideActive {
            self.currentModelId = self.defaultModelId
        }
        self.defaultOutputFormat = parsed.defaultOutputFormat

        let credentialSource = self.applyTalkConfigCredentials(
            parsed: parsed,
            activeProvider: activeProvider,
            usesRealtimeConfig: usesRealtimeConfig,
            realtimeProvider: realtimeProvider)
        let gatewayOwnedVoiceProvider = credentialSource == .gatewayRuntime
        self.applyTalkModeDescriptor(
            activeProvider: activeProvider,
            providerSelection: providerSelection,
            usesRealtimeConfig: usesRealtimeConfig,
            usesRealtimeRelay: executionMode == .realtimeRelay,
            realtimeProvider: realtimeProvider,
            realtimeModelId: realtimeModelId,
            realtimeVoiceId: realtimeVoiceId)
        self.applyTalkPermissionState(
            redactedFallbackMissingScope: redactedFallbackMissingScope,
            gatewayOwnedVoiceProvider: gatewayOwnedVoiceProvider)
        self.applyTTSConfigEvidence(
            parsed: parsed,
            activeProvider: activeProvider,
            credentialSource: credentialSource,
            secretsAccess: secretsAccess,
            missingScope: redactedFallbackMissingScope)

        if let interrupt = parsed.interruptOnSpeech {
            self.interruptOnSpeech = interrupt
        }
        self.gatewaySpeechLocaleID = parsed.speechLocaleID
        self.silenceWindow = TimeInterval(parsed.silenceTimeoutMs) / 1000
        if parsed.normalizedPayload || parsed.defaultVoiceId != nil || parsed.rawConfigApiKey != nil {
            GatewayDiagnostics.log("talk config provider=\(activeProvider) silenceTimeoutMs=\(parsed.silenceTimeoutMs)")
        }
    }

    private func applyTalkConfigCredentials(
        parsed: TalkModeGatewayConfigState,
        activeProvider: String,
        usesRealtimeConfig: Bool,
        realtimeProvider: String?) -> TalkTTSCredentialSource
    {
        let rawConfigApiKey = parsed.rawConfigApiKey
        let configApiKey = Self.normalizedTalkApiKey(rawConfigApiKey)
        let localApiKey = Self.normalizedTalkApiKey(
            GatewaySettingsStore.loadTalkProviderApiKey(provider: activeProvider))
        #if DEBUG
        let debugEnvironmentKeyPresent = Self.normalizedTalkApiKey(
            ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]) != nil
        #else
        let debugEnvironmentKeyPresent = false
        #endif
        let credentialSource = TalkTTSCredentialSourceResolver.resolve(
            gatewayOwnedProvider: usesRealtimeConfig,
            gatewayConfigKeyPresent: configApiKey != nil,
            localOverrideKeyPresent: localApiKey != nil,
            debugEnvironmentKeyPresent: debugEnvironmentKeyPresent)
        if rawConfigApiKey == Self.redactedConfigSentinel {
            self.apiKey = (localApiKey?.isEmpty == false) ? localApiKey : nil
            GatewayDiagnostics.log("talk config apiKey redacted; using local override if present")
        } else {
            self.apiKey = (localApiKey?.isEmpty == false) ? localApiKey : configApiKey
        }
        if usesRealtimeConfig {
            self.apiKey = nil
            let credentialProvider = realtimeProvider ?? activeProvider
            GatewayDiagnostics.log("talk realtime provider '\(credentialProvider)' uses gateway-owned credentials")
        }
        return credentialSource
    }

    private func applyTalkModeDescriptor(
        activeProvider: String,
        providerSelection: TalkModeProviderSelection,
        usesRealtimeConfig: Bool,
        usesRealtimeRelay: Bool,
        realtimeProvider: String?,
        realtimeModelId: String?,
        realtimeVoiceId: String?)
    {
        self.gatewayTalkDefaultVoiceId = usesRealtimeConfig ? realtimeVoiceId : self.defaultVoiceId
        self.gatewayTalkDefaultModelId = usesRealtimeConfig ? realtimeModelId : self.defaultModelId
        let providerLabel = providerSelection == .gatewayDefault
            ? Self.displayName(forProvider: activeProvider)
            : providerSelection.label
        let transport = usesRealtimeConfig ? (usesRealtimeRelay ? "gateway-relay" : "webrtc") : "native"
        let transportLabel = usesRealtimeRelay ? "Gateway Relay" : (usesRealtimeConfig ? "Native WebRTC" : "Native")
        self.gatewayTalkProviderLabel = providerLabel
        self.gatewayTalkUsesRealtime = usesRealtimeConfig
        self.gatewayTalkUsesRealtimeRelay = usesRealtimeRelay
        self.gatewayTalkTransportLabel = transportLabel
        self.gatewayTalkRealtimeProviderLabel = realtimeProvider.map { Self.displayName(forProvider: $0) }
        self.gatewayTalkRealtimeModelId = realtimeModelId
        self.gatewayTalkRealtimeVoiceId = realtimeVoiceId
        let voiceModeProvider = usesRealtimeConfig ? (realtimeProvider ?? "realtime") : activeProvider
        let voiceModeLabel = usesRealtimeConfig
            ? Self.displayName(forProvider: voiceModeProvider)
            : Self.displayName(forProvider: activeProvider)
        let voiceModeDescriptor = self.buildConfiguredVoiceModeDescriptor(
            provider: voiceModeProvider,
            providerLabel: voiceModeLabel,
            modelId: usesRealtimeConfig ? realtimeModelId : self.defaultModelId,
            voiceId: usesRealtimeConfig ? realtimeVoiceId : self.defaultVoiceId,
            transport: transport,
            isRealtime: usesRealtimeConfig)
        self.applyVoiceModeDescriptor(voiceModeDescriptor, persistAsConfigured: true)
    }

    private func applyTalkPermissionState(
        redactedFallbackMissingScope: String?,
        gatewayOwnedVoiceProvider: Bool)
    {
        self.gatewayTalkApiKeyConfigured = gatewayOwnedVoiceProvider || (self.apiKey?.isEmpty == false)
        self.gatewayTalkConfigLoaded = true
        self.talkConfigLoadedAt = Date()
        if let missingScope = redactedFallbackMissingScope,
           gatewayOwnedVoiceProvider || self.apiKey == nil
        {
            self.gatewayTalkPermissionState = .missingScope(missingScope)
            GatewayDiagnostics.log("talk config missing gateway scope=\(missingScope)")
        } else {
            self.gatewayTalkPermissionState = (self.gatewayTalkApiKeyConfigured || gatewayOwnedVoiceProvider)
                ? .ready
                : .apiKeyMissing
        }
    }

    private func applyTTSConfigEvidence(
        parsed: TalkModeGatewayConfigState,
        activeProvider: String,
        credentialSource: TalkTTSCredentialSource,
        secretsAccess: TalkTTSSecretsAccess,
        missingScope: String?)
    {
        self.ttsDiagnostics.config = TalkTTSConfigEvidenceBuilder.build(
            loaded: true,
            secretsAccess: secretsAccess,
            provider: Self.sanitizedDiagnosticToken(activeProvider, fallback: "unknown"),
            modelPresent: !parsed.defaultModelId.isEmpty,
            voiceIDPresent: parsed.defaultVoiceId?.isEmpty == false,
            apiKeyPresent: credentialSource.clientAPIKeyPresent,
            credentialSource: credentialSource)
        if missingScope != nil {
            self.updateTTSDiagnostics(TalkTTSProgress(
                state: .permissionRequired,
                userMessage: "Gateway permission required."))
        } else if secretsAccess == .redacted || secretsAccess == .rejected {
            self.updateTTSDiagnostics(TalkTTSProgress(
                state: .configRedacted,
                userMessage: credentialSource.clientAPIKeyPresent
                    ? "Gateway Talk secrets are redacted; a client credential is available."
                    : "ElevenLabs unavailable — using iOS voice."))
        } else {
            self.updateTTSDiagnostics(TalkTTSProgress(
                state: .providerResolved,
                userMessage: "Talk voice provider resolved."))
        }
        self.recordTTSConfigEvidence()
    }

    private func applyTalkConfigLoadFailure(_ error: Error) {
        if self.shouldForceRealtimeRelayFromSelection {
            self.applyOpenAIRealtimeSelectionDefaults()
            GatewayDiagnostics.log("talk config unavailable; keeping openai realtime selection")
        } else {
            self.applyTalkConfigLoadFailureFallback()
        }
        self.defaultModelId = Self.defaultModelIdFallback
        if !self.modelOverrideActive {
            self.currentModelId = self.defaultModelId
        }
        self.gatewayTalkConfigLoaded = false
        self.talkConfigLoadedAt = nil
        self.gatewaySpeechLocaleID = nil
        self.silenceWindow = TimeInterval(Self.defaultSilenceTimeoutMs) / 1000
        if let missingScope = Self.missingTalkScope(from: error) {
            self.gatewayTalkPermissionState = .missingScope(missingScope)
            self.statusText = "Gateway permission required"
            GatewayDiagnostics.log("talk config missing gateway scope=\(missingScope)")
            self.updateTTSDiagnostics(TalkTTSProgress(
                state: .permissionRequired,
                userMessage: "Gateway permission required."))
        } else {
            self.gatewayTalkPermissionState = .loadFailed(error.localizedDescription)
            self.updateTTSDiagnostics(TalkTTSProgress(
                state: .failed,
                userMessage: "Talk configuration unavailable — text remains available."))
        }
        self.ttsDiagnostics.config.loaded = false
        self.ttsDiagnostics.config.secretsAccess = .unknown
        self.recordTTSConfigEvidence()
    }

    private func applyTalkConfigLoadFailureFallback() {
        self.activeTalkProvider = Self.defaultTalkProvider
        self.executionMode = .native
        self.realtimeWebRTCEnabled = false
        self.realtimeProvider = nil
        self.realtimeModelId = nil
        self.realtimeVoiceId = nil
        self.gatewayTalkProviderLabel = "Not loaded"
        self.gatewayTalkTransportLabel = "Not loaded"
        self.gatewayTalkUsesRealtime = false
        self.gatewayTalkUsesRealtimeRelay = false
        self.gatewayTalkRealtimeProviderLabel = nil
        self.gatewayTalkRealtimeModelId = nil
        self.gatewayTalkRealtimeVoiceId = nil
        self.applyVoiceModeDescriptor(TalkVoiceModeDescriptor(
            title: "Not loaded",
            subtitle: nil,
            providerId: nil,
            modelId: nil,
            voiceId: nil,
            transport: nil,
            isRealtime: false), persistAsConfigured: true)
        self.defaultModelId = Self.defaultModelIdFallback
        if !self.modelOverrideActive {
            self.currentModelId = self.defaultModelId
        }
        self.gatewayTalkDefaultVoiceId = nil
        self.gatewayTalkDefaultModelId = nil
        self.gatewayTalkApiKeyConfigured = false
    }

    func markTalkPermissionUpgradeRequested(requestId: String?) {
        self.gatewayTalkPermissionState = .upgradeRequested(requestId: requestId)
        self.statusText = "Approval requested"
    }

    private static func missingTalkScope(from error: Error) -> String? {
        let targetScope = "operator.talk.secrets"
        if let gatewayError = error as? GatewayResponseError {
            if Self.errorTextIndicatesMissingScope(gatewayError.message, scope: targetScope) {
                return targetScope
            }
            if let missingScope = gatewayError.details["missingScope"]?.value as? String,
               missingScope == targetScope
            {
                return targetScope
            }
        }
        if Self.errorTextIndicatesMissingScope(error.localizedDescription, scope: targetScope) {
            return targetScope
        }
        return nil
    }

    private static func errorTextIndicatesMissingScope(_ text: String, scope: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("missing scope") && lower.contains(scope.lowercased())
    }

    static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let forceSpeaker = TalkDefaults.speakerphoneEnabled()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if forceSpeaker {
            options.insert(.defaultToSpeaker)
        }
        // Prefer `.spokenAudio` for STT; it tends to preserve speech energy better than `.voiceChat`.
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: options)
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
        if forceSpeaker, !Self.hasExternalAudioOutput(session.currentRoute) {
            try? session.overrideOutputAudioPort(.speaker)
        } else {
            try? session.overrideOutputAudioPort(.none)
        }
        GatewayDiagnostics.log("talk audio: session speakerphone=\(forceSpeaker) \(Self.describeAudioSession())")
    }

    /// Local TTS permits media-quality external routes while preserving the user's speaker preference.
    /// Unlike capture setup, output-route failure is surfaced so fallback cannot fail silently.
    private static func configureLocalSpeechAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let forceSpeaker = TalkDefaults.speakerphoneEnabled()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
        if forceSpeaker {
            options.insert(.defaultToSpeaker)
        }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: options)
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
        let outputPortTypes = session.currentRoute.outputs.map { $0.portType.rawValue }
        let output = TalkAudioRoutePolicy.shouldOverrideToSpeaker(
            speakerphonePreferred: forceSpeaker,
            outputPortTypes: outputPortTypes)
            ? AVAudioSession.PortOverride.speaker
            : AVAudioSession.PortOverride.none
        try session.overrideOutputAudioPort(output)
    }

    static func configureRealtimeAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let forceSpeaker = TalkDefaults.speakerphoneEnabled()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if forceSpeaker {
            options.insert(.defaultToSpeaker)
        }
        // Realtime Talk is full duplex. `.voiceChat` enables iOS voice processing so speaker
        // output is less likely to be captured as fresh microphone input.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
        if forceSpeaker, !Self.hasExternalAudioOutput(session.currentRoute) {
            try? session.overrideOutputAudioPort(.speaker)
        } else {
            try? session.overrideOutputAudioPort(.none)
        }
        GatewayDiagnostics.log(
            "talk realtime audio: session speakerphone=\(forceSpeaker) \(Self.describeAudioSession())")
    }

    private static func describeAudioSession() -> String {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        let available = session.availableInputs?
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",") ?? ""
        return "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
            + "opts=\(session.categoryOptions.rawValue) inputAvail=\(session.isInputAvailable) "
            + "routeIn=[\(inputs)] routeOut=[\(outputs)] availIn=[\(available)]"
    }

    private static func audioRouteEvidence(
        speakerphonePreferred: Bool,
        activation: TalkAudioRouteEvidence.Activation) -> TalkAudioRouteEvidence
    {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        return TalkAudioRouteEvidence(
            outputPortTypes: outputs.map { $0.portType.rawValue },
            outputNames: outputs.map { Self.sanitizedOutputName($0.portName) },
            speakerphonePreferred: speakerphonePreferred,
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            activation: activation)
    }

    private static func sanitizedOutputName(_ raw: String) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(80))
    }

    private static func hasExternalAudioOutput(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains(where: { output in
            switch output.portType {
            case .airPlay, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio, .headphones, .usbAudio:
                true
            default:
                false
            }
        })
    }

}

private final class AudioTapDiagnostics: @unchecked Sendable {
    private let label: String
    private let onLevel: (@Sendable (Float) -> Void)?
    private let lock = NSLock()
    private var bufferCount: Int = 0
    private var lastLoggedAt = Date.distantPast
    private var lastLevelEmitAt = Date.distantPast
    private var maxRmsWindow: Float = 0
    private var lastRms: Float = 0

    init(label: String, onLevel: (@Sendable (Float) -> Void)? = nil) {
        self.label = label
        self.onLevel = onLevel
    }

    func onBuffer(_ buffer: AVAudioPCMBuffer) {
        var shouldLog = false
        var shouldEmitLevel = false
        var count = 0
        self.lock.lock()
        self.bufferCount += 1
        count = self.bufferCount
        let now = Date()
        if now.timeIntervalSince(self.lastLoggedAt) >= 1.0 {
            self.lastLoggedAt = now
            shouldLog = true
        }
        if now.timeIntervalSince(self.lastLevelEmitAt) >= 0.12 {
            self.lastLevelEmitAt = now
            shouldEmitLevel = true
        }
        self.lock.unlock()

        let rate = buffer.format.sampleRate
        let ch = buffer.format.channelCount
        let frames = buffer.frameLength

        var rms: Float?
        if let data = buffer.floatChannelData?.pointee {
            let n = Int(frames)
            if n > 0 {
                var sum: Float = 0
                for i in 0..<n {
                    let v = data[i]
                    sum += v * v
                }
                rms = sqrt(sum / Float(n))
            }
        }

        let resolvedRms = rms ?? 0
        self.lock.lock()
        self.lastRms = resolvedRms
        if resolvedRms > self.maxRmsWindow { self.maxRmsWindow = resolvedRms }
        let maxRms = self.maxRmsWindow
        if shouldLog { self.maxRmsWindow = 0 }
        self.lock.unlock()

        if shouldEmitLevel, let onLevel {
            onLevel(resolvedRms)
        }

        guard shouldLog else { return }
        GatewayDiagnostics.log(
            "\(self.label) mic: buffers=\(count) frames=\(frames) rate=\(Int(rate))Hz ch=\(ch) "
                + "rms=\(String(format: "%.4f", resolvedRms)) max=\(String(format: "%.4f", maxRms))")
    }
}

extension TalkModeManager: TalkRealtimeWebRTCSessionDelegate {
    func realtimeSession(_ session: TalkRealtimeWebRTCSession, didChangeStatus status: String) {
        guard session === self.realtimeSession else { return }
        GatewayDiagnostics.log("talk.timeline realtime status=\(status)")
        self.statusText = status
        self.isListening = status == "Listening"
        self.isSpeaking = status == "Speaking"
        if status == "Thinking" {
            self.isListening = false
            self.isSpeaking = false
            self.isUserSpeechDetected = false
        }
    }

    func realtimeSession(_ session: TalkRealtimeWebRTCSession, didDetectInputSpeech active: Bool) {
        guard session === self.realtimeSession else { return }
        self.isUserSpeechDetected = active
        if active {
            self.isListening = true
        }
    }

    func realtimeSession(_ session: TalkRealtimeWebRTCSession, didReceiveUserTranscript text: String) {
        guard session === self.realtimeSession else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        GatewayDiagnostics.log("talk.timeline realtime user transcript chars=\(trimmed.count)")
        self.lastTranscript = trimmed
        self.lastHeard = Date()
    }

    func realtimeSession(_ session: TalkRealtimeWebRTCSession, didReceiveAssistantTranscript text: String) {
        guard session === self.realtimeSession else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        GatewayDiagnostics.log("talk.timeline realtime assistant transcript chars=\(trimmed.count)")
        self.lastSpokenText = trimmed
    }

    func realtimeSessionDidFinish(_ session: TalkRealtimeWebRTCSession) {
        guard session === self.realtimeSession else { return }
        self.realtimeSession = nil
        self.isListening = false
        self.isSpeaking = false
        self.isUserSpeechDetected = false
        if self.isEnabled {
            self.statusText = self.gatewayConnected ? "Ready" : "Offline"
        }
    }
}

#if DEBUG
extension TalkModeManager {
    static func _test_isPCMFormatRejectedByAPI(_ error: Error?) -> Bool {
        TalkTTSFailureClassification.isPCMFormatRejected(error)
    }

    func _test_applyOpenAIRealtimeSelectionDefaults() {
        self.applyOpenAIRealtimeSelectionDefaults()
    }

    func _test_executionMode() -> TalkModeExecutionMode {
        self.executionMode
    }

    func _test_realtimeProvider() -> String? {
        self.realtimeProvider
    }

    func _test_realtimeModelId() -> String? {
        self.realtimeModelId
    }

    func _test_gatewayTalkUsesRealtimeRelay() -> Bool {
        self.gatewayTalkUsesRealtimeRelay
    }

    func _test_seedTranscript(_ transcript: String) {
        self.lastTranscript = transcript
        self.lastHeard = Date()
    }

    func _test_prepareActivePTT(transcript: String) async throws -> String {
        self.cancelDurableResponse()
        let context = try await self.makeDurableCaptureContext()
        let captureID = UUID().uuidString
        self.activePTTCaptureId = captureID
        self.beginTranscriptCapture(context: context)
        self.lastTranscript = transcript
        self.lastHeard = Date()
        self.captureMode = .pushToTalk
        self.isListening = true
        self.isPushToTalkActive = true
        return captureID
    }

    func _test_lastTranscript() -> String {
        self.lastTranscript
    }

    func _test_pendingDurableRequest() -> TalkDurableChatRequest? {
        self.pendingDurableChat?.request
    }

    func _test_durableCaptureIdentity() -> (gatewayID: String, sessionKey: String, rawCommandID: String)? {
        guard let durableCaptureContext else { return nil }
        return (
            durableCaptureContext.stableGatewayID,
            durableCaptureContext.sessionKey,
            durableCaptureContext.rawCommandID)
    }

    func _test_activePTTCaptureID() -> String? {
        self.activePTTCaptureId
    }

    func _test_durableCaptureRouteSnapshot() -> OpenClawChatOutboxRouteSnapshot? {
        self.durableCaptureContext?.captureRouteSnapshot
    }

    func _test_hasDurableResponseTask() -> Bool {
        self.durableResponseTask != nil
    }

    func _test_incrementalSpeechState() -> (
        active: Bool,
        queued: Int,
        workerActive: Bool,
        ownsPlayback: Bool)
    {
        (
            active: self.incrementalSpeechActive,
            queued: self.incrementalSpeechQueue.count,
            workerActive: self.incrementalSpeechTask != nil,
            ownsPlayback: self.incrementalSpeechPlaybackGeneration != nil)
    }

    func _test_setPTTPermissionHooks(
        microphone: @escaping () async -> Bool,
        speech: @escaping () async -> Bool)
    {
        self.pttMicrophonePermissionOverride = microphone
        self.pttSpeechPermissionOverride = speech
    }

    func _test_setDurableEventObservedHook(
        _ hook: @escaping @Sendable (_ runID: String?, _ matched: Bool) -> Void)
    {
        self.durableEventObservedOverride = hook
    }

    func _test_setDurableResponseExitedHook(
        _ hook: @escaping @Sendable (_ generation: UInt64) -> Void)
    {
        self.durableResponseExitedOverride = hook
    }

    func _test_setDurablePresentationBeforePlaybackHook(_ hook: @escaping () async -> Void) {
        self.durablePresentationBeforePlaybackOverride = hook
    }

    func _test_seedActiveRealtimeRelayCallbacks() -> UInt64 {
        self.realtimeRelayGeneration &+= 1
        self.activeRealtimeRelayGeneration = self.realtimeRelayGeneration
        self.captureMode = .continuous
        self.isListening = true
        return self.realtimeRelayGeneration
    }

    func _test_applyRealtimeRelayStatus(_ status: String, generation: UInt64) {
        self.handleRealtimeRelayStatus(status, generation: generation)
    }

    func _test_applyRealtimeRelaySpeaking(_ speaking: Bool, generation: UInt64) {
        self.handleRealtimeRelaySpeakingChanged(speaking, generation: generation)
    }

    func _test_hasActiveRealtimeRelayCallbacks() -> Bool {
        self.activeRealtimeRelayGeneration != nil
    }

    func _test_setPTTEndBeforeBodyHook(_ hook: @escaping () async -> Void) {
        self.pttEndBeforeBodyOverride = hook
    }

    func _test_recognitionCallbackGeneration() -> UInt64 {
        self.recognitionCallbackGeneration
    }

    func _test_setPTTAutoStopEnabled(_ enabled: Bool) {
        self.pttAutoStopEnabled = enabled
    }

    func _test_armPTTAutoStopMonitors(timeoutSeconds: TimeInterval = 3600) -> (
        silenceGeneration: UInt64,
        timeoutGeneration: UInt64,
        transcriptGeneration: UInt64,
        captureID: String)?
    {
        guard let captureID = self.activePTTCaptureId else { return nil }
        self.pttAutoStopEnabled = true
        self.startSilenceMonitor()
        self.schedulePTTTimeout(seconds: timeoutSeconds)
        return (
            self.silenceMonitorGeneration,
            self.pttTimeoutGeneration,
            self.transcriptGeneration,
            captureID)
    }

    func _test_deliverSilenceMonitorTick(
        generation: UInt64,
        transcriptGeneration: UInt64,
        captureID: String) async
    {
        guard self.isCurrentSilenceMonitor(
            generation: generation,
            transcriptGeneration: transcriptGeneration,
            captureID: captureID)
        else { return }
        await self.checkSilence()
    }

    func _test_deliverPTTTimeout(generation: UInt64, captureID: String) async {
        await self.handlePTTTimeout(generation: generation, captureID: captureID)
    }

    func _test_deliverRecognitionCallback(
        transcript: String,
        isFinal: Bool,
        generation: UInt64,
        errorMessage: String? = nil) async
    {
        await self.handleRecognitionCallback(
            transcript: transcript,
            isFinal: isFinal,
            errorMessage: errorMessage,
            generation: generation)
    }

    func _test_prepareContinuousRecognition(transcript: String = "") {
        self.captureMode = .continuous
        self.isEnabled = true
        self.gatewayConnected = true
        self.isListening = true
        self.statusText = "Listening"
        self.lastTranscript = transcript
    }

    func _test_handleTranscript(_ transcript: String, isFinal: Bool) async {
        await self.handleTranscript(transcript: transcript, isFinal: isFinal)
    }

    func _test_backdateLastHeard(seconds: TimeInterval) {
        self.lastHeard = Date().addingTimeInterval(-seconds)
    }

    func _test_runSilenceCheck() async {
        await self.checkSilence()
    }

    func _test_incrementalReset() {
        self.incrementalSpeechBuffer = IncrementalSpeechBuffer()
    }

    func _test_incrementalIngest(_ text: String, isFinal: Bool) -> [String] {
        self.incrementalSpeechBuffer.ingest(text: text, isFinal: isFinal)
    }

    func _test_setTTSAudioHooks(
        prepare: @escaping () throws -> TalkAudioRouteEvidence,
        restore: @escaping () -> Void)
    {
        self.ttsPrepareAudioOverride = prepare
        self.ttsRestoreAudioOverride = restore
    }

    func _test_ttsGeneration() -> UInt64 {
        self.ttsGeneration
    }

    func _test_setIncrementalSpeechBeforeSpeakHook(
        _ hook: @escaping (UInt64) async -> Void)
    {
        self.incrementalSpeechBeforeSpeakOverride = hook
    }

    func _test_startIncrementalSpeech(_ text: String) {
        self.interruptOnSpeech = false
        self.resetIncrementalSpeech()
        self.enqueueIncrementalSpeech(text)
    }

    func _test_incrementalSpeechTaskHandle() -> Task<Void, Never>? {
        self.incrementalSpeechTask
    }

    func _test_incrementalSpeechTaskGeneration() -> UInt64 {
        self.incrementalSpeechTaskGeneration
    }

    func _test_hasIncrementalSpeechTask() -> Bool {
        self.incrementalSpeechTask != nil
    }

    func _test_setSpeakingPlaybackFormat(_ outputFormat: String?) {
        self.currentPlaybackProvider = outputFormat == nil ? .system : .elevenLabs
        self.lastPlaybackWasPCM = TalkTTSValidation.pcmSampleRate(from: outputFormat) != nil
        self.isSpeaking = true
    }

    func _test_stopSpeaking() {
        self.stopSpeaking(origin: .unknown)
    }

    func _test_lastInterruptedAtSeconds() -> Double? {
        self.lastInterruptedAtSeconds
    }

    func _test_handleAudioRouteChange(
        reasonValue: UInt,
        previousPortTypes: [String]?,
        callbackGeneration: UInt64?)
    {
        self.handleAudioRouteChange(
            reasonValue: reasonValue,
            previousPortTypes: previousPortTypes,
            callbackGeneration: callbackGeneration)
    }

    func _test_handleAudioSessionInterruption(
        typeValue: UInt,
        reasonValue: UInt?,
        optionValue: UInt,
        callbackGeneration: UInt64?)
    {
        self.handleAudioSessionInterruption(
            typeValue: typeValue,
            reasonValue: reasonValue,
            optionValue: optionValue,
            callbackGeneration: callbackGeneration)
    }
}
#endif

private struct IncrementalSpeechContext: Equatable {
    let apiKey: String?
    let voiceId: String?
    let modelId: String?
    let outputFormat: String?
    let language: String?
    let directive: TalkDirective?
    let canUseElevenLabs: Bool
}

private struct IncrementalSpeechPrefetchState {
    let id: UUID
    let segment: String
    let context: IncrementalSpeechContext
    let outputFormat: String?
    let responseEvidence: ElevenLabsTTSResponseEvidence
    var chunks: [Data]?
    let task: Task<Void, Never>
}

private struct IncrementalPrefetchedAudio {
    let chunks: [Data]
    let outputFormat: String?
    let responseEvidence: ElevenLabsTTSResponseEvidence
}

private struct TTSProviderAttempts {
    let initial: TalkTTSProviderAttempt?
    let mp3: TalkTTSProviderAttempt?
}

// swiftlint:enable type_body_length file_length
