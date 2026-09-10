import AVFAudio
import Foundation
import OpenClawKit
import Testing

/// Native player experiment: synthetic PCM/MP3, no microphone, gateway or provider calls.
/// Run this suite alone. Simulator completion is not physical audibility evidence.
/// Compares playback-only and app-style playAndRecord categories; no capture or barge-in.
@MainActor
@Suite(.serialized)
struct VoicePlaybackBoundaryTests {
    enum SessionMode: String, Sendable {
        case playbackOnly
        case appStyleSpeaker
    }

    nonisolated static var sessionModes: [SessionMode] {
        #if os(iOS)
        [.playbackOnly, .appStyleSpeaker]
        #else
        [.playbackOnly]
        #endif
    }

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(String, TimeInterval)] = []

        func record(_ stage: String) {
            self.lock.lock()
            self.values.append((stage, ProcessInfo.processInfo.systemUptime))
            self.lock.unlock()
        }

        func time(_ stage: String) -> TimeInterval? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values.first { $0.0 == stage }?.1
        }

        func printReceipt(_ scenario: String, finished: Bool, bytes: Int) throws {
            self.lock.lock()
            let snapshot = self.values
            self.lock.unlock()
            let origin = snapshot.first?.1 ?? 0
            let receipt: [String: Any] = [
                "scenario": scenario, "finished": finished,
                "inputBytes": bytes, "sampleRate": 44100,
                "evidence": "native synthetic audio; no physical audibility claim",
                "events": snapshot.map { ["stage": $0.0, "seconds": $0.1 - origin] },
            ]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            print("VOICE_PLAYBACK_PROBE " + String(decoding: data, as: UTF8.self))
        }
    }

    private func prepareAudio(_ mode: SessionMode) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case .playbackOnly:
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        case .appStyleSpeaker:
            // Matches the production speaker-preferred category/options, without
            // installing a microphone tap or starting speech recognition.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [
                .allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker,
            ])
        }
        // Set both modes explicitly so test order cannot inherit another mode's preferences.
        try session.setPreferredSampleRate(mode == .appStyleSpeaker ? 48000 : 44100)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        if mode == .appStyleSpeaker { try session.overrideOutputAudioPort(.speaker) }
        let receipt: [String: Any] = [
            "mode": mode.rawValue, "category": session.category.rawValue,
            "sampleRate": session.sampleRate, "ioBufferDuration": session.ioBufferDuration,
            "preferredSampleRate": session.preferredSampleRate,
            "outputPorts": session.currentRoute.outputs.map { $0.portType.rawValue },
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("VOICE_PLAYBACK_SESSION " + String(decoding: data, as: UTF8.self))
        #endif
    }

    private func cleanupAudio() {
        _ = PCMStreamingAudioPlayer.shared.stop()
        _ = StreamingAudioPlayer.shared.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Little-endian 16-bit synthetic tone, avoiding microphone or private audio input.
    private func pcm(frames: Int) -> Data {
        var data = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let sample = Int16(sin(Double(frame) * 2 * .pi * 440 / 44100) * 1000)
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }

    private func play(
        _ stream: AsyncThrowingStream<Data, Error>,
        observations: Observations, mp3: Bool = false) async -> StreamingPlaybackResult
    {
        let watchdog = Task { @MainActor in
            // Cold native audio setup exceeded 11 seconds in the simulator. MP3
            // initializes off-main, so include that startup in its bounded watchdog.
            do { try await Task.sleep(for: .seconds(mp3 ? 30 : 8)) } catch { return }
            observations.record("watchdog_stop")
            if mp3 { _ = StreamingAudioPlayer.shared.stop() }
            else { _ = PCMStreamingAudioPlayer.shared.stop() }
        }
        defer { watchdog.cancel() }
        observations.record("play_called")
        let observer = StreamingPlaybackObserver { observations.record($0.stage.rawValue) }
        let result: StreamingPlaybackResult
        if mp3 {
            result = await StreamingAudioPlayer.shared.play(stream: stream, observer: observer)
        } else {
            result = await PCMStreamingAudioPlayer.shared.play(
                stream: stream, sampleRate: 44100, observer: observer)
        }
        observations.record("play_returned")
        return result
    }

    @Test(arguments: Self.sessionModes)
    func immediateEOFWaitsForKnownAudioDuration(mode: SessionMode) async throws {
        try self.prepareAudio(mode)
        defer { self.cleanupAudio() }
        let observations = Observations()
        let data = self.pcm(frames: 44100)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(data)
            continuation.finish()
        }
        let result = await self.play(stream, observations: observations)
        try observations.printReceipt("immediate-eof-\(mode.rawValue)", finished: result.finished, bytes: data.count)
        #expect(result.finished)
        #expect(observations.time("watchdog_stop") == nil)
        let accepted = try #require(observations.time("playback_submission_accepted"))
        let returned = try #require(observations.time("play_returned"))
        // 100 ms tolerance avoids treating scheduling jitter as sample-accurate proof.
        #expect(returned - accepted >= 0.9)
        #expect(observations.time("playback_completed") != nil)
    }

    @Test(arguments: Self.sessionModes)
    func starvedStreamWaitsForLateTailPlayback(mode: SessionMode) async throws {
        try self.prepareAudio(mode)
        defer { self.cleanupAudio() }
        let observations = Observations()
        let chunk = self.pcm(frames: 22050)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(chunk)
        let producer = Task { @MainActor in
            do {
                // Anchor starvation to actual submission, not potentially slow engine setup.
                while observations.time("playback_submission_accepted") == nil {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try await Task.sleep(for: .seconds(1))
            } catch { continuation.finish(); return }
            observations.record("tail_submitted")
            continuation.yield(chunk)
            continuation.finish()
        }
        defer { producer.cancel(); continuation.finish() }
        let result = await self.play(stream, observations: observations)
        try observations.printReceipt("starved-late-tail-\(mode.rawValue)", finished: result.finished, bytes: chunk.count * 2)
        #expect(result.finished)
        #expect(observations.time("watchdog_stop") == nil)
        let tail = try #require(observations.time("tail_submitted"))
        let returned = try #require(observations.time("play_returned"))
        #expect(returned - tail >= 0.4)
        #expect(observations.time("playback_completed") != nil)
    }

    @Test(arguments: Self.sessionModes)
    func consecutiveSegmentsEachDrainBeforeReplacement(mode: SessionMode) async throws {
        try self.prepareAudio(mode)
        defer { self.cleanupAudio() }
        let data = self.pcm(frames: 22050)
        for ordinal in 1...3 {
            let observations = Observations()
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(data)
                continuation.finish()
            }
            let result = await self.play(stream, observations: observations)
            try observations.printReceipt("consecutive-\(ordinal)-\(mode.rawValue)", finished: result.finished, bytes: data.count)
            #expect(result.finished)
            #expect(observations.time("watchdog_stop") == nil)
            let accepted = try #require(observations.time("playback_submission_accepted"))
            let returned = try #require(observations.time("play_returned"))
            #expect(returned - accepted >= 0.4)
            #expect(observations.time("playback_cancelled") == nil)
        }
    }

    func checkMP3EOF(mode: SessionMode) async throws {
        try self.prepareAudio(mode)
        defer { self.cleanupAudio() }
        let url = try #require(Bundle.module.url(
            forResource: "synthetic-1s-44100", withExtension: "mp3", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        #expect(data.count == 16718)
        // Whole prefetched payload versus network chunks that split MPEG frame boundaries.
        for chunkSize in [data.count, 137] {
            let observations = Observations()
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                for offset in stride(from: 0, to: data.count, by: chunkSize) {
                    continuation.yield(data.subdata(in: offset..<min(offset + chunkSize, data.count)))
                }
                continuation.finish()
            }
            let result = await self.play(stream, observations: observations, mp3: true)
            try observations.printReceipt(
                "mp3-eof-\(chunkSize)-\(mode.rawValue)", finished: result.finished, bytes: data.count)
            #expect(result.finished)
            #expect(observations.time("watchdog_stop") == nil)
            let accepted = try #require(observations.time("playback_submission_accepted"))
            let returned = try #require(observations.time("play_returned"))
            #expect(returned - accepted >= 0.9)
            #expect(observations.time("playback_completed") != nil)
            #expect(observations.time("playback_failed") == nil)
        }
    }


    /// Independently validates the same MP3 with Apple's file decoder and player.
    /// This does not exercise the production streaming parser or queue lifecycle.
    func checkMP3FileControl(mode: SessionMode) async throws {
        try self.prepareAudio(mode)
        defer { self.cleanupAudio() }
        let url = try #require(Bundle.module.url(
            forResource: "synthetic-1s-44100", withExtension: "mp3", subdirectory: "Fixtures"))
        let encodedBytes = try Data(contentsOf: url).count
        #expect(encodedBytes == 16718)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
        try file.read(into: buffer)
        let duration = Double(buffer.frameLength) / format.sampleRate
        #expect(duration >= 0.9 && duration <= 1.1)
        #expect(format.channelCount == 1)
        #expect(format.sampleRate == 44100)
        let samples = try #require(buffer.floatChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
        #expect(peak > 0.01 && peak < 0.1)
        print("VOICE_MP3_DECODE frames=\(buffer.frameLength) rate=\(format.sampleRate) duration=\(duration) peak=\(peak)")

        let player = try AVAudioPlayer(contentsOf: url)
        let observations = Observations()
        let delegate = MP3FileDelegate(observations: observations)
        player.delegate = delegate
        defer { player.stop(); player.delegate = nil }
        #expect(player.prepareToPlay())
        observations.record("play_called")
        #expect(player.play())
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while observations.time("file_playback_finished") == nil,
              observations.time("file_playback_failed") == nil,
              ProcessInfo.processInfo.systemUptime < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = observations.time("file_playback_finished")
        try observations.printReceipt(
            "mp3-file-control-\(mode.rawValue)", finished: completed != nil, bytes: encodedBytes)
        let start = try #require(observations.time("play_called"))
        #expect(try #require(completed) - start >= 0.9)
        #expect(observations.time("file_playback_failed") == nil)
        withExtendedLifetime(delegate) {}
    }

    private final class MP3FileDelegate: NSObject, AVAudioPlayerDelegate {
        let observations: Observations

        init(observations: Observations) { self.observations = observations }

        nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            self.observations.record(flag ? "file_playback_finished" : "file_playback_failed")
        }

        nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            self.observations.record("file_playback_failed")
        }
    }

    func checkStandardFloatOutput(mode: SessionMode) async throws {
        try self.prepareAudio(mode)
        defer { self.cleanupAudio() }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        buffer.frameLength = 44100
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<44100 {
            samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44100) * 1000 / 32768)
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        defer { node.stop(); engine.stop() }
        let observations = Observations()
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            observations.record("data_played_back")
        }
        try engine.start()
        observations.record("play_called")
        node.play()
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while observations.time("data_played_back") == nil,
              ProcessInfo.processInfo.systemUptime < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = observations.time("data_played_back")
        try observations.printReceipt(
            "direct-float-control-\(mode.rawValue)", finished: completed != nil, bytes: 44100 * 4)
        let start = try #require(observations.time("play_called"))
        #expect(try #require(completed) - start >= 0.9)
    }

}


/// Run independently from PCM failures: native format control and production MP3 path.
@MainActor
@Suite(.serialized)
struct VoicePlaybackControlTests {
    @Test(arguments: VoicePlaybackBoundaryTests.sessionModes)
    func mp3EOFWaitsForDecodedAudioDuration(mode: VoicePlaybackBoundaryTests.SessionMode) async throws {
        try await VoicePlaybackBoundaryTests().checkMP3EOF(mode: mode)
    }

    @Test(arguments: VoicePlaybackBoundaryTests.sessionModes)
    func standardFloatOutputCompletes(mode: VoicePlaybackBoundaryTests.SessionMode) async throws {
        try await VoicePlaybackBoundaryTests().checkStandardFloatOutput(mode: mode)
    }
}

/// Fresh process control for MP3 fixture validity and native file playback.
@MainActor
@Suite(.serialized)
struct VoiceMP3FileControlTests {
    @Test(arguments: VoicePlaybackBoundaryTests.sessionModes)
    func mp3FileDecodesAndPlays(mode: VoicePlaybackBoundaryTests.SessionMode) async throws {
        try await VoicePlaybackBoundaryTests().checkMP3FileControl(mode: mode)
    }
}
