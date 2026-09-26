import CryptoKit
import Foundation
import Testing
@testable import OpenClaw

@MainActor
struct ArgusAdminApprovalSecureKeyTests {
    private static func fixture() throws -> (ArgusAdminApprovalIndex, ArgusAdminApprovalReviewedDetail, Date) {
        let script = "'ok'\n"
        let args: [String: ArgusAdminApprovalCanonical.Value] = [
            "Interface": .string("Ethernet"), "SkipAsSource": .boolean(false),
        ]
        let canonicalArgs = try ArgusAdminApprovalCanonical.arguments(args)
        let request = ArgusAdminApprovalRequest(
            requestId: "11111111-2222-4333-8444-555555555555",
            scriptPath: "scripts/windows/elevated/pc3-nic-config.ps1",
            gitCommit: String(repeating: "a", count: 40),
            scriptSha256: ArgusAdminApprovalCanonical.sha256(Data(script.utf8)),
            args: args, argsCanonical: String(decoding: canonicalArgs, as: UTF8.self),
            argsSha256: ArgusAdminApprovalCanonical.sha256(canonicalArgs),
            nonce: String(repeating: "0", count: 32), reason: "Test fixture only",
            issue: "ARG-431", requestedBy: "isolated-test",
            requestedAt: "2026-09-25T22:00:00Z", expiresAt: "2026-09-26T22:00:00Z",
            previous: nil)
        let index = ArgusAdminApprovalIndex(
            brokerId: "0123456789abcdef", updatedAt: "2026-09-25T22:01:00Z",
            pending: [request])
        let reviewed = ArgusAdminApprovalReviewedDetail(request: request, scriptText: script, changes: nil)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-25T23:00:00Z"))
        return (index, reviewed, now)
    }

    @Test func publicIdentityUsesBrokerKeyIDAndGroupedFingerprint() throws {
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let digest = ArgusAdminApprovalCanonical.sha256(publicKey)
        let identity = ArgusAdminApprovalSecureKey.identity(for: publicKey)
        #expect(identity.keyID == String(digest.prefix(16)))
        #expect(identity.publicKeyX963Base64 == publicKey.base64EncodedString())
        #expect(identity.fingerprint.replacingOccurrences(of: " ", with: "")
            == String(digest.prefix(24)))
        #expect(identity.fingerprint.split(separator: " ").count == 6)
        #expect(identity.fingerprint.split(separator: " ").allSatisfy { $0.count == 4 })
    }

    @Test func decisionStatementUsesExactReviewedVector() throws {
        let (index, reviewed, now) = try Self.fixture()
        let statement = try ArgusAdminApprovalSecureKey.preparedStatement(
            for: reviewed, in: index, decision: .approve, now: now)
        #expect(ArgusAdminApprovalCanonical.sha256(statement)
            == "c67d572554b6b2c457468edd0b99221afe4ede05e3af47f10286092cc91d2d34")
        let denied = try ArgusAdminApprovalSecureKey.preparedStatement(
            for: reviewed, in: index, decision: .deny, now: now)
        #expect(String(decoding: denied, as: UTF8.self).contains("\ndecision:deny\n"))
        #expect(denied != statement)
    }

    @Test func staleChangedOrExpiredReviewCannotBecomeDecisionBytes() throws {
        let (index, reviewed, now) = try Self.fixture()
        let emptyIndex = ArgusAdminApprovalIndex(
            brokerId: index.brokerId, updatedAt: index.updatedAt, pending: [])
        #expect(throws: ArgusAdminApprovalSecureKey.ReviewError.self) {
            try ArgusAdminApprovalSecureKey.preparedStatement(
                for: reviewed, in: emptyIndex, decision: .approve, now: now)
        }
        let changed = ArgusAdminApprovalReviewedDetail(
            request: reviewed.request, scriptText: "'changed'\n", changes: nil)
        #expect(throws: ArgusAdminApprovalCanonical.FormatError.self) {
            try ArgusAdminApprovalSecureKey.preparedStatement(
                for: changed, in: index, decision: .approve, now: now)
        }
        let expiry = try #require(ISO8601DateFormatter().date(from: reviewed.request.expiresAt))
        #expect(throws: ArgusAdminApprovalSecureKey.ReviewError.self) {
            try ArgusAdminApprovalSecureKey.preparedStatement(
                for: reviewed, in: index, decision: .approve, now: expiry)
        }
    }
}
