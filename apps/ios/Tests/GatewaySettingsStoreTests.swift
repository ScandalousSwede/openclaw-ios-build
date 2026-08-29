import Foundation
import Testing
@testable import OpenClaw

private struct KeychainEntry: Hashable {
    let service: String
    let account: String
}

private let gatewayService = "ai.openclaw.gateway"
private let nodeService = "ai.openclaw.node"
private let talkService = "ai.openclaw.talk"
private let instanceIdEntry = KeychainEntry(service: nodeService, account: "instanceId")
private let preferredGatewayEntry = KeychainEntry(service: gatewayService, account: "preferredStableID")
private let lastGatewayEntry = KeychainEntry(service: gatewayService, account: "lastDiscoveredStableID")
private let talkAcmeProviderEntry = KeychainEntry(service: talkService, account: "provider.apiKey.acme")
private let bootstrapDefaultsKeys = [
    "node.instanceId",
    "gateway.preferredStableID",
    "gateway.lastDiscoveredStableID",
]
private let bootstrapKeychainEntries = [instanceIdEntry, preferredGatewayEntry, lastGatewayEntry]
private let lastGatewayDefaultsKeys = [
    "gateway.last.kind",
    "gateway.last.host",
    "gateway.last.port",
    "gateway.last.tls",
    "gateway.last.stableID",
]
private let lastGatewayKeychainEntry = KeychainEntry(service: gatewayService, account: "lastConnection")

private func snapshotDefaults(_ keys: [String]) -> [String: Any?] {
    let defaults = UserDefaults.standard
    var snapshot: [String: Any?] = [:]
    for key in keys {
        snapshot[key] = defaults.object(forKey: key)
    }
    return snapshot
}

