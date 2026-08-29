import Foundation

public struct DeviceAuthEntry: Codable, Sendable {
    public let token: String
    public let role: String
    public let scopes: [String]
    public let updatedAtMs: Int

    public init(token: String, role: String, scopes: [String], updatedAtMs: Int) {
        self.token = token
        self.role = role
        self.scopes = scopes
        self.updatedAtMs = updatedAtMs
    }
}

struct DeviceAuthTokenWrite: Sendable {
    let role: String
    let token: String
    let scopes: [String]
}

enum DeviceAuthStoreWriteError: Error {
    case emptyDeviceID
    case emptyBatch
    case emptyRole
    case emptyToken(role: String)
    case duplicateRole(String)
    case temporaryFileCreationFailed
    case securePermissionsNotApplied
    case verificationFailed
}

private struct DeviceAuthStoreFile: Codable {
    var version: Int
    var deviceId: String
    var tokens: [String: DeviceAuthEntry]
}

public enum DeviceAuthStore {
    private static let fileName = "device-auth.json"
    private static let storeLock = NSLock()

    public static func loadToken(deviceId: String, role: String) -> DeviceAuthEntry? {
        self.withStoreLock {
            guard let store = self.readStoreUnlocked(), store.deviceId == deviceId else { return nil }
            let role = self.normalizeRole(role)
            return store.tokens[role]
        }
    }

    public static func storeToken(
        deviceId: String,
        role: String,
        token: String,
        scopes: [String] = []) -> DeviceAuthEntry
    {
        self.withStoreLock {
            let normalizedRole = self.normalizeRole(role)
            var next = self.readStoreUnlocked()
            if next?.deviceId != deviceId {
                next = DeviceAuthStoreFile(version: 1, deviceId: deviceId, tokens: [:])
            }
            let entry = DeviceAuthEntry(
                token: token,
                role: normalizedRole,
                scopes: normalizeScopes(scopes),
                updatedAtMs: Int(Date().timeIntervalSince1970 * 1000))
            if next == nil {
                next = DeviceAuthStoreFile(version: 1, deviceId: deviceId, tokens: [:])
            }
            next?.tokens[normalizedRole] = entry
            if let store = next {
                try? self.writeStoreUnlocked(store)
            }
            return entry
        }
    }

    /// Persists one complete issuance result with a single atomic file replacement.
    /// Input validation finishes before the existing store is changed, so a rejected
    /// batch cannot leave only one role updated.
    static func storeTokensAtomically(
        deviceId: String,
        writes: [DeviceAuthTokenWrite]) throws -> [String: DeviceAuthEntry]
    {
        try self.withStoreLock {
            let normalizedDeviceID = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedDeviceID.isEmpty else { throw DeviceAuthStoreWriteError.emptyDeviceID }
            guard !writes.isEmpty else { throw DeviceAuthStoreWriteError.emptyBatch }

            let updatedAtMs = Int(Date().timeIntervalSince1970 * 1000)
            var entries: [String: DeviceAuthEntry] = [:]
            entries.reserveCapacity(writes.count)

            for write in writes {
                let role = self.normalizeRole(write.role)
                guard !role.isEmpty else { throw DeviceAuthStoreWriteError.emptyRole }
                let token = write.token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { throw DeviceAuthStoreWriteError.emptyToken(role: role) }
                guard entries[role] == nil else { throw DeviceAuthStoreWriteError.duplicateRole(role) }
                entries[role] = DeviceAuthEntry(
                    token: token,
                    role: role,
                    scopes: self.normalizeScopes(write.scopes),
                    updatedAtMs: updatedAtMs)
            }

            var next = self.readStoreUnlocked()
            if next?.deviceId != normalizedDeviceID {
                next = DeviceAuthStoreFile(version: 1, deviceId: normalizedDeviceID, tokens: [:])
            }
            if next == nil {
                next = DeviceAuthStoreFile(version: 1, deviceId: normalizedDeviceID, tokens: [:])
            }
            for (role, entry) in entries {
                next?.tokens[role] = entry
            }
            if let store = next {
                try self.writeStoreUnlocked(store)
            }
            guard let persisted = self.readStoreUnlocked(),
                  persisted.deviceId == normalizedDeviceID,
                  entries.allSatisfy({ role, entry in
                      guard let observed = persisted.tokens[role] else { return false }
                      return observed.token == entry.token &&
                          observed.role == entry.role &&
                          observed.scopes == entry.scopes &&
                          observed.updatedAtMs == entry.updatedAtMs
                  })
            else { throw DeviceAuthStoreWriteError.verificationFailed }
            return entries
        }
    }

    public static func clearToken(deviceId: String, role: String) {
        self.withStoreLock {
            guard var store = self.readStoreUnlocked(), store.deviceId == deviceId else { return }
            let normalizedRole = self.normalizeRole(role)
            guard store.tokens[normalizedRole] != nil else { return }
            store.tokens.removeValue(forKey: normalizedRole)
            try? self.writeStoreUnlocked(store)
        }
    }

    private static func normalizeRole(_ role: String) -> String {
        role.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeScopes(_ scopes: [String]) -> [String] {
        let trimmed = scopes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(trimmed)).sorted()
    }

    private static func fileURL() -> URL {
        DeviceIdentityPaths.stateDirURL()
            .appendingPathComponent("identity", isDirectory: true)
            .appendingPathComponent(self.fileName, isDirectory: false)
    }

    private static func withStoreLock<T>(_ operation: () throws -> T) rethrows -> T {
        self.storeLock.lock()
        defer { self.storeLock.unlock() }
        return try operation()
    }

    private static func readStoreUnlocked() -> DeviceAuthStoreFile? {
        let url = self.fileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(DeviceAuthStoreFile.self, from: data) else {
            return nil
        }
        guard decoded.version == 1 else { return nil }
        return decoded
    }

    private static func writeStoreUnlocked(_ store: DeviceAuthStoreFile) throws {
        let url = self.fileURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(store)
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(self.fileName).\(UUID().uuidString).tmp", isDirectory: false)
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600])
        else { throw DeviceAuthStoreWriteError.temporaryFileCreationFailed }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try self.requireSecurePermissions(at: temporaryURL)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        try self.requireSecurePermissions(at: url)
    }

    private static func requireSecurePermissions(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600
        else { throw DeviceAuthStoreWriteError.securePermissionsNotApplied }
    }
}
