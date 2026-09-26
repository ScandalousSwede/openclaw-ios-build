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

@MainActor
private final class RelayStartupGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        self.entered = true
        let waiters = self.entryWaiters
        self.entryWaiters = []
        for waiter in waiters { waiter.resume() }
        guard !self.released else { return }
        await withCheckedContinuation { self.releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !self.entered else { return }
        await withCheckedContinuation { self.entryWaiters.append($0) }
    }

    func release() {
        self.released = true
        self.releaseWaiter?.resume()
        self.releaseWaiter = nil
    }
}

@MainActor
private final class RelayStartupRecorder {
    let createGate: RelayStartupGate?
    let subscribeGate: RelayStartupGate?
    let requestGate: RelayStartupGate?
    private(set) var createCount = 0
    private(set) var subscribeCount = 0
    private(set) var captureStarts = 0
    private(set) var captureStops = 0
    private(set) var closedIDs: [String] = []
    private(set) var requestedMethods: [String] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(createGate: RelayStartupGate? = nil, subscribeGate: RelayStartupGate? = nil,
         requestGate: RelayStartupGate? = nil) {
        self.createGate = createGate
        self.subscribeGate = subscribeGate
        self.requestGate = requestGate
    }

    func hooks() -> RealtimeTalkRelaySession.RelayTestHooks {
        .init(
            create: {
                self.createCount += 1
                await self.createGate?.suspend()
                return TalkSessionCreateResult(
                    sessionid: "synthetic-session", provider: nil,
                    mode: AnyCodable("realtime"), transport: AnyCodable("gateway-relay"),
                    brain: AnyCodable("agent-consult"), relaysessionid: "synthetic-created-relay",
                    transcriptionsessionid: nil, handoffid: nil, roomid: nil, roomurl: nil,
                    token: nil, audio: nil, model: nil, voice: nil, expiresat: nil)
            },
            subscribe: {
                self.subscribeCount += 1
                await self.subscribeGate?.suspend()
                return AsyncStream<EventFrame> { $0.finish() }
            },
            startCapture: { self.captureStarts += 1 },
            stopCapture: { self.captureStops += 1 },
            closeRelay: { id in
                self.closedIDs.append(id)
                let waiters = self.closeWaiters
                self.closeWaiters = []
                for waiter in waiters { waiter.resume() }
            },
            request: { method, _, _ in
                self.requestedMethods.append(method)
                await self.requestGate?.suspend()
                return method == "talk.client.toolCall"
                    ? Data(#"{"runId":"synthetic-run"}"#.utf8)
                    : Data(#"{"ok":true}"#.utf8)
            })
    }

    func waitForClose() async {
        guard self.closedIDs.isEmpty else { return }
        await withCheckedContinuation { self.closeWaiters.append($0) }
    }
}

extension RealtimeTalkRelaySessionTests {
    private static func startupSession(
        _ recorder: RelayStartupRecorder,
        onStatus: @escaping (String) -> Void = { _ in }) -> RealtimeTalkRelaySession
    {
        let session = RealtimeTalkRelaySession(
            gateway: GatewayNodeSession(),
            options: .init(sessionKey: "synthetic-start-fixture", provider: nil, model: nil, voice: nil),
            pcmPlayer: RelayReplayPCMPlayer(),
            onStatus: onStatus, onSpeakingChanged: { _ in })
        session._test_configureStartup(recorder.hooks())
        return session
    }

    private static func expectCancelled(_ startup: Task<Void, Error>) async {
        switch await startup.result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Retired startup must report cancellation")
        }
    }

    @Test func stopWhileCreateIsSuspendedClosesReturnedRelayWithoutCapture() async {
        let gate = RelayStartupGate()
        let recorder = RelayStartupRecorder(createGate: gate)
        var statuses: [String] = []
        let session = Self.startupSession(recorder, onStatus: { statuses.append($0) })
        defer { gate.release(); session.stop() }
        let startup = Task { try await session.start() }
        await gate.waitUntilEntered()
        session.stop()
        gate.release()
        await Self.expectCancelled(startup)
        #expect(recorder.captureStarts == 0)
        #expect(recorder.subscribeCount == 0)
        #expect(recorder.closedIDs == ["synthetic-created-relay"])
        #expect(statuses == ["Connecting realtime…"])
    }

    @Test func stopWhileSubscriptionIsSuspendedDoesNotReopenCaptureOrCloseTwice() async {
        let gate = RelayStartupGate()
        let recorder = RelayStartupRecorder(subscribeGate: gate)
        var statuses: [String] = []
        let session = Self.startupSession(recorder, onStatus: { statuses.append($0) })
        defer { gate.release(); session.stop() }
        let startup = Task { try await session.start() }
        await gate.waitUntilEntered()
        session.stop()
        await recorder.waitForClose()
        gate.release()
        await Self.expectCancelled(startup)
        #expect(recorder.captureStarts == 0)
        #expect(recorder.closedIDs == ["synthetic-created-relay"])
        #expect(statuses == ["Connecting realtime…"])
    }

    @Test func cancelledCreateContinuationClosesReturnedRelayWithoutCapture() async {
        let gate = RelayStartupGate()
        let recorder = RelayStartupRecorder(createGate: gate)
        let session = Self.startupSession(recorder)
        defer { gate.release(); session.stop() }
        let startup = Task { try await session.start() }
        await gate.waitUntilEntered()
        startup.cancel()
        gate.release()
        await Self.expectCancelled(startup)
        #expect(recorder.captureStarts == 0)
        #expect(recorder.subscribeCount == 0)
        #expect(recorder.closedIDs == ["synthetic-created-relay"])
    }

    @Test func stoppedInstanceCannotBeRearmedByAnAlreadyScheduledStart() async {
        let recorder = RelayStartupRecorder()
        let session = Self.startupSession(recorder)
        session.stop()
        await Self.expectCancelled(Task { try await session.start() })
        #expect(recorder.createCount == 0)
        #expect(recorder.captureStarts == 0)
        #expect(recorder.closedIDs.isEmpty)
    }

    @Test func ordinaryStartupCapturesOnceAndStopClosesItsBoundRelayOnce() async throws {
        let recorder = RelayStartupRecorder()
        var statuses: [String] = []
        let session = Self.startupSession(recorder, onStatus: { statuses.append($0) })
        defer { session.stop() }
        try await session.start()
        #expect(recorder.createCount == 1)
        #expect(recorder.subscribeCount == 1)
        #expect(recorder.captureStarts == 1)
        #expect(recorder.closedIDs.isEmpty)
        #expect(statuses == ["Connecting realtime…", "Listening (Realtime)"])
        session.stop()
        await recorder.waitForClose()
        #expect(recorder.closedIDs == ["synthetic-created-relay"])
        #expect(recorder.captureStops == 1)
    }
}

extension RealtimeTalkRelaySessionTests {
    @Test func retiredToolSubscriptionCannotDispatchOrRestoreListening() async {
        let gate = RelayStartupGate()
        let recorder = RelayStartupRecorder(subscribeGate: gate)
        var statuses: [String] = []
        let session = Self.startupSession(recorder, onStatus: { statuses.append($0) })
        session._test_bindRelaySession("relay-current")
        defer { gate.release(); session.stop() }
        let handling = Task {
            await session._test_handleGatewayEvent(Self.relayEvent("toolCall", fields: [
                "callId": AnyCodable("synthetic-call"), "name": AnyCodable("openclaw_agent_consult"),
            ]))
        }
        await gate.waitUntilEntered()
        session.stop()
        await recorder.waitForClose()
        gate.release()
        await handling.value
        // Record the actual native request boundary, rather than only its eventual
        // status: a later guard could hide a wrongly dispatched tool call.
        #expect(recorder.requestedMethods.isEmpty)
        #expect(statuses == ["Thinking…"])
        #expect(recorder.captureStarts == 0)
        #expect(recorder.closedIDs == ["relay-current"])
    }
}

extension RealtimeTalkRelaySessionTests {
    @Test func stopDuringToolStartReplyDoesNotSubmitAResultOrRestoreListening() async {
        let gate = RelayStartupGate()
        let recorder = RelayStartupRecorder(requestGate: gate)
        var statuses: [String] = []
        let session = Self.startupSession(recorder, onStatus: { statuses.append($0) })
        session._test_bindRelaySession("relay-current")
        defer { gate.release(); session.stop() }
        let handling = Task {
            await session._test_handleGatewayEvent(Self.relayEvent("toolCall", fields: [
                "callId": AnyCodable("synthetic-call"), "name": AnyCodable("openclaw_agent_consult"),
            ]))
        }
        await gate.waitUntilEntered()
        session.stop()
        await recorder.waitForClose()
        gate.release()
        await handling.value
        #expect(recorder.requestedMethods == ["talk.client.toolCall"])
        #expect(statuses == ["Thinking…"])
        #expect(recorder.captureStarts == 0)
        #expect(recorder.closedIDs == ["relay-current"])
    }
}
