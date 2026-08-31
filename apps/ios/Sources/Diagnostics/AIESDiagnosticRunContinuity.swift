import Foundation
import OpenClawKit
import os

enum AIESDiagnosticRunContinuity {
    static let schemaName = "argus.openclaw-ios.diagnostic-run-marker.v2"
    static let legacySchemaName = "argus.openclaw-ios.diagnostic-run-marker.v1"
    static let maximumMarkerBytes = 2048

    enum PriorState: String, Codable, Equatable, Sendable {
        // Retained for decoding already-exported v1 diagnostic records. New markers use one of
        // the three identity-aware states below; none of them is itself evidence of a crash.
        case previousRunUnclosed = "previous_run_unclosed"
        case previousRunUnclosedSameBuild = "previous_run_unclosed_same_build"
        case previousRunUnclosedBuildTransition = "previous_run_unclosed_build_transition"
        case previousRunUnclosedIdentityUnknown = "previous_run_unclosed_identity_unknown"
        case priorBackgroundBoundaryObserved = "prior_background_boundary_observed"
        case orderlyCloseObserved = "orderly_close_observed"
        case noPriorRun = "no_prior_run"
        case priorStateCorrupt = "prior_state_corrupt"
        case priorStateUnknown = "prior_state_unknown"
    }

    enum Boundary: String, Codable, Equatable, Sendable {
        case running
        case background
        case orderlyClose = "orderly_close"
    }

    struct BuildIdentity: Codable, Equatable, Sendable {
        let buildNumber: String
        let sourceSHA: String
        let mainExecutableUUID: String

        init?(buildNumber: String, sourceSHA: String, mainExecutableUUID: String) {
            let normalizedBuild = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSource = sourceSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedUUID = mainExecutableUUID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard Self.isBuildNumber(normalizedBuild),
                  Self.isSourceSHA(normalizedSource),
                  Self.isCanonicalUUID(normalizedUUID)
            else { return nil }
            self.buildNumber = normalizedBuild
            self.sourceSHA = normalizedSource
            self.mainExecutableUUID = normalizedUUID
        }

        static func current(bundle: Bundle = .main) -> BuildIdentity? {
            guard let info = bundle.infoDictionary,
                  let buildNumber = info["CFBundleVersion"] as? String,
                  let sourceSHA = info["OpenClawBuildGitSHA"] as? String
            else { return nil }
            let executableUUIDs = Array(Set(
                AIESRuntimeMachOUUIDReader.readMainExecutable(bundle: bundle).slices.map(\.uuid)))
                .sorted()
            guard executableUUIDs.count == 1 else { return nil }
            return BuildIdentity(
                buildNumber: buildNumber,
                sourceSHA: sourceSHA,
                mainExecutableUUID: executableUUIDs[0])
        }

        private static func isBuildNumber(_ value: String) -> Bool {
            guard (1...32).contains(value.utf8.count) else { return false }
            let components = value.split(separator: ".", omittingEmptySubsequences: false)
            return (1...3).contains(components.count)
                && components.allSatisfy { component in
                    !component.isEmpty && component.utf8.allSatisfy { (48...57).contains($0) }
                }
        }

        private static func isSourceSHA(_ value: String) -> Bool {
            value.utf8.count == 40 && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
        }

        private static func isCanonicalUUID(_ value: String) -> Bool {
            UUID(uuidString: value)?.uuidString.lowercased() == value
        }
    }

    struct Marker: Codable, Equatable, Sendable {
        let schema: String
        let processInstanceID: String
        let launchInstanceID: String
        let boundary: Boundary
        let buildNumber: String?
        let sourceSHA: String?
        let mainExecutableUUID: String?

        init(
            schema: String,
            processInstanceID: String,
            launchInstanceID: String,
            boundary: Boundary,
            buildIdentity: BuildIdentity?)
        {
            self.schema = schema
            self.processInstanceID = processInstanceID
            self.launchInstanceID = launchInstanceID
            self.boundary = boundary
            self.buildNumber = buildIdentity?.buildNumber
            self.sourceSHA = buildIdentity?.sourceSHA
            self.mainExecutableUUID = buildIdentity?.mainExecutableUUID
        }

        var buildIdentity: BuildIdentity? {
            guard let buildNumber, let sourceSHA, let mainExecutableUUID else { return nil }
            return BuildIdentity(
                buildNumber: buildNumber,
                sourceSHA: sourceSHA,
                mainExecutableUUID: mainExecutableUUID)
        }

        var hasNoBuildIdentityFields: Bool {
            self.buildNumber == nil && self.sourceSHA == nil && self.mainExecutableUUID == nil
        }

        var hasCompleteValidBuildIdentity: Bool {
            guard let buildNumber, let sourceSHA, let mainExecutableUUID,
                  let identity = self.buildIdentity
            else { return false }
            return buildNumber == identity.buildNumber
                && sourceSHA == identity.sourceSHA
                && mainExecutableUUID == identity.mainExecutableUUID
        }