private func applyDefaults(_ values: [String: Any?]) {
    let defaults = UserDefaults.standard
    for (key, value) in values {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

private func restoreDefaults(_ snapshot: [String: Any?]) {
    applyDefaults(snapshot)
}

private func snapshotKeychain(_ entries: [KeychainEntry]) -> [KeychainEntry: String?] {
    var snapshot: [KeychainEntry: String?] = [:]
    for entry in entries {
        snapshot[entry] = KeychainStore.loadString(service: entry.service, account: entry.account)
    }
    return snapshot
}

private func applyKeychain(_ values: [KeychainEntry: String?]) {
    for (entry, value) in values {
        if let value {
            _ = KeychainStore.saveString(value, service: entry.service, account: entry.account)
        } else {
            _ = KeychainStore.delete(service: entry.service, account: entry.account)
        }
    }
}

private func restoreKeychain(_ snapshot: [KeychainEntry: String?]) {
    applyKeychain(snapshot)
}

private func withBootstrapSnapshots(_ body: () -> Void) {
    let defaultsSnapshot = snapshotDefaults(bootstrapDefaultsKeys)
    let keychainSnapshot = snapshotKeychain(bootstrapKeychainEntries)
    defer {
        restoreDefaults(defaultsSnapshot)
        restoreKeychain(keychainSnapshot)
    }
    body()
}

private func withLastGatewaySnapshot(_ body: () -> Void) {
    let defaultsSnapshot = snapshotDefaults(lastGatewayDefaultsKeys)
    let keychainSnapshot = snapshotKeychain([lastGatewayKeychainEntry])
    defer {
        restoreDefaults(defaultsSnapshot)
        restoreKeychain(keychainSnapshot)
    }
    body()
}

@Suite(.serialized) struct GatewaySettingsStoreTests {
    // The test bundle is hosted by the live app. Keep this synthetic migration
    // transaction on MainActor so the host's MainActor gateway lifecycle cannot
    // observe a partially seeded set of legacy UserDefaults keys.
    @Test @MainActor func sameIdentityUpdateReadsHistoricalGatewayStateWithoutRewrite() throws {
        let instanceID = "continuity-node"
        let stableGatewayID = "continuity-gateway"
        let defaultsKeys = bootstrapDefaultsKeys + lastGatewayDefaultsKeys + [
            "gateway.clientIdOverride.\(stableGatewayID)",
            "gateway.selectedAgentId.\(stableGatewayID)",
        ]
        let credentialEntries = bootstrapKeychainEntries + [
            lastGatewayKeychainEntry,
            KeychainEntry(service: gatewayService, account: "gateway-token.\(instanceID)"),
            KeychainEntry(service: gatewayService, account: "gateway-bootstrap-token.\(instanceID)"),
            KeychainEntry(service: gatewayService, account: "gateway-password.\(instanceID)"),
        ]
        let defaultsSnapshot = snapshotDefaults(defaultsKeys)
        let keychainSnapshot = snapshotKeychain(credentialEntries)
        defer {
            restoreDefaults(defaultsSnapshot)
            restoreKeychain(keychainSnapshot)
        }

        // Seed the historical persistence contract directly rather than using
        // current writers, then let current code perform its supported migration.
        applyKeychain([
            instanceIdEntry: instanceID,
            preferredGatewayEntry: stableGatewayID,
            lastGatewayEntry: "continuity-last-gateway",
            lastGatewayKeychainEntry: nil,
            KeychainEntry(service: gatewayService, account: "gateway-token.\(instanceID)"):
                "paired-gateway-token",
            KeychainEntry(service: gatewayService, account: "gateway-bootstrap-token.\(instanceID)"):
                "paired-bootstrap-token",
            KeychainEntry(service: gatewayService, account: "gateway-password.\(instanceID)"):
                "paired-gateway-password",
        ])
        applyDefaults([
            "node.instanceId": instanceID,
            "gateway.preferredStableID": stableGatewayID,
            "gateway.lastDiscoveredStableID": "continuity-last-gateway",
            "gateway.last.kind": "manual",
            "gateway.last.host": "gateway.continuity.invalid",
            "gateway.last.port": 443,
            "gateway.last.tls": true,
            "gateway.last.stableID": stableGatewayID,
            "gateway.clientIdOverride.\(stableGatewayID)": "preserved-client-id",
            "gateway.selectedAgentId.\(stableGatewayID)": "preserved-agent",
        ])

        GatewaySettingsStore.bootstrapPersistence()

        #expect(GatewaySettingsStore.currentInstanceID() == instanceID)
        #expect(GatewaySettingsStore.loadStableInstanceID() == instanceID)
        #expect(GatewaySettingsStore.loadPreferredGatewayStableID() == stableGatewayID)
        #expect(GatewaySettingsStore.loadLastDiscoveredGatewayStableID() == "continuity-last-gateway")
        #expect(GatewaySettingsStore.loadGatewayToken(instanceId: instanceID) == "paired-gateway-token")
        #expect(
            GatewaySettingsStore.loadGatewayBootstrapToken(instanceId: instanceID)
                == "paired-bootstrap-token")
        #expect(
            GatewaySettingsStore.loadGatewayPassword(instanceId: instanceID)
                == "paired-gateway-password")
        #expect(
            GatewaySettingsStore.loadLastGatewayConnection()
                == .manual(
                    host: "gateway.continuity.invalid",
                    port: 443,
                    useTLS: true,
                    stableID: stableGatewayID))
        #expect(
            GatewaySettingsStore.loadGatewayClientIdOverride(stableID: stableGatewayID)
                == "preserved-client-id")
        #expect(
            GatewaySettingsStore.loadGatewaySelectedAgentId(stableID: stableGatewayID)
                == "preserved-agent")
    }

    @Test func productionDirectRegistrationUsesOldTopicAndKeepsPairing() async throws {
        let instanceID = "continuity-node"
        let gatewayTokenEntry = KeychainEntry(
            service: gatewayService,
            account: "gateway-token.\(instanceID)")
        let bootstrapTokenEntry = KeychainEntry(
            service: gatewayService,
            account: "gateway-bootstrap-token.\(instanceID)")
        let defaultsSnapshot = snapshotDefaults(["node.instanceId"])
        let keychainSnapshot = snapshotKeychain([
            instanceIdEntry,
            gatewayTokenEntry,
            bootstrapTokenEntry,
        ])
        defer {
            restoreDefaults(defaultsSnapshot)
            restoreKeychain(keychainSnapshot)
        }

        applyDefaults(["node.instanceId": instanceID])
        applyKeychain([
            instanceIdEntry: instanceID,
            gatewayTokenEntry: "paired-gateway-token",
            bootstrapTokenEntry: "paired-bootstrap-token",
        ])

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = tempDirectory.appendingPathComponent("Continuity.bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "ai.openclaw.client",
            "CFBundleName": "OpenClaw Continuity Test",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "2026.6.2",
            "CFBundleVersion": "73",
            "OpenClawPushTransport": "direct",
            "OpenClawPushDistribution": "local",
            "OpenClawPushAPNsEnvironment": "production",
            "OpenClawPushRelayBaseURL": "",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0)
        try data.write(to: bundleURL.appendingPathComponent("Info.plist"), options: .atomic)
        let bundle = try #require(Bundle(url: bundleURL))
        let manager = PushRegistrationManager(buildConfig: PushBuildConfig(bundle: bundle))

        let payload = try await manager.makeGatewayRegistrationPayload(
            apnsTokenHex: "0123456789abcdef0123456789abcdef",
            topic: "ai.openclaw.client",
            gatewayIdentity: nil)
        let payloadData = try #require(payload.data(using: .utf8))
        let decoded = try #require(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any])

        #expect(decoded["transport"] as? String == "direct")
        #expect(decoded["token"] as? String == "0123456789abcdef0123456789abcdef")
        #expect(decoded["topic"] as? String == "ai.openclaw.client")
        #expect(decoded["environment"] as? String == "production")
        #expect(GatewaySettingsStore.loadStableInstanceID() == instanceID)
        #expect(GatewaySettingsStore.loadGatewayToken(instanceId: instanceID) == "paired-gateway-token")
        #expect(
            GatewaySettingsStore.loadGatewayBootstrapToken(instanceId: instanceID)
                == "paired-bootstrap-token")
    }

    @Test func bootstrapCopiesDefaultsToKeychainWhenMissing() {
        withBootstrapSnapshots {
            applyDefaults([
                "node.instanceId": "node-test",
                "gateway.preferredStableID": "preferred-test",
                "gateway.lastDiscoveredStableID": "last-test",
            ])
            applyKeychain([
                instanceIdEntry: nil,
                preferredGatewayEntry: nil,
                lastGatewayEntry: nil,
            ])

            GatewaySettingsStore.bootstrapPersistence()

            #expect(KeychainStore.loadString(service: nodeService, account: "instanceId") == "node-test")
            #expect(KeychainStore.loadString(service: gatewayService, account: "preferredStableID") == "preferred-test")
            #expect(KeychainStore.loadString(service: gatewayService, account: "lastDiscoveredStableID") == "last-test")
        }
    }

    @Test func bootstrapCopiesKeychainToDefaultsWhenMissing() {
        withBootstrapSnapshots {
            applyDefaults([
                "node.instanceId": nil,
                "gateway.preferredStableID": nil,
                "gateway.lastDiscoveredStableID": nil,
            ])
            applyKeychain([
                instanceIdEntry: "node-from-keychain",
                preferredGatewayEntry: "preferred-from-keychain",
                lastGatewayEntry: "last-from-keychain",
            ])

            GatewaySettingsStore.bootstrapPersistence()

            let defaults = UserDefaults.standard
            #expect(defaults.string(forKey: "node.instanceId") == "node-from-keychain")
            #expect(defaults.string(forKey: "gateway.preferredStableID") == "preferred-from-keychain")
            #expect(defaults.string(forKey: "gateway.lastDiscoveredStableID") == "last-from-keychain")
        }
    }

    @Test func lastGateway_manualRoundTrip() {
        withLastGatewaySnapshot {
            GatewaySettingsStore.saveLastGatewayConnectionManual(
                host: "example.com",
                port: 443,
                useTLS: true,
                stableID: "manual|example.com|443")

            let loaded = GatewaySettingsStore.loadLastGatewayConnection()
            #expect(loaded == .manual(host: "example.com", port: 443, useTLS: true, stableID: "manual|example.com|443"))
        }
    }

    @Test func lastGateway_discoveredOverwritesManual() {
        withLastGatewaySnapshot {
            GatewaySettingsStore.saveLastGatewayConnectionManual(
                host: "10.0.0.99",
                port: 18789,
                useTLS: true,
                stableID: "manual|10.0.0.99|18789")

            GatewaySettingsStore.saveLastGatewayConnectionDiscovered(stableID: "gw|abc", useTLS: true)

            #expect(GatewaySettingsStore.loadLastGatewayConnection() == .discovered(stableID: "gw|abc", useTLS: true))
        }
    }

    // Like the continuity fixture above, this seeds the live host's legacy
    // multi-key defaults contract. Keep the synchronous seed/migrate/assert
    // transaction on MainActor so app startup cannot consume a partial seed.
    @Test @MainActor func lastGateway_migratesFromUserDefaults() {
        withLastGatewaySnapshot {
            // Clear Keychain entry and plant legacy UserDefaults values.
            applyKeychain([lastGatewayKeychainEntry: nil])
            applyDefaults([
                "gateway.last.kind": nil,
                "gateway.last.host": "example.org",
                "gateway.last.port": 18789,
                "gateway.last.tls": false,
                "gateway.last.stableID": "manual|example.org|18789",
            ])

            let loaded = GatewaySettingsStore.loadLastGatewayConnection()
            #expect(loaded == .manual(host: "example.org", port: 18789, useTLS: false, stableID: "manual|example.org|18789"))

            // Legacy keys should be cleaned up after migration.
            let defaults = UserDefaults.standard
            #expect(defaults.object(forKey: "gateway.last.stableID") == nil)
            #expect(defaults.object(forKey: "gateway.last.host") == nil)
        }
    }

    @Test func talkProviderApiKey_genericRoundTrip() {
        let keychainSnapshot = snapshotKeychain([talkAcmeProviderEntry])
        defer { restoreKeychain(keychainSnapshot) }

        _ = KeychainStore.delete(service: talkService, account: talkAcmeProviderEntry.account)

        GatewaySettingsStore.saveTalkProviderApiKey("acme-key", provider: "acme")
        #expect(GatewaySettingsStore.loadTalkProviderApiKey(provider: "acme") == "acme-key")

        GatewaySettingsStore.saveTalkProviderApiKey(nil, provider: "acme")
        #expect(GatewaySettingsStore.loadTalkProviderApiKey(provider: "acme") == nil)
    }
}
