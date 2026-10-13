import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import OpenClaw

@MainActor
private final class UnusedPCMStreamingAudioPlayer: PCMStreamingAudioPlaying {
    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult {
        fatalError("Playback is not used by this test")
    }

    func stop() -> Double? {
        nil
    }
}

@MainActor
@Suite struct RealtimeTalkRelaySessionTests {
    @Test func outputPlaybackFinishClearsBargeInStartTime() {
        var speakingStates: [Bool] = []
        let session = RealtimeTalkRelaySession(
            gateway: GatewayNodeSession(),
            options: .init(sessionKey: "main", provider: nil, model: nil, voice: nil),
            pcmPlayer: UnusedPCMStreamingAudioPlayer(),
            onStatus: { _ in },
            onSpeakingChanged: { speakingStates.append($0) })

        session._test_markOutputAudioStarted(nowMs: 100)
        #expect(session._test_isOutputPlaying())
        #expect(session._test_outputStartedAtMs() == 100)

        session._test_markOutputPlaybackFinished()
        #expect(!session._test_isOutputPlaying())
        #expect(session._test_outputStartedAtMs() == nil)
        #expect(speakingStates == [false])

        session._test_markOutputAudioStarted(nowMs: 500)
        #expect(session._test_outputStartedAtMs() == 500)
    }
}

@MainActor
private final class RelayReplayPCMPlayer: PCMStreamingAudioPlaying {
    private(set) var stopCount = 0

    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult {
        // No device audio: replay assertions inspect the native handler's synchronous output state.
        StreamingPlaybackResult(finished: true, interruptedAt: nil)
    }

    func stop() -> Double? {
        self.stopCount += 1
        return nil
    }
}

extension RealtimeTalkRelaySessionTests {
    private static func relayEvent(
        _ type: String,
        id: String = "relay-current",
        fields: [String: AnyCodable] = [:]) -> EventFrame
    {
        var payload = fields
        payload["type"] = AnyCodable(type)
        payload["relaySessionId"] = AnyCodable(id)
        return EventFrame(type: "event", event: "talk.event", payload: AnyCodable(payload), seq: nil, stateversion: nil)
    }

    @Test func retiredRelayEventsCannotReopenStatusOrPlayback() async {
        let player = RelayReplayPCMPlayer()
        var statuses: [String] = []
        var speaking: [Bool] = []
        let session = RealtimeTalkRelaySession(
            gateway: GatewayNodeSession(),
            options: .init(sessionKey: "fixture", provider: nil, model: nil, voice: nil),
            pcmPlayer: player,
            onStatus: { statuses.append($0) },
            onSpeakingChanged: { speaking.append($0) })
        session._test_bindRelaySession("relay-current")
        await session._test_handleGatewayEvent(Self.relayEvent("ready"))
        #expect(statuses == ["Listening (Realtime)"])
        session._test_retireRelaySession()
        let beforeStatuses = statuses
        let beforeSpeaking = speaking
        let beforeStops = player.stopCount

        await session._test_handleGatewayEvent(Self.relayEvent("ready"))
        await session._test_handleGatewayEvent(Self.relayEvent("error", fields: ["message": AnyCodable("late fixture error")]))
        await session._test_handleGatewayEvent(Self.relayEvent("transcript", fields: [
            "role": AnyCodable("user"), "final": AnyCodable(true), "text": AnyCodable("follow up")]))
        await session._test_handleGatewayEvent(Self.relayEvent("audio", fields: [
            "audioBase64": AnyCodable(Data([0, 0, 1, 0]).base64EncodedString())]))
        #expect(!session._test_isOutputPlaying())
        #expect(statuses == beforeStatuses)
        #expect(speaking == beforeSpeaking)
        #expect(player.stopCount == beforeStops)
        // Clean up the intentionally failing baseline's fake output without a live cancel request.
        session.cancelOutput()
    }

    @Test func unboundAndDifferentRelayEventsAreIgnored() async {
        let player = RelayReplayPCMPlayer()
        var statuses: [String] = []
        let session = RealtimeTalkRelaySession(
            gateway: GatewayNodeSession(),
            options: .init(sessionKey: "fixture", provider: nil, model: nil, voice: nil),
            pcmPlayer: player,
            onStatus: { statuses.append($0) },
            onSpeakingChanged: { _ in })
        await session._test_handleGatewayEvent(Self.relayEvent("ready"))
        #expect(statuses.isEmpty)
        session._test_bindRelaySession("relay-current")
        await session._test_handleGatewayEvent(Self.relayEvent("ready", id: "relay-old"))
        #expect(statuses.isEmpty)
        session._test_retireRelaySession()
    }

    @Test func matchingRelayAcceptsAnOrdinaryFollowUpWithoutRestart() async {
        var statuses: [String] = []
        let session = RealtimeTalkRelaySession(
            gateway: GatewayNodeSession(),
            options: .init(sessionKey: "fixture", provider: nil, model: nil, voice: nil),
            pcmPlayer: RelayReplayPCMPlayer(),
            onStatus: { statuses.append($0) },
            onSpeakingChanged: { _ in })
        session._test_bindRelaySession("relay-current")
        for role in ["user", "assistant", "user", "assistant"] {
            await session._test_handleGatewayEvent(Self.relayEvent("transcript", fields: [
                "role": AnyCodable(role), "final": AnyCodable(true), "text": AnyCodable("fixture follow up")]))
        }
        #expect(statuses == ["Thinking…", "Listening (Realtime)", "Thinking…", "Listening (Realtime)"])
        session._test_retireRelaySession()
    }
}
