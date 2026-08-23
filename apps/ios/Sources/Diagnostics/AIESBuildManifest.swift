import Foundation

struct AIESBuildManifest: Codable, Equatable, Sendable {
    static let schemaName = "argus.openclaw-ios.build-manifest.v1"

    let schema: String
    let gitSHA: String
    let gitBranch: String
    let version: String
    let buildNumber: String
    let buildTimestamp: String
    let xcodeVersion: String
    let swiftVersion: String
    let sdkVersion: String
    let mainBundleID: String
    let extensionBundleIDs: [String]
    let watchBundleIDsIfPresent: [String]
    let archiveUUID: String?
    let dsymUUIDs: [String]
    let configuration: String
    let apsEnvironmentIfSigned: String?

    static func current(bundle: Bundle = .main) -> AIESBuildManifest {
        self.from(
            infoDictionary: bundle.infoDictionary ?? [:],
            bundleIdentifier: bundle.bundleIdentifier)
    }

    static func from(
        infoDictionary: [String: Any],
        bundleIdentifier: String?) -> AIESBuildManifest
    {
        let archiveUUID = self.optionalValue(infoDictionary, key: "OpenClawBuildArchiveUUID")
            .flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        let apsEnvironment = self.optionalValue(infoDictionary, key: "OpenClawBuildAPSEnvironmentIfSigned")
            .flatMap { ["development", "production"].contains($0) ? $0 : nil }
        return AIESBuildManifest(
            schema: self.schemaName,
            gitSHA: self.value(infoDictionary, key: "OpenClawBuildGitSHA"),
            gitBranch: self.value(infoDictionary, key: "OpenClawBuildGitBranch"),
            version: self.value(infoDictionary, key: "CFBundleShortVersionString"),
            buildNumber: self.value(infoDictionary, key: "CFBundleVersion"),
            buildTimestamp: self.value(infoDictionary, key: "OpenClawBuildTimestamp"),
            xcodeVersion: self.value(infoDictionary, key: "OpenClawBuildXcodeVersion"),
            swiftVersion: self.value(infoDictionary, key: "OpenClawBuildSwiftVersion"),
            sdkVersion: self.value(infoDictionary, key: "OpenClawBuildSDKVersion"),
            mainBundleID: bundleIdentifier ?? self.value(infoDictionary, key: "CFBundleIdentifier"),
            extensionBundleIDs: self.stringArray(infoDictionary, key: "OpenClawBuildExtensionBundleIDs"),
            watchBundleIDsIfPresent: self.stringArray(infoDictionary, key: "OpenClawBuildWatchBundleIDs"),
            archiveUUID: archiveUUID,
            dsymUUIDs: [],
            configuration: self.value(infoDictionary, key: "OpenClawBuildConfiguration"),
            apsEnvironmentIfSigned: apsEnvironment)
    }

    private static func value(_ info: [String: Any], key: String) -> String {
        self.optionalValue(info, key: key) ?? "unknown"
    }

    private static func optionalValue(_ info: [String: Any], key: String) -> String? {
        guard let value = info[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringArray(_ info: [String: Any], key: String) -> [String] {
        guard let values = info[key] as? [String] else { return [] }
        return Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case gitSHA = "git_sha"
        case gitBranch = "git_branch"
        case version
        case buildNumber = "build_number"
        case buildTimestamp = "build_timestamp"
        case xcodeVersion = "xcode_version"
        case swiftVersion = "swift_version"
        case sdkVersion = "sdk_version"
        case mainBundleID = "main_bundle_id"
        case extensionBundleIDs = "extension_bundle_ids"
        case watchBundleIDsIfPresent = "watch_bundle_ids_if_present"
        case archiveUUID = "archive_uuid"
        case dsymUUIDs = "dsym_uuids"
        case configuration
        case apsEnvironmentIfSigned = "aps_environment_if_signed"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schema, forKey: .schema)
        try container.encode(self.gitSHA, forKey: .gitSHA)
        try container.encode(self.gitBranch, forKey: .gitBranch)
        try container.encode(self.version, forKey: .version)
        try container.encode(self.buildNumber, forKey: .buildNumber)
        try container.encode(self.buildTimestamp, forKey: .buildTimestamp)
        try container.encode(self.xcodeVersion, forKey: .xcodeVersion)
        try container.encode(self.swiftVersion, forKey: .swiftVersion)
        try container.encode(self.sdkVersion, forKey: .sdkVersion)
        try container.encode(self.mainBundleID, forKey: .mainBundleID)
        try container.encode(self.extensionBundleIDs, forKey: .extensionBundleIDs)
        try container.encode(self.watchBundleIDsIfPresent, forKey: .watchBundleIDsIfPresent)
        if let archiveUUID {
            try container.encode(archiveUUID, forKey: .archiveUUID)
        } else {
            try container.encodeNil(forKey: .archiveUUID)
        }
        try container.encode(self.dsymUUIDs, forKey: .dsymUUIDs)
        try container.encode(self.configuration, forKey: .configuration)
        if let apsEnvironmentIfSigned {
            try container.encode(apsEnvironmentIfSigned, forKey: .apsEnvironmentIfSigned)
        } else {
            try container.encodeNil(forKey: .apsEnvironmentIfSigned)
        }
    }
}
