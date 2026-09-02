#if Talk
import XCTest
@testable import OpenClawKit

final class ElevenLabsTTSValidationTests: XCTestCase {
    func testValidatedOutputFormatAllowsOnlySupportedPCMAndMP3Presets() {
        XCTAssertEqual(ElevenLabsTTSClient.validatedOutputFormat("mp3_44100_128"), "mp3_44100_128")
        XCTAssertEqual(ElevenLabsTTSClient.validatedOutputFormat("pcm_16000"), "pcm_16000")
        XCTAssertEqual(ElevenLabsTTSClient.validatedOutputFormat("pcm_48000"), "pcm_48000")
        XCTAssertNil(ElevenLabsTTSClient.validatedOutputFormat("pcm_private"))
        XCTAssertNil(ElevenLabsTTSClient.validatedOutputFormat("mp3_44100_999"))
    }

    func testValidatedLanguageAcceptsTwoLetterCodes() {
        XCTAssertEqual(ElevenLabsTTSClient.validatedLanguage("EN"), "en")
        XCTAssertNil(ElevenLabsTTSClient.validatedLanguage("eng"))
    }

    func testValidatedNormalizeAcceptsKnownValues() {
        XCTAssertEqual(ElevenLabsTTSClient.validatedNormalize("AUTO"), "auto")
        XCTAssertNil(ElevenLabsTTSClient.validatedNormalize("maybe"))
    }
}
#endif
