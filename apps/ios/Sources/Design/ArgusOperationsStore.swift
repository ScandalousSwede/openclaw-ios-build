import CryptoKit
import Foundation
import Observation
import OpenClawKit

struct ArgusOperation: Decodable, Identifiable, Sendable {
    struct Artifact: Decodable, Identifiable, Sendable {
        let sha256: String
        let bytes: Int
        var id: String { self.sha256 }
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
    var id: String { self.operationId }
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
}

struct ArgusOperationArtifact: Decodable, Identifiable, Sendable {
    let sha256: String
    let bytes: Int
    let mimeType: String
    let contentBase64: String
    let operationId: String
    var id: String { self.sha256 }

    func validatedData(for operation: String, artifact: ArgusOperation.Artifact) throws -> Data {
        guard self.operationId == operation, self.sha256 == artifact.sha256,
              self.bytes == artifact.bytes, (0...1_048_576).contains(self.bytes),
              ["text/plain", "application/pdf", "image/png", "image/jpeg"].contains(self.mimeType),
              self.contentBase64.utf8.count <= 1_398_104,
              let data = Data(base64Encoded: self.contentBase64), data.count == self.bytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == self.sha256
        else { throw ArgusOperationsError.invalidResponse }
        return data
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
        guard !self.isLoading, self.gatewayID == client.gatewayID else { return }
        if more, self.nextCursor == nil { return }
        self.isLoading = true
        let generation = self.generation
        defer { if generation == self.generation { self.isLoading = false } }
        do {
            var params = ["project": "Argus"]
            if more { params["cursor"] = self.nextCursor }
            let page = try await client.request("argus.operations.list", params: params, as: ArgusOperationsPage.self)
            guard generation == self.generation else { return }
            try self.accept(page, more: more)
        } catch {
            guard generation == self.generation else { return }
            self.unavailable = true
        }
    }

    func accept(_ page: ArgusOperationsPage, more: Bool) throws {
        guard page.items.count <= 100, !page.automaticDispatchEnabled,
              page.items.allSatisfy({ $0.project == "Argus" && $0.state == "observed" && !$0.ownerAccepted }),
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
