#if Talk
import Foundation

@MainActor
public protocol StreamingAudioPlaying {
    func play(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult
    func play(
        stream: AsyncThrowingStream<Data, Error>,
        observer: StreamingPlaybackObserver) async -> StreamingPlaybackResult
    func stop() -> Double?
}

public extension StreamingAudioPlaying {
    func play(
        stream: AsyncThrowingStream<Data, Error>,
        observer _: StreamingPlaybackObserver) async -> StreamingPlaybackResult
    {
        await self.play(stream: stream)
    }
}

@MainActor
public protocol PCMStreamingAudioPlaying {
    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult
    func play(
        stream: AsyncThrowingStream<Data, Error>,
        sampleRate: Double,
        observer: StreamingPlaybackObserver) async -> StreamingPlaybackResult
    func stop() -> Double?
}

public extension PCMStreamingAudioPlaying {
    func play(
        stream: AsyncThrowingStream<Data, Error>,
        sampleRate: Double,
        observer _: StreamingPlaybackObserver) async -> StreamingPlaybackResult
    {
        await self.play(stream: stream, sampleRate: sampleRate)
    }
}

extension StreamingAudioPlayer: StreamingAudioPlaying {}
extension PCMStreamingAudioPlayer: PCMStreamingAudioPlaying {}
#endif
