#if Talk
import ElevenLabsKit
import Foundation

public struct ElevenLabsVoice: Decodable, Sendable {
    public let voiceId: String
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case name
    }
}

public struct ElevenLabsTTSRequest: Sendable {
    public var text: String
    public var modelId: String?
    public var outputFormat: String?
    public var speed: Double?
    public var stability: Double?
    public var similarity: Double?
    public var style: Double?
    public var speakerBoost: Bool?
    public var seed: UInt32?
    public var normalize: String?
    public var language: String?
    public var latencyTier: Int?

    public init(
        text: String,
        modelId: String? = nil,
        outputFormat: String? = nil,
        speed: Double? = nil,
        stability: Double? = nil,
        similarity: Double? = nil,
        style: Double? = nil,
        speakerBoost: Bool? = nil,
        seed: UInt32? = nil,
        normalize: String? = nil,
        language: String? = nil,
        latencyTier: Int? = nil
    ) {
        self.text = text
        self.modelId = modelId
        self.outputFormat = outputFormat
        self.speed = speed
        self.stability = stability
        self.similarity = similarity
        self.style = style
        self.speakerBoost = speakerBoost
        self.seed = seed
        self.normalize = normalize
        self.language = language
        self.latencyTier = latencyTier
    }
}

public enum ElevenLabsAudioMagicType: String, Codable, Sendable {
    case id3MPEG = "id3_mpeg"
    case mpegFrameSync = "mpeg_frame_sync"
    case riffWave = "riff_wave"
    case oggContainer = "ogg_container"
    case oggOpus = "ogg_opus"
    case rawNoKnownHeader = "raw_no_known_header"
    case empty
}

public enum ElevenLabsAudioByteParity: String, Codable, Sendable {
    case even
    case odd
}

public enum ElevenLabsAudioValidationResult: String, Codable, Sendable {
    case codecValidated = "codec_validated"
    case codecMismatch = "codec_mismatch"
    case frameAlignmentInvalid = "frame_alignment_invalid"
    case emptyPayload = "empty_payload"
    case httpError = "http_error"
}

public struct ElevenLabsTTSResponseMetadata: Codable, Equatable, Sendable {
    public let requestedOutputFormat: String
    public let httpStatus: Int
    public let contentType: String
    public let contentEncoding: String
    public let declaredByteCount: Int?
    public let receivedByteCount: Int
    public let byteCountParity: ElevenLabsAudioByteParity
    public let audioMagicType: ElevenLabsAudioMagicType
    public let validationResult: ElevenLabsAudioValidationResult

    public init(
        requestedOutputFormat: String,
        httpStatus: Int,
        contentType: String,
        contentEncoding: String,
        declaredByteCount: Int?,
        receivedByteCount: Int,
        byteCountParity: ElevenLabsAudioByteParity,
        audioMagicType: ElevenLabsAudioMagicType,
        validationResult: ElevenLabsAudioValidationResult)
    {
        self.requestedOutputFormat = requestedOutputFormat
        self.httpStatus = httpStatus
        self.contentType = contentType
        self.contentEncoding = contentEncoding
        self.declaredByteCount = declaredByteCount
        self.receivedByteCount = receivedByteCount
        self.byteCountParity = byteCountParity
        self.audioMagicType = audioMagicType
        self.validationResult = validationResult
    }
}

public final class ElevenLabsTTSResponseEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ElevenLabsTTSResponseMetadata?

    public init() {}

    public func record(_ metadata: ElevenLabsTTSResponseMetadata) {
        self.lock.lock()
        self.value = metadata
        self.lock.unlock()
    }

    public var snapshot: ElevenLabsTTSResponseMetadata? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

public struct ElevenLabsTTSClient: Sendable {
    public var apiKey: String
    public var requestTimeoutSeconds: TimeInterval
    public var listVoicesTimeoutSeconds: TimeInterval
    public var baseUrl: URL

