import Foundation
import OpenClawKit

enum TalkAudioSessionDiagnostics {
    struct CallbackContext: Equatable, Sendable {
        let callbackGeneration: UInt64?
        let activeGeneration: UInt64?
        let ownerGeneration: UInt64?

        var resultClass: String {
            guard let callbackGeneration else { return "unattributed_callback" }
            return callbackGeneration == self.activeGeneration ? "current_callback" : "stale_callback"
        }
    }

    enum RestoreResult: Sendable {
        case requested
        case completed
        case failed

        var state: String {
            switch self {
            case .requested: "tts_audio_session_restore_requested"
            case .completed: "tts_audio_session_restore_completed"
            case .failed: "tts_audio_session_restore_failed"
            }
        }

        var resultClass: String {
            switch self {
            case .requested: "requested"
            case .completed: "restored"
            case .failed: "failed"
            }
        }
    }

    static func routeChangeReason(rawValue: UInt) -> OpenClawDiagnosticAudioRouteChangeReason {
        switch rawValue {
        case 1: .newDeviceAvailable
        case 2: .oldDeviceUnavailable
        case 3: .categoryChange
        case 4: .override
        case 6: .wakeFromSleep
        case 7: .noSuitableRoute
        case 8: .routeConfigurationChange
        default: .unknown
        }
    }

    static func interruptionType(rawValue: UInt) -> OpenClawDiagnosticAudioInterruptionType {
        switch rawValue {
        case 0: .ended
        case 1: .began
        default: .unknown
        }
    }

    static func interruptionReason(rawValue: UInt?) -> OpenClawDiagnosticAudioInterruptionReason {
        switch rawValue {
        case 0: .defaultReason
        case 1: .appWasSuspended
        case 2: .builtInMicMuted
        default: .unknown
        }
    }

    static func interruptionOptions(rawValue: UInt) -> [OpenClawDiagnosticAudioInterruptionOption] {
        (rawValue & 1) == 1 ? [.shouldResume] : []
    }

    static func outputRouteClasses(
        rawPortTypes: [String]
    ) -> [OpenClawDiagnosticAudioOutputRouteClass] {
        guard !rawPortTypes.isEmpty else { return [.noOutput] }
        return Array(Set(rawPortTypes.map(Self.outputRouteClass)).sorted {
            $0.rawValue < $1.rawValue
        }.prefix(8))
    }

    static func previousOutputRouteClasses(
        rawPortTypes: [String]?
    ) -> [OpenClawDiagnosticAudioOutputRouteClass] {
        guard let rawPortTypes else { return [.unknown] }
        return self.outputRouteClasses(rawPortTypes: rawPortTypes)
    }

    private static func outputRouteClass(
        rawPortType: String
    ) -> OpenClawDiagnosticAudioOutputRouteClass {
        let normalized = rawPortType.lowercased().filter { $0.isLetter || $0.isNumber }
        if normalized.contains("bluetooth") { return .bluetooth }
        if normalized.contains("airplay") { return .airPlay }
        if normalized.contains("receiver") { return .builtInReceiver }
        if normalized.contains("speaker") { return .builtInSpeaker }
        if normalized.contains("headphone") || normalized.contains("headset") { return .headphones }
        if normalized.contains("caraudio") { return .carAudio }
        if normalized.contains("hdmi") { return .hdmi }
        if normalized.contains("usb") { return .usb }
        if normalized.contains("lineout") { return .lineOut }
        return .other
    }

