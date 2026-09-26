import CryptoKit
import Foundation
import Testing
@testable import OpenClaw

@MainActor
struct ArgusAdminApprovalSecureKeyTests {
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
}
