import Testing
@testable import OpenClaw

@MainActor
@Suite struct TalkModeIncrementalSpeechBufferTests {
    @Test func emitsSoftBoundaryBeforeTerminalPunctuation() {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager._test_incrementalReset()

        let partial =
            "We start speaking earlier by splitting this long stream chunk at a whitespace boundary before punctuation arrives"
        let segments = manager._test_incrementalIngest(partial, isFinal: false)

        #expect(segments.count == 1)
        #expect(segments[0].count >= 72)
        #expect(segments[0].count < partial.count)
    }

    @Test func keepsShortChunkBufferedWithoutPunctuation() {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager._test_incrementalReset()

        let short = "short chunk without punctuation"
        let segments = manager._test_incrementalIngest(short, isFinal: false)

        #expect(segments.isEmpty)
    }

    @Test func cumulativeVoiceDirectiveDoesNotReplaySpokenPrefix() {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager._test_incrementalReset()
        let directive = #"{"voice":"fixture-voice"}"# + "\n"
        let first = manager._test_incrementalIngest(directive + "First sentence.", isFinal: false)
        let second = manager._test_incrementalIngest(
            directive + "First sentence. Second sentence.", isFinal: false)
        let final = manager._test_incrementalIngest(
            directive + "First sentence. Second sentence. Final sentence.", isFinal: true)
        #expect(first == ["First sentence."])
        #expect(second == ["Second sentence."])
        #expect(final == ["Final sentence."])
        #expect(manager._test_incrementalIngest(
            directive + "First sentence. Second sentence. Final sentence.", isFinal: true).isEmpty)
    }

    @Test func splitVoiceDirectiveRemainsStrippedInLaterSnapshots() {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager._test_incrementalReset()
        #expect(manager._test_incrementalIngest(#"{"lang":"en"}"#, isFinal: false).isEmpty)
        let prefix = #"{"lang":"en"}"# + "\n"
        #expect(manager._test_incrementalIngest(prefix + "Ready.", isFinal: false) == ["Ready."])
        #expect(manager._test_incrementalIngest(
            prefix + "Ready. This is the tail.", isFinal: true) == ["This is the tail."])
    }

    @Test func ordinaryJSONIsPreservedAcrossCumulativeSnapshots() {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager._test_incrementalReset()
        let prefix = #"{"count":12}"# + "\nThe first reading."
        let first = manager._test_incrementalIngest(prefix, isFinal: false)
        let second = manager._test_incrementalIngest(prefix + " More detail.", isFinal: true)
        #expect(first == [prefix])
        #expect(second == ["More detail."])
    }


    @Test func correctedSnapshotDoesNotStripDifferentDirectiveShapedContent() {
        let manager = TalkModeManager(allowSimulatorCapture: true)
        manager._test_incrementalReset()
        let original = #"{"voice":"fixture-voice"}"# + "\nFirst sentence."
        #expect(manager._test_incrementalIngest(original, isFinal: false) == ["First sentence."])
        let corrected = #"{"language":"Swift"}"# + "\nCorrected technical content."
        #expect(manager._test_incrementalIngest(corrected, isFinal: true) == [corrected])
    }

}