    private let urlSession: URLSession
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        apiKey: String,
        requestTimeoutSeconds: TimeInterval = 45,
        listVoicesTimeoutSeconds: TimeInterval = 15,
        baseUrl: URL = URL(string: "https://api.elevenlabs.io")!,
        urlSession: URLSession = .shared,
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.listVoicesTimeoutSeconds = listVoicesTimeoutSeconds
        self.baseUrl = baseUrl
        self.urlSession = urlSession
        self.sleep = sleep ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    public func synthesizeWithHardTimeout(
        voiceId: String,
        request: ElevenLabsTTSRequest,
        hardTimeoutSeconds: TimeInterval
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await synthesize(voiceId: voiceId, request: request)
            }
            group.addTask {
                await sleep(hardTimeoutSeconds)
                throw NSError(domain: "ElevenLabsTTS", code: 408, userInfo: [
                    NSLocalizedDescriptionKey: "ElevenLabs TTS timed out after \(hardTimeoutSeconds)s",
                ])
            }
            let data = try await group.next()!
            group.cancelAll()
            return data
        }
    }

    public func synthesize(voiceId: String, request: ElevenLabsTTSRequest) async throws -> Data {
        try await self.synthesize(voiceId: voiceId, request: request, responseEvidence: nil)
    }

    private func synthesize(
        voiceId: String,
        request: ElevenLabsTTSRequest,
        responseEvidence: ElevenLabsTTSResponseEvidence?) async throws -> Data
    {
        let outputFormat = try Self.resolvedOutputFormat(request.outputFormat)
        var url = baseUrl
        url.appendPathComponent("v1")
        url.appendPathComponent("text-to-speech")
        url.appendPathComponent(voiceId)
        url = Self.addSynthesisQuery(
            outputFormat: outputFormat,
            latencyTier: request.latencyTier,
            to: url)

        let body = try JSONSerialization.data(withJSONObject: Self.buildPayload(request), options: [])
        let urlRequest = Self.buildSynthesizeRequest(
            url: url,
            apiKey: apiKey,
            body: body,
            timeoutSeconds: requestTimeoutSeconds,
            outputFormat: outputFormat)

        let (data, response) = try await urlSession.data(for: urlRequest)
        if let http = response as? HTTPURLResponse {
            let metadata = Self.responseMetadata(
                http: http,
                data: data,
                requestedOutputFormat: outputFormat)
            responseEvidence?.record(metadata)
            if http.statusCode >= 400 {
                throw NSError(domain: "ElevenLabsTTS", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "ElevenLabs failed: \(http.statusCode) ct=\(metadata.contentType) \(Self.truncatedErrorBody(data))",
                ])
            }
            if metadata.validationResult != .codecValidated {
                throw NSError(domain: "ElevenLabsAudioValidation", code: 415, userInfo: [
                    NSLocalizedDescriptionKey: "ElevenLabs response did not match output_format=\(metadata.requestedOutputFormat) validation=\(metadata.validationResult.rawValue)",
                ])
            }
        } else {
            throw NSError(domain: "ElevenLabsAudioValidation", code: 415, userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs response did not include HTTP metadata",
            ])
        }
        return data
    }

    public func streamSynthesize(
        voiceId: String,
        request: ElevenLabsTTSRequest,
        responseEvidence: ElevenLabsTTSResponseEvidence? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let data = try await synthesize(
                        voiceId: voiceId,
                        request: request,
                        responseEvidence: responseEvidence)
                    continuation.yield(data)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func listVoices() async throws -> [ElevenLabsVoice] {
        var url = baseUrl
        url.appendPathComponent("v1")
        url.appendPathComponent("voices")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = listVoicesTimeoutSeconds
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "ElevenLabsTTS", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs voices failed: \(http.statusCode) \(Self.truncatedErrorBody(data))",
            ])
        }

        struct VoicesResponse: Decodable { let voices: [ElevenLabsVoice] }
        return try JSONDecoder().decode(VoicesResponse.self, from: data).voices
    }

    public static func validatedOutputFormat(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pcmFormats: Set<String> = [
            "pcm_8000", "pcm_16000", "pcm_22050", "pcm_24000", "pcm_44100", "pcm_48000",
        ]
        let mp3Formats: Set<String> = [
            "mp3_22050_32",
            "mp3_44100_32", "mp3_44100_64", "mp3_44100_96", "mp3_44100_128", "mp3_44100_192",
        ]
        guard pcmFormats.contains(trimmed) || mp3Formats.contains(trimmed) else { return nil }
        return trimmed
    }

    private static func resolvedOutputFormat(_ value: String?) throws -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let outputFormat = validatedOutputFormat(trimmed) else {
            throw NSError(domain: "ElevenLabsAudioValidation", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported ElevenLabs output format",
            ])
        }
        return outputFormat
    }

    public static func validatedLanguage(_ value: String?) -> String? {
        let normalized = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 2, normalized.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return nil }
        return normalized
    }

    public static func validatedNormalize(_ value: String?) -> String? {
        let normalized = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["auto", "on", "off"].contains(normalized) else { return nil }
        return normalized
    }

    private static func buildPayload(_ request: ElevenLabsTTSRequest) -> [String: Any] {
        var payload: [String: Any] = ["text": request.text]
        if let modelId = request.modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !modelId.isEmpty {
            payload["model_id"] = modelId
        }
        if let seed = request.seed {
            payload["seed"] = seed
        }
        if let normalize = request.normalize {
            payload["apply_text_normalization"] = normalize
        }
        if let language = request.language {
            payload["language_code"] = language
        }

        var voiceSettings: [String: Any] = [:]
        if let speed = request.speed { voiceSettings["speed"] = speed }
        if let stability = request.stability { voiceSettings["stability"] = stability }
        if let similarity = request.similarity { voiceSettings["similarity_boost"] = similarity }
        if let style = request.style { voiceSettings["style"] = style }
        if let speakerBoost = request.speakerBoost { voiceSettings["use_speaker_boost"] = speakerBoost }
        if !voiceSettings.isEmpty {
            payload["voice_settings"] = voiceSettings
        }
        return payload
    }

    private static func buildSynthesizeRequest(
        url: URL,
        apiKey: String,
        body: Data,
        timeoutSeconds: TimeInterval,
        outputFormat: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accept = acceptHeader(for: outputFormat) {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private static func addSynthesisQuery(
        outputFormat: String?,
        latencyTier: Int?,
        to url: URL) -> URL
    {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var queryItems = (components.queryItems ?? []).filter {
            $0.name != "output_format" && $0.name != "optimize_streaming_latency"
        }
        if let outputFormat {
            queryItems.append(URLQueryItem(name: "output_format", value: outputFormat))
        }
        if let latencyTier {
            queryItems.append(URLQueryItem(
                name: "optimize_streaming_latency",
                value: String(latencyTier)))
        }
        components.queryItems = queryItems
        return components.url ?? url
    }

    private static func acceptHeader(for outputFormat: String?) -> String? {
        guard let outputFormat else { return nil }
        if outputFormat.hasPrefix("mp3_") { return "audio/mpeg" }
        if outputFormat.hasPrefix("pcm_") { return "audio/pcm" }
        return nil
    }

    private static func responseMetadata(
        http: HTTPURLResponse,
        data: Data,
        requestedOutputFormat: String?) -> ElevenLabsTTSResponseMetadata
    {
        let outputFormat = validatedOutputFormat(requestedOutputFormat) ?? "unspecified"
        let contentType = sanitizedHeaderValue(
            http.value(forHTTPHeaderField: "Content-Type"),
            fallback: "absent")
        let contentEncoding = sanitizedHeaderValue(
            http.value(forHTTPHeaderField: "Content-Encoding"),
            fallback: "identity")
        let declaredByteCount = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int.init)
            .flatMap { $0 >= 0 ? $0 : nil }
        let magicType = classifyAudioMagic(data)
        let parity: ElevenLabsAudioByteParity = data.count.isMultiple(of: 2) ? .even : .odd
        let validationResult = validateAudioResponse(
            outputFormat: outputFormat,
            contentType: contentType,
            data: data,
            magicType: magicType)
        return ElevenLabsTTSResponseMetadata(
            requestedOutputFormat: outputFormat,
            httpStatus: http.statusCode,
            contentType: contentType,
            contentEncoding: contentEncoding,
            declaredByteCount: declaredByteCount,
            receivedByteCount: data.count,
            byteCountParity: parity,
            audioMagicType: magicType,
            validationResult: http.statusCode >= 400 ? .httpError : validationResult)
    }

    private static func validateAudioResponse(
        outputFormat: String,
        contentType: String,
        data: Data,
        magicType: ElevenLabsAudioMagicType) -> ElevenLabsAudioValidationResult
    {
        guard !data.isEmpty else { return .emptyPayload }
        let baseContentType = contentType.split(separator: ";", maxSplits: 1)
            .first.map(String.init) ?? contentType
        if outputFormat.hasPrefix("pcm_") {
            guard magicType == .rawNoKnownHeader else { return .codecMismatch }
            let acceptedPCMTypes: Set<String> = [
                "application/octet-stream", "audio/l16", "audio/pcm", "audio/x-pcm", "binary/octet-stream",
            ]
            guard acceptedPCMTypes.contains(baseContentType) else { return .codecMismatch }
            return data.count.isMultiple(of: 2) ? .codecValidated : .frameAlignmentInvalid
        }
        if outputFormat == "unspecified" || outputFormat.hasPrefix("mp3_") {
            let acceptedMP3Types: Set<String> = [
                "application/octet-stream", "audio/mp3", "audio/mpeg", "binary/octet-stream",
            ]
            guard acceptedMP3Types.contains(baseContentType) else { return .codecMismatch }
            return [.id3MPEG, .mpegFrameSync].contains(magicType) ? .codecValidated : .codecMismatch
        }
        return .codecMismatch
    }

    private static func classifyAudioMagic(_ data: Data) -> ElevenLabsAudioMagicType {
        guard !data.isEmpty else { return .empty }
        let prefix = Array(data.prefix(64))
        if prefix.count >= 10,
           prefix.starts(with: [0x49, 0x44, 0x33]),
           (2...4).contains(prefix[3]),
           prefix[4] != 0xFF,
           prefix[6...9].allSatisfy({ $0 & 0x80 == 0 })
        {
            return .id3MPEG
        }
        if prefix.count >= 12,
           prefix.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(prefix[8...11]) == [0x57, 0x41, 0x56, 0x45]
        {
            return .riffWave
        }
        if prefix.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
            let opusHeader = Data("OpusHead".utf8)
            return data.prefix(64).range(of: opusHeader) == nil ? .oggContainer : .oggOpus
        }
        if prefix.count >= 4,
           prefix[0] == 0xFF,
           prefix[1] & 0xE0 == 0xE0,
           ((prefix[1] >> 3) & 0x03) != 0x01,
           ((prefix[1] >> 1) & 0x03) != 0,
           (prefix[2] >> 4) != 0,
           (prefix[2] >> 4) != 0x0F,
           ((prefix[2] >> 2) & 0x03) != 0x03
        {
            return .mpegFrameSync
        }
        return .rawNoKnownHeader
    }

    private static func sanitizedHeaderValue(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 128 else { return "redacted" }
        let permitted = normalized.utf8.allSatisfy { byte in
            switch byte {
            case 32, 43...59, 61, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
        return permitted ? normalized : "redacted"
    }

    private static func truncatedErrorBody(_ data: Data) -> String {
        let raw = String(data: data.prefix(4096), encoding: .utf8) ?? "unknown"
        return raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

public enum TalkTTSValidation: Sendable {
    private static let v3StabilityValues: Set<Double> = [0.0, 0.5, 1.0]

    public static func resolveSpeed(speed: Double?, rateWPM: Int?) -> Double? {
        if let rateWPM, rateWPM > 0 {
            let resolved = Double(rateWPM) / 175.0
            if resolved <= 0.5 || resolved >= 2.0 { return nil }
            return resolved
        }
        if let speed {
            if speed <= 0.5 || speed >= 2.0 { return nil }
            return speed
        }
        return nil
    }

    public static func validatedUnit(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value < 0 || value > 1 { return nil }
        return value
    }

    public static func validatedStability(_ value: Double?, modelId: String?) -> Double? {
        guard let value else { return nil }
        let normalizedModel = (modelId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedModel == "eleven_v3" {
            return v3StabilityValues.contains(value) ? value : nil
        }
        return validatedUnit(value)
    }

    public static func validatedSeed(_ value: Int?) -> UInt32? {
        guard let value else { return nil }
        if value < 0 || value > 4_294_967_295 { return nil }
        return UInt32(value)
    }

    public static func validatedLatencyTier(_ value: Int?) -> Int? {
        guard let value else { return nil }
        if value < 0 || value > 4 { return nil }
        return value
    }

    public static func pcmSampleRate(from outputFormat: String?) -> Double? {
        let trimmed = (outputFormat ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("pcm_") else { return nil }
        let parts = trimmed.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let rate = Double(parts[1]), rate > 0 else { return nil }
        return rate
    }
}

public struct StreamingPlaybackResult: Sendable {
    public let finished: Bool
    public let interruptedAt: Double?

    public init(finished: Bool, interruptedAt: Double?) {
        self.finished = finished
        self.interruptedAt = interruptedAt
    }
}

public enum StreamingPlaybackPath: String, Sendable {
    case pcm
    case mp3
}

public enum StreamingPlaybackObservationStage: String, Sendable {
    case decoderCreated = "decoder_created"
    case playerInstanceCreated = "player_instance_created"
    case playerInstanceDeallocated = "player_instance_deallocated"
    case playbackSubmissionStarted = "playback_submission_started"
    case playbackSubmissionAccepted = "playback_submission_accepted"
    case firstRenderCallbackObserved = "first_render_callback_observed"
    case playbackCompleted = "playback_completed"
    case playbackFailed = "playback_failed"
    case playbackCancelled = "playback_cancelled"
}

public struct StreamingPlaybackObservation: Equatable, Sendable {
    public let stage: StreamingPlaybackObservationStage
    public let path: StreamingPlaybackPath

    public init(stage: StreamingPlaybackObservationStage, path: StreamingPlaybackPath) {
        self.stage = stage
        self.path = path
    }

    fileprivate init(_ observation: ElevenLabsKit.ElevenLabsPlaybackObservation) {
        self.stage = switch observation.stage {
        case .decoderCreated: .decoderCreated
        case .playerInstanceCreated: .playerInstanceCreated
        case .playerInstanceDeallocated: .playerInstanceDeallocated
        case .playbackSubmissionStarted: .playbackSubmissionStarted
        case .playbackSubmissionAccepted: .playbackSubmissionAccepted
        case .firstRenderCallbackObserved: .firstRenderCallbackObserved
        case .playbackCompleted: .playbackCompleted
        case .playbackFailed: .playbackFailed
        case .playbackCancelled: .playbackCancelled
        }
        self.path = switch observation.path {
        case .pcm: .pcm
        case .mp3: .mp3
        }
    }
}

public struct StreamingPlaybackObserver: Sendable {
    fileprivate let handler: @Sendable (StreamingPlaybackObservation) -> Void

    public init(
        _ handler: @escaping @Sendable (StreamingPlaybackObservation) -> Void = { _ in }
    ) {
        self.handler = handler
    }

    public func record(_ observation: StreamingPlaybackObservation) {
        self.handler(observation)
    }

    fileprivate var dependencyObserver: ElevenLabsKit.ElevenLabsPlaybackObserver {
        ElevenLabsKit.ElevenLabsPlaybackObserver { observation in
            self.record(StreamingPlaybackObservation(observation))
        }
    }
}

@MainActor
public final class StreamingAudioPlayer {
    public static let shared = StreamingAudioPlayer()

    private let player: ElevenLabsKit.StreamingAudioPlayer

    init(player: ElevenLabsKit.StreamingAudioPlayer = .shared) {
        self.player = player
    }

    public func play(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult {
        return await self.play(stream: stream, observer: StreamingPlaybackObserver())
    }

    public func play(
        stream: AsyncThrowingStream<Data, Error>,
        observer: StreamingPlaybackObserver
    ) async -> StreamingPlaybackResult {
        let result = await self.player.play(
            stream: stream,
            observer: observer.dependencyObserver)
        return StreamingPlaybackResult(
            finished: result.finished,
            interruptedAt: result.interruptedAt)
    }

    public func stop() -> Double? {
        self.player.stop()
    }
}

@MainActor
public final class PCMStreamingAudioPlayer {
    public static let shared = PCMStreamingAudioPlayer()

    private let player: ElevenLabsKit.PCMStreamingAudioPlayer

    init(player: ElevenLabsKit.PCMStreamingAudioPlayer = .shared) {
        self.player = player
    }

    public func play(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult {
        return await self.play(
            stream: stream,
            sampleRate: sampleRate,
            observer: StreamingPlaybackObserver())
    }

    public func play(
        stream: AsyncThrowingStream<Data, Error>,
        sampleRate: Double,
        observer: StreamingPlaybackObserver
    ) async -> StreamingPlaybackResult {
        let result = await self.player.play(
            stream: stream,
            sampleRate: sampleRate,
            observer: observer.dependencyObserver)
        return StreamingPlaybackResult(
            finished: result.finished,
            interruptedAt: result.interruptedAt)
    }

    public func stop() -> Double? {
        self.player.stop()
    }
}
#endif