        private enum CodingKeys: String, CodingKey {
            case schema
            case processInstanceID = "process_instance_id"
            case launchInstanceID = "launch_instance_id"
            case boundary
            case buildNumber = "build_number"
            case sourceSHA = "source_sha"
            case mainExecutableUUID = "main_executable_uuid"
        }
    }

    struct BootstrapResult: Equatable, Sendable {
        let priorState: PriorState
        let priorProcessInstanceID: String?
        let priorLaunchInstanceID: String?
        let markerWriteSucceeded: Bool
        let priorBuildIdentity: BuildIdentity?
        let currentBuildIdentity: BuildIdentity?

        init(
            priorState: PriorState,
            priorProcessInstanceID: String?,
            priorLaunchInstanceID: String?,
            markerWriteSucceeded: Bool,
            priorBuildIdentity: BuildIdentity? = nil,
            currentBuildIdentity: BuildIdentity? = nil)
        {
            self.priorState = priorState
            self.priorProcessInstanceID = priorProcessInstanceID
            self.priorLaunchInstanceID = priorLaunchInstanceID
            self.markerWriteSucceeded = markerWriteSucceeded
            self.priorBuildIdentity = priorBuildIdentity
            self.currentBuildIdentity = currentBuildIdentity
        }
    }

    private static let liveStarted = OSAllocatedUnfairLock(initialState: false)
    private static let liveBuildIdentity = BuildIdentity.current()

    static var liveMarkerURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
        else { return nil }
        return applicationSupport
            .appendingPathComponent("OpenClaw", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            // Keep the shipped path so the first v2 launch can consume and classify a v1 marker.
            .appendingPathComponent("diagnostic-run-marker-v1.json", isDirectory: false)
    }

