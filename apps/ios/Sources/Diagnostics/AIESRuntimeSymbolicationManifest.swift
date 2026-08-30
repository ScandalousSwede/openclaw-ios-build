import Foundation

struct AIESRuntimeSymbolicationManifest: Codable, Equatable, Sendable {
    static let schemaName = "argus.openclaw-ios.runtime-symbolication-manifest.v1"
    static let resourceName = "AIESRuntimeSymbolicationManifest"
    static let maximumBytes = 64 * 1024

    enum ExecutableRole: String, Codable, Equatable, Sendable {
        case compiledProduct = "compiled_product"
        case sdkWatchKitStub = "sdk_watchkit_stub"
    }

    enum DSYMRequirement: String, Codable, Equatable, Sendable {
        case requiredCompiledExecutable = "required_compiled_executable"
        case notApplicableSDKWatchKitStub = "not_applicable_sdk_watchkit_stub"
    }

    enum DSYMStatus: String, Codable, Equatable, Sendable {
        case uuidMatchedDuringBuild = "uuid_matched_during_build"
        case notEmitted = "not_emitted"
    }

    struct Executable: Codable, Equatable, Sendable {
        let bundleID: String
        let bundleRelativePath: String
        let executableName: String
        let executableRole: ExecutableRole
        let executableUUIDs: [AIESRuntimeMachOUUIDReader.Slice]
        let dsymRequirement: DSYMRequirement
        let dsymStatus: DSYMStatus
        let dsymUUIDs: [AIESRuntimeMachOUUIDReader.Slice]

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case bundleRelativePath = "bundle_relative_path"
            case executableName = "executable_name"
            case executableRole = "executable_role"
            case executableUUIDs = "executable_uuids"
            case dsymRequirement = "dsym_requirement"
            case dsymStatus = "dsym_status"
            case dsymUUIDs = "dsym_uuids"
        }
    }

    enum Status: String, Codable, Equatable, Sendable {
        case observed = "verified_runtime_and_build_dsym_mapping"
        case manifestUnavailable = "runtime_symbolication_manifest_unavailable"
        case manifestUnreadable = "runtime_symbolication_manifest_unreadable"
        case manifestMalformed = "runtime_symbolication_manifest_malformed"
        case provenanceMismatch = "runtime_symbolication_provenance_mismatch"
        case executableMismatch = "runtime_symbolication_executable_mismatch"
    }

    struct Observation: Equatable, Sendable {
        let status: Status
        let executables: [Executable]
    }

    let schema: String
    let gitSHA: String
    let archiveUUID: String
    let buildNumber: String
    let configuration: String
    let executables: [Executable]

    private enum CodingKeys: String, CodingKey {
        case schema
        case gitSHA = "git_sha"
        case archiveUUID = "archive_uuid"
        case buildNumber = "build_number"
        case configuration
        case executables
    }

    static func read(bundle: Bundle = .main) -> Observation {
        guard let url = bundle.url(forResource: self.resourceName, withExtension: "json") else {
            return Observation(status: .manifestUnavailable, executables: [])
        }
        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= self.maximumBytes
            else {
                return Observation(status: .manifestMalformed, executables: [])
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return Observation(status: .manifestUnreadable, executables: [])
        }
        guard data.count <= self.maximumBytes,
              let manifest = try? JSONDecoder().decode(Self.self, from: data),
              manifest.schema == self.schemaName
        else {
            return Observation(status: .manifestMalformed, executables: [])
        }
        return manifest.validate(bundle: bundle)
    }

    func validate(bundle: Bundle) -> Observation {
        let info = bundle.infoDictionary ?? [:]
        guard self.gitSHA == Self.infoString(info, "OpenClawBuildGitSHA"),
              self.archiveUUID == Self.normalizedUUID(Self.infoString(info, "OpenClawBuildArchiveUUID")),
              self.buildNumber == Self.infoString(info, "CFBundleVersion"),
              self.configuration == Self.infoString(info, "OpenClawBuildConfiguration")
        else {
            return Observation(status: .provenanceMismatch, executables: [])
        }
        let mainBundleID = bundle.bundleIdentifier ?? Self.infoString(info, "CFBundleIdentifier")
        let expectedBundleIDs = Set(
            [mainBundleID]
                + Self.infoStringArray(info, "OpenClawBuildExtensionBundleIDs")
                + Self.infoStringArray(info, "OpenClawBuildWatchBundleIDs"))
        guard expectedBundleIDs.count == 5,
              self.executables.count == 5,
              Set(self.executables.map(\.bundleID)) == expectedBundleIDs,
              Set(self.executables.map(\.bundleRelativePath)).count == self.executables.count,
              self.executables == self.executables.sorted(by: {
                  $0.bundleRelativePath < $1.bundleRelativePath
              })
        else {
            return Observation(status: .manifestMalformed, executables: [])
        }

        for record in self.executables {
            guard let executableURL = Self.executableURL(
                for: record,
                mainBundle: bundle,
                expectedMainBundleID: mainBundleID),
                AIESRuntimeMachOUUIDReader.readExecutable(at: executableURL).slices
                    == record.executableUUIDs,
                !record.executableUUIDs.isEmpty
            else {
                return Observation(status: .executableMismatch, executables: [])
            }
            switch record.executableRole {
            case .compiledProduct:
                guard record.dsymRequirement == .requiredCompiledExecutable,
                      record.dsymStatus == .uuidMatchedDuringBuild,
                      record.dsymUUIDs == record.executableUUIDs
                else {
                    return Observation(status: .manifestMalformed, executables: [])
                }
            case .sdkWatchKitStub:
                guard record.dsymRequirement == .notApplicableSDKWatchKitStub,
                      record.dsymStatus == .notEmitted,
                      record.dsymUUIDs.isEmpty
                else {
                    return Observation(status: .manifestMalformed, executables: [])
                }
            }
        }
        return Observation(status: .observed, executables: self.executables)
    }

    private static func executableURL(
        for record: Executable,
        mainBundle: Bundle,
        expectedMainBundleID: String) -> URL?
    {
        guard self.isSafeRelativePath(record.bundleRelativePath),
              !record.executableName.isEmpty,
              record.executableName.utf8.count <= 128,
              !record.executableName.contains("/")
        else { return nil }
        let bundleURL = record.bundleRelativePath == "."
            ? mainBundle.bundleURL
            : mainBundle.bundleURL.appendingPathComponent(record.bundleRelativePath)
        let normalizedRoot = mainBundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let normalizedBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let isWatchApplication = record.bundleRelativePath.hasPrefix("Watch/")
            && record.bundleRelativePath.hasSuffix(".app")
            && record.bundleRelativePath.split(separator: "/").count == 2
        guard (record.bundleRelativePath == "." || normalizedBundle.hasPrefix(normalizedRoot)),
              (record.executableRole == .sdkWatchKitStub) == isWatchApplication,
              let embeddedBundle = Bundle(url: bundleURL),
              embeddedBundle.bundleIdentifier == record.bundleID,
              embeddedBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
                == record.executableName
        else { return nil }
        if record.executableRole == .sdkWatchKitStub {
            guard embeddedBundle.object(forInfoDictionaryKey: "WKWatchKitApp") as? Bool == true,
                  embeddedBundle.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String
                    == expectedMainBundleID
            else { return nil }
        }
        let executableURL = bundleURL.appendingPathComponent(record.executableName)
        let normalizedExecutable = executableURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard normalizedExecutable.hasPrefix(normalizedBundle) else { return nil }
        return executableURL
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 256,
              !value.hasPrefix("/"),
              !value.contains("\\")
        else { return false }
        if value == "." { return true }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func infoString(_ info: [String: Any], _ key: String) -> String {
        (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func infoStringArray(_ info: [String: Any], _ key: String) -> [String] {
        guard let values = info[key] as? [String] else { return [] }
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedUUID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? ""
    }
}
