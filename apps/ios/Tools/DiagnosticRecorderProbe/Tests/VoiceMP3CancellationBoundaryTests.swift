#if os(macOS)
import AudioToolbox
@testable import ElevenLabsKit
import Foundation
import OSLog
import Testing

// SwiftPM Release enables testing for the unchanged production dependency.
// This is a deterministic injected-client lifetime test, not native audio proof.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct VoiceMP3CancellationBoundaryTests {
    enum Operation: String, CaseIterable, Sendable { case open, parse, queue }

    final class Probe: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var active = false
        private var counts: [String: Int] = [:]

        func count(_ event: String) {
            lock.lock()
            counts[event, default: 0] += 1
            if active, event == "close" || event == "dispose" {
                counts["teardownWhileActive", default: 0] += 1
            }
            lock.unlock()
        }

        func hold() {
            lock.lock(); active = true; lock.unlock()
            entered.signal()
            let released = release.wait(timeout: .now() + 10) == .success
            lock.lock()
            if !released { counts["holdTimeout", default: 0] += 1 }
            active = false
            lock.unlock()
        }

        func snapshot() -> [String: Int] {
            lock.lock(); defer { lock.unlock() }; return counts
        }
    }

    private func wait(_ signal: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: signal.wait(timeout: .now() + 12) == .success)
            }
        }
    }

    @Test(arguments: Operation.allCases, [false, true])
    func finishPreservesInFlightAudioLifetime(operation: Operation, overlap: Bool) async throws {
        let probe = Probe()
        var audio = AudioToolboxClient.live
        audio.fileStreamOpen = { _, _, _, _, output in
            probe.count("open")
            if operation == .open { probe.hold() }
            output.pointee = OpaquePointer(bitPattern: 1)
            return noErr
        }
        audio.fileStreamParseBytes = { _, _, _, _ in
            probe.count("parse")
            if operation == .parse { probe.hold() }
            return noErr
        }
        audio.fileStreamClose = { _ in probe.count("close"); return noErr }
        audio.queueNewOutput = { _, _, _, _, _, _, output in
            probe.count("queue")
            if operation == .queue { probe.hold() }
            output.pointee = OpaquePointer(bitPattern: 2)
            return noErr
        }
        audio.queueAddPropertyListener = { _, _, _, _ in noErr }
        audio.fileStreamGetPropertyInfo = { _, _, size, writable in
            size.pointee = 0; writable.pointee = false; return noErr
        }
        // No packet callback runs in this ownership discriminator. Avoid real
        // buffers and never hand the synthetic queue pointer to AudioToolbox.
        audio.queueAllocateBuffer = { _, _, output in output.pointee = nil; return -1 }
        audio.queueGetCurrentTime = { _, _, _, _ in -1 }
        audio.queueStop = { _, _ in probe.count("stop"); return noErr }
        audio.queueDispose = { _, _ in probe.count("dispose"); return noErr }
        let playback = StreamingAudioPlayback(
            logger: Logger(subsystem: "test.voice", category: "cancellation"),
            audio: audio,
            scheduleParseWork: { $0() })
        if operation != .open { playback.start() }
        let fixture = try #require(Bundle.module.url(
            forResource: "synthetic-1s-44100", withExtension: "mp3", subdirectory: "Fixtures"))
        let payload = try Data(contentsOf: fixture)
        #expect(payload.count == 16_718)
        DispatchQueue.global().async {
            switch operation {
            case .open: playback.start()
            case .parse: playback.append(payload)
            case .queue:
                var format = AudioStreamBasicDescription()
                format.mSampleRate = 44_100
                playback.setupQueueIfNeeded(format)
            }
            probe.done.signal()
        }
        let entered = await wait(probe.entered)
        defer { probe.release.signal() }
        try #require(entered)
        if overlap {
            playback.observeCancellationIfActive()
            _ = playback.stop(immediate: true)
            playback.finish(StreamingPlaybackResult(finished: false, interruptedAt: nil))
        }
        probe.release.signal()
        let completed = await wait(probe.done)
        try #require(completed)
        if !overlap {
            playback.observeCancellationIfActive()
            _ = playback.stop(immediate: true)
        }
        // A repeat finish must not be required to recover a late-created handle.
        playback.finish(StreamingPlaybackResult(finished: false, interruptedAt: nil))
        let counts = probe.snapshot()
        print("MP3_CANCEL_BOUNDARY operation=\(operation.rawValue) overlap=\(overlap) counts=\(counts)")
        #expect(counts["holdTimeout", default: 0] == 0)
        #expect(counts["teardownWhileActive", default: 0] == 0)
        #expect(counts["close", default: 0] == 1)
        #expect(counts["dispose", default: 0] == (operation == .queue ? 1 : 0))
    }
}
#endif
