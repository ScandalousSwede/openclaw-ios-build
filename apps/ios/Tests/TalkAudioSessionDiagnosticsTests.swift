import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

private final class AudioSessionDiagnosticLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        self.lock.lock()
        self.storage.append(line)
        self.lock.unlock()
    }

    func events() -> [OpenClawDiagnosticEvent] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage.compactMap(OpenClawDiagnosticRecorder.decodeRecord)
    }
}

@MainActor
extension TalkTTSDiagnosticsTests {
    @Test func routeChangeRecordsBluetoothTransitionAndStaleGeneration() throws {
        let lines = AudioSessionDiagnosticLines()
        OpenClawDiagnosticRecorder.installSink { lines.append($0) }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        TalkAudioSessionDiagnostics.recordRouteChange(
            reasonValue: 3,
            previousPortTypes: ["Speaker"],
            currentPortTypes: ["BluetoothA2DP"],
            context: .init(callbackGeneration: 6, activeGeneration: 7, ownerGeneration: 7),
            flush: {})

        let event = try #require(lines.events().only)
        #expect(event.state == "tts_route_changed")
        #expect(event.callbackPlaybackGeneration == 6)
        #expect(event.activePlaybackGeneration == 7)
        #expect(event.audioSessionOwnerGeneration == 7)
        #expect(event.resultClass == "stale_callback")
        #expect(event.audioRouteChangeReason == .categoryChange)
        #expect(event.previousAudioOutputRouteClasses == [.builtInSpeaker])
        #expect(event.currentAudioOutputRouteClasses == [.bluetooth])
    }

    @Test func interruptionAndMediaServiceNotificationsRetainOnlyAllowlistedCustody() throws {
        let lines = AudioSessionDiagnosticLines()
        OpenClawDiagnosticRecorder.installSink { lines.append($0) }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        let active = TalkAudioSessionDiagnostics.CallbackContext(
            callbackGeneration: 11,
            activeGeneration: 11,
            ownerGeneration: 11)
        TalkAudioSessionDiagnostics.recordInterruption(
            typeValue: 1,
            reasonValue: 1,
            optionValue: 0,
            currentPortTypes: ["BluetoothHFP"],
            context: active,
            flush: {})
        TalkAudioSessionDiagnostics.recordInterruption(
            typeValue: 0,
            reasonValue: 0,
            optionValue: 1,
            currentPortTypes: ["BluetoothHFP"],
            context: active,
            flush: {})
        TalkAudioSessionDiagnostics.recordMediaServices(
            reset: false,
            currentPortTypes: [],
            context: .init(callbackGeneration: nil, activeGeneration: nil, ownerGeneration: nil),
            flush: {})
        TalkAudioSessionDiagnostics.recordMediaServices(
            reset: true,
            currentPortTypes: ["Speaker"],
            context: active,
            flush: {})

        let events = lines.events()
        #expect(events.map(\.state) == [
            "tts_audio_session_interruption_began",
            "tts_audio_session_interruption_ended",
            "tts_media_services_lost",
            "tts_media_services_reset",
        ])
        #expect(events[0].audioInterruptionType == .began)
        #expect(events[0].audioInterruptionReason == .appWasSuspended)
        #expect(events[0].audioInterruptionOptions == [])
        #expect(events[0].currentAudioOutputRouteClasses == [.bluetooth])
        #expect(events[1].audioInterruptionType == .ended)
        #expect(events[1].audioInterruptionReason == .defaultReason)
        #expect(events[1].audioInterruptionOptions == [.shouldResume])
        #expect(events[2].resultClass == "unattributed_callback")
        #expect(events[2].currentAudioOutputRouteClasses == [.noOutput])
        #expect(events[3].resultClass == "current_callback")
        #expect(events[3].currentAudioOutputRouteClasses == [.builtInSpeaker])
    }

    @Test func restoreAndCancellationOriginsAreExplicitAndGenerationBound() throws {
        let lines = AudioSessionDiagnosticLines()
        OpenClawDiagnosticRecorder.installSink { lines.append($0) }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        for result in [
            TalkAudioSessionDiagnostics.RestoreResult.requested,
            .completed,
            .failed,
        ] {
            TalkAudioSessionDiagnostics.recordRestore(
                result,
                ownerGeneration: 17,
                activeGeneration: 18,
                currentPortTypes: ["Headphones"],
                flush: {})
        }
        for origin in [
            OpenClawDiagnosticTTSCancellationOrigin.userOrb,
            .lifecycleOrManagerStop,
            .pttAdmission,
            .speechRecognitionBargeIn,
            .durableResponseOwner,
            .providerReplacement,
            .unknown,
        ] {
            TalkAudioSessionDiagnostics.recordStopRequested(
                origin: origin,
                generation: 17,
                activeGeneration: 18,
                ownerGeneration: 17,
                currentPortTypes: ["Headphones"],
                flush: {})
        }

        let events = lines.events()
        #expect(events.prefix(3).map(\.state) == [
            "tts_audio_session_restore_requested",
            "tts_audio_session_restore_completed",
            "tts_audio_session_restore_failed",
        ])
        #expect(events.prefix(3).allSatisfy { $0.audioSessionOwnerGeneration == 17 })
        #expect(Array(events.dropFirst(3).compactMap(\.ttsCancellationOrigin)) == [
            .userOrb,
            .lifecycleOrManagerStop,
            .pttAdmission,
            .speechRecognitionBargeIn,
            .durableResponseOwner,
            .providerReplacement,
            .unknown,
        ])
    }
}

private extension Array {
    var only: Element? {
        self.count == 1 ? self[0] : nil
    }
}
