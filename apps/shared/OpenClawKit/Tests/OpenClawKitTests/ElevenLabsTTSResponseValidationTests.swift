#if Talk
import Foundation
import os
import XCTest
@testable import OpenClawKit

private final class ElevenLabsResponseURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    static func install(host: String, _ value: @escaping Handler) {
        self.handlers.withLock { $0[host] = value }
    }

    static func remove(host: String) {
        self.handlers.withLock { $0.removeValue(forKey: host) }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = self.request.url?.host,
              let handler = Self.handlers.withLock({ $0[host] })
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ElevenLabsRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?
    private var bodyValue: Data?

    func record(_ request: URLRequest) {
        let body = Self.bodyData(from: request)
        self.lock.lock()
        self.value = request
        self.bodyValue = body
        self.lock.unlock()
    }

    var request: URLRequest? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }

    var body: Data? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.bodyValue
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
}

final class ElevenLabsTTSResponseValidationTests: XCTestCase {
    private struct Result {
        let chunks: [Data]
        let error: NSError?
        let metadata: ElevenLabsTTSResponseMetadata?
        let request: URLRequest?
        let requestBody: Data?
    }

    func testPCMFormatIsSentAsQueryAndNotUnsupportedBodyProperty() async throws {
        let result = await self.perform(
            outputFormat: "pcm_44100",
            data: Data([0x00, 0x00, 0x01, 0x00]),
            contentType: "audio/pcm; rate=44100",
            contentEncoding: "identity",
            latencyTier: 2)

        XCTAssertNil(result.error)
        let request = try XCTUnwrap(result.request)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["output_format"]!, "pcm_44100")
        XCTAssertEqual(query["optimize_streaming_latency"]!, "2")
        XCTAssertEqual((components.queryItems ?? []).filter { $0.name == "output_format" }.count, 1)
        let body = try XCTUnwrap(result.requestBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["output_format"])
    }

    func testEvenRawS16LEPCMIsValidatedAndPreservedByteExactly() async {
        let bytes = Data([0x00, 0x80, 0xFF, 0x7F])
        let result = await self.perform(
            outputFormat: "pcm_44100",
            data: bytes,
            contentType: "application/octet-stream")

        XCTAssertNil(result.error)
        XCTAssertEqual(result.chunks, [bytes])
        XCTAssertEqual(result.metadata?.validationResult, .codecValidated)
        XCTAssertEqual(result.metadata?.audioMagicType, .rawNoKnownHeader)
        XCTAssertEqual(result.metadata?.byteCountParity, .even)
        XCTAssertEqual(result.metadata?.declaredByteCount, bytes.count)
        XCTAssertEqual(result.metadata?.receivedByteCount, bytes.count)
        XCTAssertEqual(result.metadata?.httpStatus, 200)
        XCTAssertEqual(result.metadata?.contentType, "application/octet-stream")
        XCTAssertEqual(result.metadata?.contentEncoding, "identity")
    }

    func testPCMRequestRejectsMPEGResponsesBeforeYieldingBytes() async {
        for fixture in [
            Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0, 0, 0, 0]),
            Data([0xFF, 0xFB, 0x90, 0x64]),
        ] {
            let result = await self.perform(
                outputFormat: "pcm_44100",
                data: fixture,
                contentType: "audio/mpeg")

            XCTAssertEqual(result.error?.domain, "ElevenLabsAudioValidation")
            XCTAssertTrue(result.chunks.isEmpty)
            XCTAssertEqual(result.metadata?.validationResult, .codecMismatch)
            XCTAssertTrue(result.metadata.map {
                [ElevenLabsAudioMagicType.id3MPEG, .mpegFrameSync].contains($0.audioMagicType)
            } ?? false)
        }
    }

    func testPCMRequestRejectsRIFFAndOggContainers() async {
        let riff = Data([0x52, 0x49, 0x46, 0x46, 0x04, 0, 0, 0, 0x57, 0x41, 0x56, 0x45])
        var ogg = Data([0x4F, 0x67, 0x67, 0x53])
        ogg.append(Data(repeating: 0, count: 12))
        ogg.append(Data("OpusHead".utf8))
        for (fixture, magic, contentType) in [
            (riff, ElevenLabsAudioMagicType.riffWave, "audio/wav"),
            (ogg, ElevenLabsAudioMagicType.oggOpus, "application/octet-stream"),
        ] {
            let result = await self.perform(
                outputFormat: "pcm_44100",
                data: fixture,
                contentType: contentType)
            XCTAssertEqual(result.error?.domain, "ElevenLabsAudioValidation")
            XCTAssertTrue(result.chunks.isEmpty)
            XCTAssertEqual(result.metadata?.audioMagicType, magic)
            XCTAssertEqual(result.metadata?.validationResult, .codecMismatch)
        }
    }

    func testOddTerminalPCMByteIsRejectedAsFrameAlignmentFailure() async {
        let result = await self.perform(
            outputFormat: "pcm_44100",
            data: Data([0x00, 0x01, 0x02]),
            contentType: "audio/pcm")

        XCTAssertEqual(result.error?.domain, "ElevenLabsAudioValidation")
        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.metadata?.validationResult, .frameAlignmentInvalid)
        XCTAssertEqual(result.metadata?.byteCountParity, .odd)
    }

    func testEmptyPCMAndGenericMPEGTypedRawBytesFailBeforePlayback() async {
        let empty = await self.perform(
            outputFormat: "pcm_44100",
            data: Data(),
            contentType: "audio/pcm")
        XCTAssertEqual(empty.error?.domain, "ElevenLabsAudioValidation")
        XCTAssertEqual(empty.metadata?.validationResult, .emptyPayload)
        XCTAssertTrue(empty.chunks.isEmpty)

        let mislabeled = await self.perform(
            outputFormat: "pcm_44100",
            data: Data([0x00, 0x01, 0x02, 0x03]),
            contentType: "audio/mpeg")
        XCTAssertEqual(mislabeled.error?.domain, "ElevenLabsAudioValidation")
        XCTAssertEqual(mislabeled.metadata?.validationResult, .codecMismatch)
        XCTAssertTrue(mislabeled.chunks.isEmpty)
    }

    func testDeclaredAndReceivedByteCountsRemainDistinctSanitizedEvidence() async {
        let result = await self.perform(
            outputFormat: "pcm_44100",
            data: Data([0x00, 0x01, 0x02, 0x03]),
            contentType: "audio/pcm",
            declaredByteCount: 12)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.metadata?.declaredByteCount, 12)
        XCTAssertEqual(result.metadata?.receivedByteCount, 4)
    }

    func testMP3RequestAcceptsOnlyLocallyClassifiedMP3Bytes() async {
        for fixture in [
            Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0, 0, 0, 0]),
            Data([0xFF, 0xFB, 0x90, 0x64]),
        ] {
            let result = await self.perform(
                outputFormat: "mp3_44100_128",
                data: fixture,
                contentType: "application/octet-stream")
            XCTAssertNil(result.error)
            XCTAssertEqual(result.chunks, [fixture])
            XCTAssertEqual(result.metadata?.validationResult, .codecValidated)
        }

        let rawPCM = await self.perform(
            outputFormat: "mp3_44100_128",
            data: Data([0x00, 0x00, 0x01, 0x00]),
            contentType: "audio/mpeg")
        XCTAssertEqual(rawPCM.error?.domain, "ElevenLabsAudioValidation")
        XCTAssertTrue(rawPCM.chunks.isEmpty)
        XCTAssertEqual(rawPCM.metadata?.validationResult, .codecMismatch)
    }

    func testUnspecifiedFormatUsesVerifiedMP3DefaultWithoutAssumingGenericAudio() async {
        let mp3 = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0, 0, 0, 0])
        let accepted = await self.perform(outputFormat: nil, data: mp3, contentType: "audio/mpeg")
        XCTAssertNil(accepted.error)
        XCTAssertEqual(accepted.metadata?.requestedOutputFormat, "unspecified")
        XCTAssertEqual(accepted.metadata?.validationResult, .codecValidated)

        let generic = await self.perform(
            outputFormat: nil,
            data: Data([0x00, 0x00, 0x01, 0x00]),
            contentType: "audio/aac")
        XCTAssertEqual(generic.error?.domain, "ElevenLabsAudioValidation")
        XCTAssertEqual(generic.metadata?.validationResult, .codecMismatch)
    }

    func testUnsupportedFormatFailsLocallyWithoutContradictoryAcceptOrNetworkRequest() async {
        let result = await self.perform(
            outputFormat: "pcm_private",
            data: Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0, 0, 0, 0]),
            contentType: "audio/mpeg")

        XCTAssertEqual(result.error?.domain, "ElevenLabsAudioValidation")
        XCTAssertEqual(result.error?.code, 400)
        XCTAssertNil(result.request)
        XCTAssertNil(result.metadata)
        XCTAssertTrue(result.chunks.isEmpty)
    }

    private func perform(
        outputFormat: String?,
        data: Data,
        contentType: String,
        contentEncoding: String = "identity",
        latencyTier: Int? = nil,
        declaredByteCount: Int? = nil) async -> Result
    {
        let recorder = ElevenLabsRequestRecorder()
        let host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        ElevenLabsResponseURLProtocol.install(host: host) { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": contentType,
                    "Content-Encoding": contentEncoding,
                    "Content-Length": String(declaredByteCount ?? data.count),
                ])!
            return (response, data)
        }
        defer { ElevenLabsResponseURLProtocol.remove(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ElevenLabsResponseURLProtocol.self]
        let evidence = ElevenLabsTTSResponseEvidence()
        let request = ElevenLabsTTSRequest(
            text: "fixture",
            outputFormat: outputFormat,
            latencyTier: latencyTier)
        let stream = ElevenLabsTTSClient(
            apiKey: "fixture-key",
            baseUrl: URL(string: "https://\(host)")!,
            urlSession: URLSession(configuration: configuration))
            .streamSynthesize(
                voiceId: "fixture-voice",
                request: request,
                responseEvidence: evidence)
        var chunks: [Data] = []
        var caught: NSError?
        do {
            for try await chunk in stream {
                chunks.append(chunk)
            }
        } catch {
            caught = error as NSError
        }
        return Result(
            chunks: chunks,
            error: caught,
            metadata: evidence.snapshot,
            request: recorder.request,
            requestBody: recorder.body)
    }
}
#endif
