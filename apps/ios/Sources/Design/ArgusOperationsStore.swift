import CryptoKit
import Foundation
import Observation
import OpenClawKit

enum ArgusEvidenceProject: String, CaseIterable, Sendable {
    case argus = "Argus"
    case miKobots = "MiKobots"
    case epc = "EPC"
}

struct ArgusOperation: Decodable, Identifiable, Sendable {
    struct Artifact: Decodable, Identifiable, Sendable {
        let sha256: String
        let bytes: Int?
        let displayName: String?
        var id: String { self.sha256 }

        init(sha256: String, bytes: Int?, displayName: String? = nil) {
            self.sha256 = sha256
            self.bytes = bytes
            self.displayName = displayName
        }

        private enum CodingKeys: String, CodingKey { case sha256, bytes, displayName }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.sha256 = try values.decode(String.self, forKey: .sha256)
            self.bytes = try values.decode(Int?.self, forKey: .bytes)
            self.displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
            if let name = self.displayName, !Self.isValidDisplayName(name) {
                throw DecodingError.dataCorruptedError(
                    forKey: .displayName, in: values, debugDescription: "Invalid artifact display name")
            }
        }

        static func isValidDisplayName(_ name: String) -> Bool {
            let scalars = name.unicodeScalars
            // Match the gateway/desktop ECMAScript trim whitespace-only predicate.
            let whitespaceOnly = scalars.allSatisfy {
                let value = $0.value
                return (9...13).contains(value) || value == 0x20 || value == 0xA0 || value == 0x1680
                    || (0x2000...0x200A).contains(value) || value == 0x2028 || value == 0x2029
                    || value == 0x202F || value == 0x205F || value == 0x3000 || value == 0xFEFF
            }
            guard (1...160).contains(scalars.count), name != ".", name != "..", !whitespaceOnly else {
                return false
            }
            return !scalars.contains {
                let value = $0.value
                return value == 47 || value == 92 || value <= 31 || (127...159).contains(value)
                    || value == 0x061C || value == 0x200E || value == 0x200F
                    || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
            }
        }

        var byteCountLabel: String { self.bytes.map { "\($0) bytes" } ?? "Size unknown" }

        func buttonLabel(operationLabel: String?) -> String {
            // Display metadata never changes the digest used for retrieval or review binding.
            self.displayName ?? operationLabel ?? "Artifact \(self.sha256.prefix(12))"
        }
    }

    let operationId: String
    let taskId: String
    let eventId: String
    let title: String
    let source: String
    let project: String
    let kind: String
    let state: String
    let occurredAt: String
    let observedAt: String
    let artifacts: [Artifact]
    let supersedesEventId: String?
    let ownerAccepted: Bool
    struct Display: Decodable, Sendable {
        let label: String
        let changeSummary: String?
        let artifactLabel: String?
        let continuationLabel: String?
        var isValid: Bool {
            (1...160).contains(self.label.count)
                && (self.changeSummary.map { (1...500).contains($0.count) } ?? true)
                && (self.artifactLabel.map { (1...160).contains($0.count) } ?? true)
                && (self.continuationLabel.map { (1...160).contains($0.count) } ?? true)
        }
    }
    var display: Display? = nil
    var evidenceScope: String? = nil
    var artifactContext: ArgusArtifactContext? = nil
    var id: String { self.operationId }

    var isAdmitted: Bool {
        guard ArgusEvidenceProject(rawValue: self.project) != nil, !self.ownerAccepted,
              !self.operationId.isEmpty, !self.taskId.isEmpty, !self.eventId.isEmpty,
              self.artifacts.count <= 100, self.display?.isValid != false else { return false }
        if self.source.hasPrefix("federation:") { return self.state == "observed" }
        return self.project == "Argus" && self.source == "canonical:codex-completion-adapter"
            && self.evidenceScope == "admitted_canonical_technical_operation"
            && Self.canonicalStates.contains(self.state)
    }

    static let canonicalStates: Set<String> = [
        "observed", "queued", "claimed", "running", "artifact_produced", "routed", "delivered",
        "acknowledged", "verified", "disposed", "blocked", "retry_scheduled", "failed",
        "dead_lettered", "expired", "superseded", "cancelled",
    ]
}

