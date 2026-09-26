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

    @Test func signedPayloadUsesExactV2StatementAndRawSignature() throws {
        let (index, reviewed, now) = try Self.fixture()
        let key = P256.Signing.PrivateKey()
        let publicBytes = key.publicKey.x963Representation
        let identity = ArgusAdminApprovalSecureKey.identity(for: publicBytes)
        let statement = try ArgusAdminApprovalSecureKey.preparedStatement(
            for: reviewed, in: index, decision: .approve, now: now)
        let signature = try key.signature(for: statement)
        let payload = try ArgusAdminApprovalSecureKey.verifiedDecision(
            for: reviewed, in: index, decision: .approve, statement: statement,
            signature: signature.rawRepresentation, publicKeyX963: publicBytes,
            expectedKeyID: identity.keyID, now: now)
        let relayedStatement = try #require(Data(base64Encoded: payload.statementBase64))
        let relayedSignature = try #require(Data(base64Encoded: payload.signatureBase64))
        #expect(relayedStatement == statement)
        #expect(relayedSignature.count == 64)
        #expect(key.publicKey.isValidSignature(
            try P256.Signing.ECDSASignature(rawRepresentation: relayedSignature),
            for: relayedStatement))
        #expect(Set(payload.relayParameters.keys)
            == Set(["request_id", "key_id", "statement_b64", "sig_b64"]))
        #expect(payload.requestID == reviewed.request.requestId)
        #expect(payload.keyID == identity.keyID)
    }

    @Test func signedPayloadRefusesExpiredReplayedWrongKeyAndInvalidSignature() throws {
        let (index, reviewed, now) = try Self.fixture()
        let key = P256.Signing.PrivateKey()
        let publicBytes = key.publicKey.x963Representation
        let keyID = ArgusAdminApprovalSecureKey.identity(for: publicBytes).keyID
        let statement = try ArgusAdminApprovalSecureKey.preparedStatement(
            for: reviewed, in: index, decision: .approve, now: now)
        let signature = try key.signature(for: statement)
        func payload(_ bytes: Data, _ expectedKey: String, _ decision: ArgusAdminApprovalSecureKey.Decision,
                     _ timestamp: Date) throws -> ArgusAdminApprovalSecureKey.SignedDecision {
            try ArgusAdminApprovalSecureKey.verifiedDecision(
                for: reviewed, in: index, decision: decision, statement: statement,
                signature: bytes, publicKeyX963: publicBytes,
                expectedKeyID: expectedKey, now: timestamp)
        }
        #expect(throws: ArgusAdminApprovalSecureKey.ReviewError.self) {
            try payload(signature.rawRepresentation, keyID, .deny, now)
        }
        let expiry = try #require(ISO8601DateFormatter().date(from: reviewed.request.expiresAt))
        #expect(throws: ArgusAdminApprovalSecureKey.ReviewError.self) {
            try payload(signature.rawRepresentation, keyID, .approve, expiry)
        }
        #expect(throws: ArgusAdminApprovalSecureKey.KeyError.self) {
            try payload(signature.rawRepresentation, String(repeating: "0", count: 16), .approve, now)
        }
        #expect(throws: ArgusAdminApprovalSecureKey.ReviewError.self) {
            try payload(Data(repeating: 0, count: 64), keyID, .approve, now)
        }
        #expect(throws: ArgusAdminApprovalSecureKey.ReviewError.self) {
            try payload(signature.derRepresentation, keyID, .approve, now)
        }
        let otherSignature = try P256.Signing.PrivateKey().signature(for: statement)
        #expect(throws: ArgusAdminApprovalSecureKey.ReviewError.self) {
            try payload(otherSignature.rawRepresentation, keyID, .approve, now)
        }
    }

    @MainActor
    private final class PendingAuthentication {
        var started = false
        var invalidated = false
        var advanced = false
        private var continuation: CheckedContinuation<Bool, Error>?

        func evaluate() async throws -> Bool {
            guard !self.invalidated else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.started = true
            }
        }

        func invalidate() {
            self.invalidated = true
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(throwing: CancellationError())
        }

        func complete() {
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(returning: true)
        }
    }

    @Test func cancellingPendingAuthenticationInvalidatesItBeforeAResponse() async throws {
        let authentication = PendingAuthentication()
        let task = Task { @MainActor in
            let accepted = try await ArgusAdminApprovalSecureKey.evaluateAuthentication({
                try await authentication.evaluate()
            }, invalidate: { authentication.invalidate() })
            authentication.advanced = true
            return accepted
        }
        defer {
            task.cancel()
            authentication.complete()
        }
        for _ in 0..<100 {
            if authentication.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(authentication.started)
        task.cancel()
        for _ in 0..<100 {
            if authentication.invalidated { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(authentication.invalidated)
        // Bound a failing preimage too: a missing invalidation must not leave a
        // suspended fake policy evaluation hanging the native test process.
        authentication.complete()
        do {
            _ = try await task.value
            Issue.record("Cancelled authentication returned an accepted result")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!authentication.advanced)
    }

    @Test func authenticationOnlyRunsForAnActiveTask() async throws {
        let normal = PendingAuthentication()
        let accepted = try await ArgusAdminApprovalSecureKey.evaluateAuthentication({
            normal.started = true
            return true
        }, invalidate: { normal.invalidate() })
        #expect(accepted)
        #expect(normal.started && !normal.invalidated)

        let cancelled = PendingAuthentication()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ArgusAdminApprovalSecureKey.evaluateAuthentication({
                cancelled.started = true
                return true
            }, invalidate: { cancelled.invalidate() })
        }
        do {
            _ = try await task.value
            Issue.record("Already-cancelled task started authentication")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!cancelled.started)
    }
}
