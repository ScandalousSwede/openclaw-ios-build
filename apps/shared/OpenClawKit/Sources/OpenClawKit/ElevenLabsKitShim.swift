#if Talk
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
        var url = baseUrl
        url.appendPathComponent("v1")
        url.appendPathComponent("text-to-speech")
        url.appendPathComponent(voiceId)

        let body = try JSONSerialization.data(withJSONObject: Self.buildPayload(request), options: [])
        var urlRequest = Self.buildSynthesizeRequest(
            url: url,
            apiKey: apiKey,
            body: body,
            timeoutSeconds: requestTimeoutSeconds,
            outputFormat: request.outputFormat)

        if let latencyTier = request.latencyTier {
            urlRequest.url = Self.addLatencyTier(latencyTier, to: url)
        }

        let (data, response) = try await urlSession.data(for: urlRequest)
        if let http = response as? HTTPURLResponse {
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "unknown").lowercased()
            if http.statusCode >= 400 {
                throw NSError(domain: "ElevenLabsTTS", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "ElevenLabs failed: \(http.statusCode) ct=\(contentType) \(Self.truncatedErrorBody(data))",
                ])
            }
            if !Self.isAudioContentType(contentType, outputFormat: request.outputFormat) {
                throw NSError(domain: "ElevenLabsTTS", code: 415, userInfo: [
                    NSLocalizedDescriptionKey: "ElevenLabs returned non-audio ct=\(contentType) \(Self.truncatedErrorBody(data))",
                ])
            }
        }
        return data
    }

    public func streamSynthesize(
        voiceId: String,
        request: ElevenLabsTTSRequest
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let data = try await synthesize(voiceId: voiceId, request: request)
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
        guard trimmed.hasPrefix("mp3_") || trimmed.hasPrefix("pcm_") else { return nil }
        return trimmed
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
        if let outputFormat = request.outputFormat?.trimmingCharacters(in: .whitespacesAndNewlines), !outputFormat.isEmpty {
            payload["output_format"] = outputFormat
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

    private static func addLatencyTier(_ latencyTier: Int, to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "optimize_streaming_latency", value: String(latencyTier)),
        ]
        return components.url ?? url
    }

    private static func acceptHeader(for outputFormat: String?) -> String? {
        guard let outputFormat else { return nil }
        if outputFormat.hasPrefix("mp3_") { return "audio/mpeg" }
        if outputFormat.hasPrefix("pcm_") { return "audio/pcm" }
        return nil
    }

    private static func isAudioContentType(_ contentType: String, outputFormat: String?) -> Bool {
        if contentType.hasPrefix("audio/") || contentType == "application/octet-stream" {
            return true
        }
        if outputFormat?.hasPrefix("pcm_") == true, contentType == "binary/octet-stream" {
            return true
        }
        return false
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

@MainActor
public final class StreamingAudioPlayer {
    public static let shared = StreamingAudioPlayer()

    public func play(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult {
        do {
            for try await _ in stream {}
            return StreamingPlaybackResult(finished: true, interruptedAt: nil)
        } catch {
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
    }

    public func stop() -> Double? {
        nil
    }
}

@MainActor
public final class PCMStreamingAudioPlayer {
    public static let shared = PCMStreamingAudioPlayer()

    public func play(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult {
        do {
            for try await _ in stream {}
            return StreamingPlaybackResult(finished: true, interruptedAt: nil)
        } catch {
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
    }

    public func stop() -> Double? {
        nil
    }
}
#endif