struct ArgusOperationsCoverage: Decodable, Sendable {
    let complete: Bool
    let hasMore: Bool
    let observedAt: String?
}

struct ArgusOperationsPage: Decodable, Sendable {
    let items: [ArgusOperation]
    let coverage: ArgusOperationsCoverage
    let nextCursor: String?
    let automaticDispatchEnabled: Bool
}

struct ArgusOperationDetail: Decodable, Sendable {
    let item: ArgusOperation
    let requested: ArgusOperation
    let timeline: [ArgusOperation]
    let coverage: ArgusOperationsCoverage
    let ownerAccepted: Bool
    var workContract: ArgusWorkContract? = nil
    var reviewHistory: ArgusReviewHistory? = nil

    static func requestParameters(for operation: ArgusOperation) -> [String: String] {
        ["operation_id": operation.id, "event_id": operation.eventId]
    }

    var displayTimeline: [ArgusOperation] {
        var seen = Set<String>()
        return ([self.item] + self.timeline + [self.requested]).filter { seen.insert($0.eventId).inserted }
    }

    func validate(for operation: ArgusOperation) throws {
        guard self.requested.id == operation.id, self.requested.eventId == operation.eventId, !self.ownerAccepted,
              self.timeline.count <= 256,
              ([self.item, self.requested] + self.timeline).allSatisfy({
                  $0.isAdmitted && $0.project == operation.project
                      && $0.taskId == operation.taskId && $0.source == operation.source
              }) else { throw ArgusOperationsError.invalidResponse }
        try self.workContract?.validate(for: self.item)
        try self.reviewHistory?.validate(for: self.item)
    }
}

struct ArgusOperationArtifact: Decodable, Identifiable, Sendable {
    let sha256: String
    let bytes: Int
    let mimeType: String
    let contentBase64: String
    let operationId: String
    var eventId: String? = nil
    var id: String { self.sha256 }

    var previewMimeType: String? {
        switch self.mimeType {
        case "text/plain", "text/plain; charset=utf-8": "text/plain"
        case "application/pdf", "image/png", "image/jpeg": self.mimeType
        default: nil
        }
    }

    func validatedData(
        for operation: String, eventID: String? = nil, artifact: ArgusOperation.Artifact) throws -> Data
    {
        guard self.operationId == operation, eventID == nil || self.eventId == eventID,
              self.sha256 == artifact.sha256,
              artifact.bytes.map({ self.bytes == $0 }) ?? true, (0...1_048_576).contains(self.bytes),
              self.previewMimeType != nil,
              self.contentBase64.utf8.count <= 1_398_104,
              let data = Data(base64Encoded: self.contentBase64), data.count == self.bytes,
              self.previewMimeType != "text/plain" || String(data: data, encoding: .utf8) != nil,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == self.sha256
        else { throw ArgusOperationsError.invalidResponse }
        return data
    }
}

struct ArgusArtifactPreview: Identifiable {
    let id: String
    let data: Data
    let mimeType: String
}

@MainActor
@Observable
final class ArgusArtifactOpenStore {
    private(set) var preview: ArgusArtifactPreview?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isAvailable = false

    func setAvailable(_ available: Bool) {
        self.invalidate()
        self.isAvailable = available
    }

    func invalidate() {
        self.generation += 1
        self.preview = nil
        self.isLoading = false
        self.error = nil
    }

    func dismissPreview() { self.preview = nil }

