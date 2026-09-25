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
            argsSHA256: argsSha256, nonce: nonce, expiresAt: expiresAt,
            brokerID: "0123456789abcdef"))
    }
}

extension ArgusAdminApprovalCanonical.Value: Decodable, Sendable {
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
        return .init(request: request, scriptText: text)
    }
}

struct ArgusAdminApprovalReviewedDetail: Sendable {
    let request: ArgusAdminApprovalRequest
    let scriptText: String
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
