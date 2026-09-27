import Foundation

// The gateway is a relay, not an approval authority. This read contract only
// produces reviewable content after independently checking the relayed bytes.
struct ArgusAdminApprovalIndex: Decodable, Sendable {
    let brokerId: String
    let updatedAt: String
    let pending: [ArgusAdminApprovalRequest]

    func validated() throws -> Self {
        guard brokerId.range(of: "^[0-9a-f]{16}$", options: .regularExpression)
                == (brokerId.startIndex..<brokerId.endIndex),
              pending.count <= 10,
              Set(pending.map(\.requestId)).count == pending.count else {
            throw ArgusAdminApprovalReadError.invalidResponse
        }
        for request in pending { try request.validate() }
        return self
    }
}

struct ArgusAdminApprovalRequest: Decodable, Equatable, Sendable {
    let requestId: String
    let scriptPath: String
    let gitCommit: String
    let scriptSha256: String
    let args: [String: ArgusAdminApprovalCanonical.Value]
    let argsCanonical: String
    let argsSha256: String
    let nonce: String
    let reason: String
    let issue: String
    let requestedBy: String
    let requestedAt: String
    let expiresAt: String
    let previous: ArgusAdminApprovalPreviousIdentity?

    func validate() throws {
        let canonical = try ArgusAdminApprovalCanonical.reviewedArguments(
            args, expectedSHA256: argsSha256)
        guard String(data: canonical, encoding: .utf8) == argsCanonical,
              reason.utf8.count <= 300, requestedBy.utf8.count <= 64,
              reason.utf8.allSatisfy({ (32...126).contains($0) }),
              requestedBy.utf8.allSatisfy({ (32...126).contains($0) }),
              issue.range(of: "^ARG-[0-9]{1,5}$", options: .regularExpression)
                == (issue.startIndex..<issue.endIndex) else {
            throw ArgusAdminApprovalReadError.invalidResponse
        }
        _ = try ArgusAdminApprovalCanonical.statement(.init(
            requestID: requestId, decision: "deny", scriptPath: scriptPath,
            gitCommit: gitCommit, scriptSHA256: scriptSha256,
            previousScriptSHA256: previous?.scriptSha256 ?? "FIRST_VERSION",
            argsSHA256: argsSha256, nonce: nonce, expiresAt: expiresAt,
            brokerID: "0123456789abcdef"))
        if let previous {
            guard previous.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression)
                    == (previous.commit.startIndex..<previous.commit.endIndex),
                  previous.scriptSha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression)
                    == (previous.scriptSha256.startIndex..<previous.scriptSha256.endIndex),
                  previous.scriptSha256 != scriptSha256 else {
                throw ArgusAdminApprovalReadError.invalidResponse
            }
        }
    }
}

struct ArgusAdminApprovalPreviousIdentity: Decodable, Equatable, Sendable {
    let commit: String
    let scriptSha256: String
}

struct ArgusAdminApprovalPreviousBytes: Decodable, Sendable {
    let commit: String
    let scriptSha256: String
    let scriptB64: String
}

extension ArgusAdminApprovalCanonical.Value: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { throw DecodingError.typeMismatch(Self.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported approval argument")) }
    }
}

struct ArgusAdminApprovalDetail: Decodable, Sendable {
    let brokerId: String
    let request: ArgusAdminApprovalRequest
    let scriptB64: String
    let previous: ArgusAdminApprovalPreviousBytes?

    func reviewed(against index: ArgusAdminApprovalIndex,
                  selected: ArgusAdminApprovalRequest) throws -> ArgusAdminApprovalReviewedDetail {
        guard brokerId == index.brokerId, request == selected,
              index.pending.contains(selected),
              let bytes = Data(base64Encoded: scriptB64),
              bytes.base64EncodedString() == scriptB64 else {
            throw ArgusAdminApprovalReadError.invalidResponse
        }
        try request.validate()
        let text = try ArgusAdminApprovalCanonical.reviewedScript(
            bytes, expectedSHA256: request.scriptSha256)
        let changes: String?
        if let identity = request.previous {
            guard let previous,
                  previous.commit == identity.commit,
                  previous.scriptSha256 == identity.scriptSha256,
                  let priorBytes = Data(base64Encoded: previous.scriptB64),
                  priorBytes.base64EncodedString() == previous.scriptB64 else {
                throw ArgusAdminApprovalReadError.invalidResponse
            }
            let priorText = try ArgusAdminApprovalCanonical.reviewedScript(
                priorBytes, expectedSHA256: identity.scriptSha256)
            changes = try Self.changes(from: priorText, to: text)
        } else {
            guard previous == nil else { throw ArgusAdminApprovalReadError.invalidResponse }
            changes = nil
        }
        return .init(request: request, scriptText: text, changes: changes)
    }

    private static func changes(from old: String, to new: String) throws -> String {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard oldLines.count <= 4_000, newLines.count <= 4_000 else {
            throw ArgusAdminApprovalReadError.invalidResponse
        }
        let difference = newLines.difference(from: oldLines)
        func visible(_ line: String) -> String {
            line.replacingOccurrences(of: "\r", with: "␍")
        }
        let removed = difference.removals.compactMap { change -> String? in
            guard case .remove(let offset, let line, _) = change else { return nil }
            return "− old line \(offset + 1): \(visible(line))"
        }
        let added = difference.insertions.compactMap { change -> String? in
            guard case .insert(let offset, let line, _) = change else { return nil }
            return "+ new line \(offset + 1): \(visible(line))"
        }
        return (removed + added).isEmpty
            ? "No line changes between the two verified scripts."
            : (removed + added).joined(separator: "\n")
    }
}

struct ArgusAdminApprovalReviewedDetail: Sendable {
    let request: ArgusAdminApprovalRequest
    let scriptText: String
    let changes: String?
}

enum ArgusAdminApprovalReadError: Error {
    case invalidResponse
}

struct ArgusAdminApprovalReadClient: Sendable {
    let gateway: ArgusOperationsClient

    func list() async throws -> ArgusAdminApprovalIndex {
        try await gateway.request("argus.approvals.list", params: [:],
                                  as: ArgusAdminApprovalIndex.self).validated()
    }

    func get(_ selected: ArgusAdminApprovalRequest,
             in index: ArgusAdminApprovalIndex) async throws -> ArgusAdminApprovalReviewedDetail {
        let detail = try await gateway.request("argus.approvals.get",
                                               params: ["request_id": selected.requestId],
                                               as: ArgusAdminApprovalDetail.self)
        return try detail.reviewed(against: index, selected: selected)
    }
}