    func open(
        _ artifact: ArgusOperation.Artifact,
        item: ArgusOperation,
        fetch: ([String: String]) async throws -> ArgusOperationArtifact) async
    {
        guard self.isAvailable, !self.isLoading, !Task.isCancelled else { return }
        self.generation += 1
        let generation = self.generation
        self.isLoading = true
        self.preview = nil
        self.error = nil
        defer { if generation == self.generation { self.isLoading = false } }
        do {
            let response = try await fetch([
                "operation_id": item.id, "event_id": item.eventId, "sha256": artifact.sha256,
            ])
            guard generation == self.generation, !Task.isCancelled else { return }
            let data = try response.validatedData(for: item.id, eventID: item.eventId, artifact: artifact)
            guard let previewMimeType = response.previewMimeType else { throw ArgusOperationsError.invalidResponse }
            self.preview = ArgusArtifactPreview(id: "\(item.eventId):\(artifact.sha256)", data: data,
                                               mimeType: previewMimeType)
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            self.error = "Artifact unavailable or integrity verification failed. Nothing was opened."
        }
    }
}

enum ArgusOperationsError: Error {
    case unavailable
    case invalidResponse
}

struct ArgusOperationsClient: Sendable {
    let session: GatewayNodeSession
    let gatewayID: String

    func request<T: Decodable & Sendable>(_ method: String, params: [String: String], as _: T.Type) async throws -> T {
        guard let route = await self.session.currentRoute(ifGatewayID: self.gatewayID) else {
            throw ArgusOperationsError.unavailable
        }
        let encoded = try JSONSerialization.data(withJSONObject: params)
        let data = try await self.session.request(
            method: method,
            paramsJSON: String(decoding: encoded, as: UTF8.self),
            timeoutSeconds: 15,
            ifCurrentRoute: route)
        guard data.count <= 2_000_000 else { throw ArgusOperationsError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

@MainActor
@Observable
final class ArgusOperationsStore {
    private(set) var project: ArgusEvidenceProject = .argus
    private(set) var items: [ArgusOperation] = []
    private(set) var coverage: ArgusOperationsCoverage?
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var unavailable = true
    @ObservationIgnored private var gatewayID: String?
    @ObservationIgnored private var generation = 0

    // Keep only in-memory last observation, scoped to the selected paired
    // gateway. Switching pairings must not expose the previous gateway's work.
    func selectGateway(_ id: String?) {
        guard id != self.gatewayID else { return }
        self.gatewayID = id
        self.resetObservation()
    }

    func selectProject(_ project: ArgusEvidenceProject) {
        guard project != self.project else { return }
        self.project = project
        self.resetObservation()
    }

    private func resetObservation() {
        self.generation += 1
        self.items = []
        self.coverage = nil
        self.nextCursor = nil
        self.isLoading = false
        self.unavailable = true
    }

    func markUnavailable() {
        self.generation += 1
        self.isLoading = false
        self.unavailable = true
    }

    func refresh(using client: ArgusOperationsClient, more: Bool = false) async {
        await self.refresh(gatewayID: client.gatewayID, more: more) { params in
            try await client.request("argus.operations.list", params: params, as: ArgusOperationsPage.self)
        }
    }

    func refresh(
        gatewayID: String,
        more: Bool = false,
        fetch: ([String: String]) async throws -> ArgusOperationsPage
    ) async {
        guard !self.isLoading, self.gatewayID == gatewayID, !Task.isCancelled else { return }
        if more, self.nextCursor == nil { return }
        self.isLoading = true
        let generation = self.generation
        defer { if generation == self.generation { self.isLoading = false } }
        do {
            var params = ["project": self.project.rawValue]
            if more { params["cursor"] = self.nextCursor }
            let page = try await fetch(params)
            guard generation == self.generation, !Task.isCancelled else { return }
            try self.accept(page, more: more)
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            self.unavailable = true
        }
    }

    func accept(_ page: ArgusOperationsPage, more: Bool) throws {
        guard page.items.count <= 100, !page.automaticDispatchEnabled,
              page.items.allSatisfy({ $0.isAdmitted && $0.project == self.project.rawValue }),
              page.coverage.hasMore == (page.nextCursor != nil)
        else { throw ArgusOperationsError.invalidResponse }
        var merged = more ? self.items : []
        var ids = Set(merged.map(\.id))
        for item in page.items where ids.insert(item.id).inserted { merged.append(item) }
        self.items = merged
        self.coverage = page.coverage
        self.nextCursor = page.nextCursor
        self.unavailable = false
    }
}
