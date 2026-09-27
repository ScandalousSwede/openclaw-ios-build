import CryptoKit
import Foundation
import LocalAuthentication
import Security

// Source-only key/signature preparation. There are no UI call sites or gateway
// enroll/decide calls; the broker hold still prevents activation.
@MainActor
enum ArgusAdminApprovalSecureKey {
    enum KeyError: Error {
        case faceIDUnavailable
        case keyAlreadyPrepared
        case accessControlUnavailable
        case keyStorageFailed
        case keyNotPrepared
        case keyIdentityChanged
    }

    enum Decision: String {
        case approve
        case deny
    }

    enum ReviewError: Error {
        case changedReview
        case expired
        case invalidSignature
    }

    struct PublicIdentity: Equatable {
        let keyID: String
        let publicKeyX963Base64: String
        let fingerprint: String
    }

    struct SignedDecision: Equatable {
        let requestID: String
        let keyID: String
        let statementBase64: String
        let signatureBase64: String

        // Relay transport only. This payload is not a broker acceptance receipt.
        var relayParameters: [String: String] {
            ["request_id": requestID, "key_id": keyID,
             "statement_b64": statementBase64, "sig_b64": signatureBase64]
        }
    }

    private static let service = "ai.openclaw.admin-approval-key"
    private static let account = "secure-enclave-p256-v1"

