import CryptoKit
import Foundation
import LocalAuthentication
import Security

// Local key preparation only. Neither this type nor the read-only approvals UI
// calls the gateway's enroll/decide methods or enables an Approve control.
@MainActor
enum ArgusAdminApprovalSecureKey {
    enum KeyError: Error {
        case faceIDUnavailable
        case keyAlreadyPrepared
        case accessControlUnavailable
        case keyStorageFailed
    }

    enum Decision: String {
        case approve
        case deny
    }

    enum ReviewError: Error {
        case changedReview
        case expired
    }

    struct PublicIdentity: Equatable {
        let keyID: String
        let publicKeyX963Base64: String
        let fingerprint: String
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