    static func startLive() {
        let shouldStart = self.liveStarted.withLock { started in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart, let markerURL = self.liveMarkerURL else {
            if shouldStart {
                self.recordPriorState(
                    priorState: .priorStateUnknown,
                    currentBuildIdentity: self.liveBuildIdentity,
                    resultClass: "marker_path_unavailable")
            }
            return
        }

        let result = self.beginRun(
            markerURL: markerURL,
            processInstanceID: OpenClawDiagnosticEvent.currentProcessInstanceID,
            launchInstanceID: OpenClawDiagnosticEvent.currentLaunchInstanceID,
            buildIdentity: self.liveBuildIdentity)
        self.recordPriorState(
            priorState: result.priorState,
            priorProcessInstanceID: result.priorProcessInstanceID,
            priorLaunchInstanceID: result.priorLaunchInstanceID,
            priorBuildIdentity: result.priorBuildIdentity,
            currentBuildIdentity: result.currentBuildIdentity,
            resultClass: result.markerWriteSucceeded ? "marker_replaced" : "marker_write_failed")
    }

    static func observeBackgroundBoundary() {
        self.persistLiveBoundary(.background, state: "background_boundary_observed")
    }

    static func observeRunningBoundary() {
        self.persistLiveBoundary(.running, state: "running_boundary_observed")
    }

    static func observeOrderlyClose() {
        self.persistLiveBoundary(.orderlyClose, state: "orderly_close_observed")
    }

    static func beginRun(
        markerURL: URL,
        processInstanceID: String,
        launchInstanceID: String,
        buildIdentity: BuildIdentity? = nil,
        fileManager: FileManager = .default) -> BootstrapResult
    {
        guard self.isDigest(processInstanceID), self.isDigest(launchInstanceID) else {
            return BootstrapResult(
                priorState: .priorStateUnknown,
                priorProcessInstanceID: nil,
                priorLaunchInstanceID: nil,
                markerWriteSucceeded: false,
                currentBuildIdentity: buildIdentity)
        }

        let prior = self.readPriorMarker(
            markerURL: markerURL,
            currentBuildIdentity: buildIdentity,
            fileManager: fileManager)
        let current = Marker(
            schema: self.schemaName,
            processInstanceID: processInstanceID,
            launchInstanceID: launchInstanceID,
            boundary: .running,
            buildIdentity: buildIdentity)
        let wrote = self.writeMarker(current, markerURL: markerURL, fileManager: fileManager)
        return BootstrapResult(
            priorState: prior.state,
            priorProcessInstanceID: prior.marker?.processInstanceID,
            priorLaunchInstanceID: prior.marker?.launchInstanceID,
            markerWriteSucceeded: wrote,
            priorBuildIdentity: prior.marker?.buildIdentity,
            currentBuildIdentity: buildIdentity)
    }

    @discardableResult
    static func persistBoundary(
        _ boundary: Boundary,
        markerURL: URL,
        processInstanceID: String,
        launchInstanceID: String,
        buildIdentity: BuildIdentity? = nil,
        fileManager: FileManager = .default) -> Bool
    {
        guard self.isDigest(processInstanceID), self.isDigest(launchInstanceID) else { return false }
        return self.writeMarker(
            Marker(
                schema: self.schemaName,
                processInstanceID: processInstanceID,
                launchInstanceID: launchInstanceID,
                boundary: boundary,
                buildIdentity: buildIdentity),
            markerURL: markerURL,
            fileManager: fileManager)
    }

    private static func persistLiveBoundary(_ boundary: Boundary, state: String) {
        guard self.liveStarted.withLock({ $0 }), let markerURL = self.liveMarkerURL else { return }
        let wrote = self.persistBoundary(
            boundary,
            markerURL: markerURL,
            processInstanceID: OpenClawDiagnosticEvent.currentProcessInstanceID,
            launchInstanceID: OpenClawDiagnosticEvent.currentLaunchInstanceID,
            buildIdentity: self.liveBuildIdentity)
        self.recordAndFlush(OpenClawDiagnosticEvent(
            kind: .appLifecycle,
            state: state,
            resultClass: wrote ? "marker_persisted" : "marker_write_failed"))
    }

    private static func recordPriorState(
        priorState: PriorState,
        priorProcessInstanceID: String? = nil,
        priorLaunchInstanceID: String? = nil,
        priorBuildIdentity: BuildIdentity? = nil,
        currentBuildIdentity: BuildIdentity? = nil,
        resultClass: String)
    {
        self.recordAndFlush(self.makePriorStateEvent(
            priorState: priorState,
            priorProcessInstanceID: priorProcessInstanceID,
            priorLaunchInstanceID: priorLaunchInstanceID,
            priorBuildIdentity: priorBuildIdentity,
            currentBuildIdentity: currentBuildIdentity,
            resultClass: resultClass))
    }

    static func makePriorStateEvent(
        priorState: PriorState,
        priorProcessInstanceID: String? = nil,
        priorLaunchInstanceID: String? = nil,
        priorBuildIdentity: BuildIdentity? = nil,
        currentBuildIdentity: BuildIdentity? = nil,
        resultClass: String) -> OpenClawDiagnosticEvent
    {
        OpenClawDiagnosticEvent(
            kind: .appLifecycle,
            state: priorState.rawValue,
            priorProcessInstanceID: priorProcessInstanceID,
            priorLaunchInstanceID: priorLaunchInstanceID,
            resultClass: resultClass,
            priorBuildNumber: priorBuildIdentity?.buildNumber,
            priorSourceSHA: priorBuildIdentity?.sourceSHA,
            priorMainExecutableUUID: priorBuildIdentity?.mainExecutableUUID,
            currentBuildNumber: currentBuildIdentity?.buildNumber,
            currentSourceSHA: currentBuildIdentity?.sourceSHA,
            currentMainExecutableUUID: currentBuildIdentity?.mainExecutableUUID)
    }

    /// The marker write is synchronous; drain the corresponding allowlisted evidence record too.
    /// This remains bounded because iOS does not guarantee orderly process-termination callbacks.
    @discardableResult
    static func recordAndFlush(
        _ event: OpenClawDiagnosticEvent,
        flush: () -> GatewayDiagnostics.FlushResult = {
            GatewayDiagnostics.flush(timeout: 0.25)
        }) -> GatewayDiagnostics.FlushResult
    {
        OpenClawDiagnosticRecorder.record(event)
        return flush()
    }

    private static func readPriorMarker(
        markerURL: URL,
        currentBuildIdentity: BuildIdentity?,
        fileManager: FileManager) -> (state: PriorState, marker: Marker?)
    {
        guard fileManager.fileExists(atPath: markerURL.path) else {
            return (.noPriorRun, nil)
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: markerURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= self.maximumMarkerBytes
        else {
            return (.priorStateCorrupt, nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: markerURL)
        } catch {
            return (.priorStateUnknown, nil)
        }
        guard data.count <= self.maximumMarkerBytes,
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              [self.legacySchemaName, self.schemaName].contains(marker.schema),
              self.isDigest(marker.processInstanceID),
              self.isDigest(marker.launchInstanceID),
              self.hasValidBuildIdentityShape(marker)
        else {
            return (.priorStateCorrupt, nil)
        }
        let state: PriorState = switch marker.boundary {
        case .running:
            if let priorBuildIdentity = marker.buildIdentity, let currentBuildIdentity {
                priorBuildIdentity == currentBuildIdentity
                    ? .previousRunUnclosedSameBuild
                    : .previousRunUnclosedBuildTransition
            } else {
                .previousRunUnclosedIdentityUnknown
            }
        case .background: .priorBackgroundBoundaryObserved
        case .orderlyClose: .orderlyCloseObserved
        }
        return (state, marker)
    }

    private static func hasValidBuildIdentityShape(_ marker: Marker) -> Bool {
        switch marker.schema {
        case self.legacySchemaName:
            marker.hasNoBuildIdentityFields
        case self.schemaName:
            marker.hasNoBuildIdentityFields || marker.hasCompleteValidBuildIdentity
        default:
            false
        }
    }

    private static func writeMarker(
        _ marker: Marker,
        markerURL: URL,
        fileManager: FileManager) -> Bool
    {
        do {
            let directory = markerURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try self.excludeFromBackup(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(marker)
            guard data.count <= self.maximumMarkerBytes else { return false }
            try data.write(
                to: markerURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: markerURL.path)
            try self.excludeFromBackup(markerURL)
            return true
        } catch {
            return false
        }
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}