    // Build only from the exact detail that passed list/get byte verification.
    // Recheck the displayed bytes and expiry immediately before a future Face ID
    // prompt; stale navigation state must not become a signed decision.
    static func preparedStatement(
        for reviewed: ArgusAdminApprovalReviewedDetail,
        in index: ArgusAdminApprovalIndex,
        decision: Decision,
        now: Date) throws -> Data
    {
        _ = try index.validated()
        let request = reviewed.request
        guard index.pending.contains(request),
              (request.previous == nil) == (reviewed.changes == nil) else {
            throw ReviewError.changedReview
        }
        _ = try ArgusAdminApprovalCanonical.reviewedScript(
            Data(reviewed.scriptText.utf8), expectedSHA256: request.scriptSha256)
        _ = try ArgusAdminApprovalCanonical.reviewedArguments(
            request.args, expectedSHA256: request.argsSha256)
        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: request.expiresAt), now < expiry else {
            throw ReviewError.expired
        }
        return try ArgusAdminApprovalCanonical.statement(.init(
            requestID: request.requestId, decision: decision.rawValue,
            scriptPath: request.scriptPath, gitCommit: request.gitCommit,
            scriptSHA256: request.scriptSha256,
            previousScriptSHA256: request.previous?.scriptSha256 ?? "FIRST_VERSION",
            argsSHA256: request.argsSha256, nonce: request.nonce,
            expiresAt: request.expiresAt, brokerID: index.brokerId))
    }

    // This only prepares a local, device-bound key. Trust still requires Ethan
    // to compare its fingerprint and confirm enrolment on the broker's TOTP page.
    static func prepareLocalKey() throws -> PublicIdentity {
        guard SecureEnclave.isAvailable else { throw KeyError.faceIDUnavailable }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                        error: &policyError),
              context.biometryType == .faceID else {
            throw KeyError.faceIDUnavailable
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        guard existing != errSecSuccess else {
            throw KeyError.keyAlreadyPrepared
        }
        guard existing == errSecItemNotFound else { throw KeyError.keyStorageFailed }

        var controlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet], &controlError) else {
            throw KeyError.accessControlUnavailable
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
        let identity = identity(for: key.publicKey.x963Representation)
        var insert = query
        insert[kSecValueData as String] = key.dataRepresentation
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw KeyError.keyStorageFailed
        }
        return identity
    }

    // The future enrolment UI must retain the locally displayed key ID. Never
    // silently prepare or replace a key because an existing key cannot be used.
    static func signReviewedDecision(
        for reviewed: ArgusAdminApprovalReviewedDetail,
        in index: ArgusAdminApprovalIndex,
        decision: Decision,
        expectedKeyID: String) async throws -> SignedDecision
    {
        try Task.checkCancellation()
        let statement = try preparedStatement(
            for: reviewed, in: index, decision: decision, now: Date())
        guard SecureEnclave.isAvailable else { throw KeyError.faceIDUnavailable }
        let context = LAContext()
        defer { context.invalidate() }
        context.localizedFallbackTitle = ""
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                        error: &policyError),
              context.biometryType == .faceID else {
            throw KeyError.faceIDUnavailable
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: storedKeyRepresentation(), authenticationContext: context)
        guard identity(for: key.publicKey.x963Representation).keyID == expectedKeyID else {
            throw KeyError.keyIdentityChanged
        }
        let authenticated = try await evaluateAuthentication({
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Confirm \(decision.rawValue) for admin request \(reviewed.request.issue).")
        }, invalidate: { context.invalidate() })
        guard authenticated else { throw KeyError.faceIDUnavailable }
        try Task.checkCancellation()
        // Face ID may take long enough for the request to expire. Refuse before
        // signing, then recheck again before exposing the transport payload.
        _ = try preparedStatement(for: reviewed, in: index, decision: decision, now: Date())
        let signature = try key.signature(for: statement).rawRepresentation
        try Task.checkCancellation()
        return try verifiedDecision(
            for: reviewed, in: index, decision: decision, statement: statement,
            signature: signature, publicKeyX963: key.publicKey.x963Representation,
            expectedKeyID: expectedKeyID, now: Date())
    }

    // Keep LAContext access on MainActor even when cancellation is delivered
    // from another executor. Invalidating the context terminates its pending prompt.
    @MainActor
    private final class AuthenticationCancellation {
        let invalidate: @MainActor () -> Void

        init(invalidate: @escaping @MainActor () -> Void) {
            self.invalidate = invalidate
        }
    }

    static func evaluateAuthentication(
        _ evaluate: @MainActor () async throws -> Bool,
        invalidate: @escaping @MainActor () -> Void) async throws -> Bool
    {
        try Task.checkCancellation()
        let cancellation = AuthenticationCancellation(invalidate: invalidate)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let authenticated = try await evaluate()
                try Task.checkCancellation()
                return authenticated
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task { @MainActor in cancellation.invalidate() }
        }
    }

    // Kept pure so the exact V2 bytes, raw r||s encoding and post-authentication
    // expiry can be tested without creating a device key or prompting Face ID.
    static func verifiedDecision(
        for reviewed: ArgusAdminApprovalReviewedDetail,
        in index: ArgusAdminApprovalIndex,
        decision: Decision,
        statement: Data,
        signature: Data,
        publicKeyX963: Data,
        expectedKeyID: String,
        now: Date) throws -> SignedDecision
    {
        let expectedStatement = try preparedStatement(
            for: reviewed, in: index, decision: decision, now: now)
        guard statement == expectedStatement else { throw ReviewError.changedReview }
        guard publicKeyX963.count == 65, publicKeyX963.first == 4,
              signature.count == 64,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
              let parsedSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              publicKey.isValidSignature(parsedSignature, for: statement) else {
            throw ReviewError.invalidSignature
        }
        let publicIdentity = identity(for: publicKeyX963)
        guard publicIdentity.keyID == expectedKeyID else { throw KeyError.keyIdentityChanged }
        return SignedDecision(
            requestID: reviewed.request.requestId, keyID: publicIdentity.keyID,
            statementBase64: statement.base64EncodedString(),
            signatureBase64: signature.base64EncodedString())
    }

    private static func storedKeyRepresentation() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeyError.keyNotPrepared }
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            throw KeyError.keyStorageFailed
        }
        return data
    }

    static func identity(for x963PublicKey: Data) -> PublicIdentity {
        let digest = ArgusAdminApprovalCanonical.sha256(x963PublicKey)
        let prefix = String(digest.prefix(24))
        let groups = stride(from: 0, to: 24, by: 4).map { offset in
            let start = prefix.index(prefix.startIndex, offsetBy: offset)
            let end = prefix.index(start, offsetBy: 4)
            return String(prefix[start..<end])
        }
        return PublicIdentity(
            keyID: String(digest.prefix(16)),
            publicKeyX963Base64: x963PublicKey.base64EncodedString(),
            fingerprint: groups.joined(separator: " "))
    }
}
