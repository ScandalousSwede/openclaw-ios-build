import Foundation
import Security
import Testing
@testable import OpenClaw

@Suite struct KeychainStoreTests {
    @Test func saveLoadUpdateDeleteRoundTrip() {
        let service = "ai.openclaw.tests.\(UUID().uuidString)"
        let account = "value"

        #expect(KeychainStore.delete(service: service, account: account))
        #expect(KeychainStore.loadString(service: service, account: account) == nil)

        #expect(KeychainStore.saveString("first", service: service, account: account))
        #expect(KeychainStore.loadString(service: service, account: account) == "first")
        let attributesQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var attributesResult: CFTypeRef?
        let attributeStatus = SecItemCopyMatching(
            attributesQuery as CFDictionary,
            &attributesResult)
        #expect(attributeStatus == errSecSuccess)
        let attributes = attributesResult as? [String: Any]
        #expect(
            attributes?[kSecAttrAccessGroup as String] as? String
                == "J76B47MZ6V.ai.openclaw.client")

        #expect(KeychainStore.saveString("second", service: service, account: account))
        #expect(KeychainStore.loadString(service: service, account: account) == "second")

        #expect(KeychainStore.delete(service: service, account: account))
        #expect(KeychainStore.loadString(service: service, account: account) == nil)
    }
}