    nonisolated static func recordRouteChange(
        reasonValue: UInt,
        previousPortTypes: [String]?,
        currentPortTypes: [String],
        context: CallbackContext,
        flush: @Sendable () -> Void = { GatewayDiagnostics.requestFlush() })
    {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .route,
            state: "tts_route_changed",
            connectionRole: .operator,
            playbackGeneration: context.callbackGeneration,
            cancellationGeneration: context.activeGeneration,
            resultClass: context.resultClass,
            callbackPlaybackGeneration: context.callbackGeneration,
            activePlaybackGeneration: context.activeGeneration,
            audioSessionOwnerGeneration: context.ownerGeneration,
            audioRouteChangeReason: Self.routeChangeReason(rawValue: reasonValue),
            previousAudioOutputRouteClasses: Self.previousOutputRouteClasses(
                rawPortTypes: previousPortTypes),
            currentAudioOutputRouteClasses: Self.outputRouteClasses(rawPortTypes: currentPortTypes)))
        flush()
    }

    nonisolated static func recordInterruption(
        typeValue: UInt,
        reasonValue: UInt?,
        optionValue: UInt,
        currentPortTypes: [String],
        context: CallbackContext,
        flush: @Sendable () -> Void = { GatewayDiagnostics.requestFlush() })
    {
        let interruptionType = Self.interruptionType(rawValue: typeValue)
        let state = interruptionType == .ended
            ? "tts_audio_session_interruption_ended"
            : "tts_audio_session_interruption_began"
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: state,
            playbackGeneration: context.callbackGeneration,
            cancellationGeneration: context.activeGeneration,
            resultClass: context.resultClass,
            callbackPlaybackGeneration: context.callbackGeneration,
            activePlaybackGeneration: context.activeGeneration,
            audioSessionOwnerGeneration: context.ownerGeneration,
            currentAudioOutputRouteClasses: Self.outputRouteClasses(rawPortTypes: currentPortTypes),
            audioInterruptionType: interruptionType,
            audioInterruptionReason: Self.interruptionReason(rawValue: reasonValue),
            audioInterruptionOptions: Self.interruptionOptions(rawValue: optionValue)))
        flush()
    }

    nonisolated static func recordMediaServices(
        reset: Bool,
        currentPortTypes: [String],
        context: CallbackContext,
        flush: @Sendable () -> Void = { GatewayDiagnostics.requestFlush() })
    {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: reset ? "tts_media_services_reset" : "tts_media_services_lost",
            playbackGeneration: context.callbackGeneration,
            cancellationGeneration: context.activeGeneration,
            resultClass: context.resultClass,
            callbackPlaybackGeneration: context.callbackGeneration,
            activePlaybackGeneration: context.activeGeneration,
            audioSessionOwnerGeneration: context.ownerGeneration,
            currentAudioOutputRouteClasses: Self.outputRouteClasses(rawPortTypes: currentPortTypes)))
        flush()
    }

    nonisolated static func recordRestore(
        _ result: RestoreResult,
        ownerGeneration: UInt64,
        activeGeneration: UInt64?,
        currentPortTypes: [String],
        flush: @Sendable () -> Void = { GatewayDiagnostics.requestFlush() })
    {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: result.state,
            playbackGeneration: ownerGeneration,
            cancellationGeneration: activeGeneration,
            resultClass: result.resultClass,
            activePlaybackGeneration: activeGeneration,
            audioSessionOwnerGeneration: ownerGeneration,
            currentAudioOutputRouteClasses: Self.outputRouteClasses(rawPortTypes: currentPortTypes)))
        flush()
    }

    nonisolated static func recordStopRequested(
        origin: OpenClawDiagnosticTTSCancellationOrigin,
        generation: UInt64?,
        activeGeneration: UInt64?,
        ownerGeneration: UInt64?,
        currentPortTypes: [String],
        flush: @Sendable () -> Void = { GatewayDiagnostics.requestFlush() })
    {
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .tts,
            state: "tts_stop_requested",
            playbackGeneration: generation,
            cancellationGeneration: activeGeneration,
            resultClass: "requested",
            activePlaybackGeneration: activeGeneration,
            audioSessionOwnerGeneration: ownerGeneration,
            currentAudioOutputRouteClasses: Self.outputRouteClasses(rawPortTypes: currentPortTypes),
            ttsCancellationOrigin: origin))
        flush()
    }
}
