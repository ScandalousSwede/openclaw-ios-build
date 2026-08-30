import Foundation
import OpenClawKit
import os

enum AIESDiagnosticRunContinuity {
    static let schemaName = "argus.openclaw-ios.diagnostic-run-marker.v1"
    static let maximumMarkerBytes = 2048

    enum PriorState: String, Codable, Equatable, Sendable {
        case previousRunUnclosed = "previous_run_unclosed"
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

    struct Marker: Codable, Equatable, Sendable {
        let schema: String
        let processInstanceID: String
        let launchInstanceID: String
        let boundary: Boundary

        private enum CodingKeys: String, CodingKey {
            case schema
            case processInstanceID = "process_instance_id"
            case launchInstanceID = "launch_instance_id"
            case boundary
        }
    }

    struct BootstrapResult: Equatable, Sendable {
        let priorState: PriorState
        let priorProcessInstanceID: String?
        let priorLaunchInstanceID: String?
        let markerWriteSucceeded: Bool
    }

    private static let liveStarted = OSAllocatedUnfairLock(initialState: false)

    static var liveMarkerURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
        else { return nil }
        return applicationSupport
            .appendingPathComponent("OpenClaw", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
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
                    resultClass: "marker_path_unavailable")
            }
            return
        }

        let result = self.beginRun(
            markerURL: markerURL,
            processInstanceID: OpenClawDiagnosticEvent.currentProcessInstanceID,
            launchInstanceID: OpenClawDiagnosticEvent.currentLaunchInstanceID)
        self.recordPriorState(
            priorState: result.priorState,
            priorProcessInstanceID: result.priorProcessInstanceID,
            priorLaunchInstanceID: result.priorLaunchInstanceID,
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
        fileManager: FileManager = .default) -> BootstrapResult
    {
        guard self.isDigest(processInstanceID), self.isDigest(launchInstanceID) else {
            return BootstrapResult(
                priorState: .priorStateUnknown,
                priorProcessInstanceID: nil,
                priorLaunchInstanceID: nil,
                markerWriteSucceeded: false)
        }

        let prior = self.readPriorMarker(markerURL: markerURL, fileManager: fileManager)
        let current = Marker(
            schema: self.schemaName,
            processInstanceID: processInstanceID,
            launchInstanceID: launchInstanceID,
            boundary: .running)
        let wrote = self.writeMarker(current, markerURL: markerURL, fileManager: fileManager)
        return BootstrapResult(
            priorState: prior.state,
            priorProcessInstanceID: prior.marker?.processInstanceID,
            priorLaunchInstanceID: prior.marker?.launchInstanceID,
            markerWriteSucceeded: wrote)
    }

    @discardableResult
    static func persistBoundary(
        _ boundary: Boundary,
        markerURL: URL,
        processInstanceID: String,
        launchInstanceID: String,
        fileManager: FileManager = .default) -> Bool
    {
        guard self.isDigest(processInstanceID), self.isDigest(launchInstanceID) else { return false }
        return self.writeMarker(
            Marker(
                schema: self.schemaName,
                processInstanceID: processInstanceID,
                launchInstanceID: launchInstanceID,
                boundary: boundary),
            markerURL: markerURL,
            fileManager: fileManager)
    }

    private static func persistLiveBoundary(_ boundary: Boundary, state: String) {
        guard self.liveStarted.withLock({ $0 }), let markerURL = self.liveMarkerURL else { return }
        let wrote = self.persistBoundary(
            boundary,
            markerURL: markerURL,
            processInstanceID: OpenClawDiagnosticEvent.currentProcessInstanceID,
            launchInstanceID: OpenClawDiagnosticEvent.currentLaunchInstanceID)
        self.recordAndFlush(OpenClawDiagnosticEvent(
            kind: .appLifecycle,
            state: state,
            resultClass: wrote ? "marker_persisted" : "marker_write_failed"))
    }

    private static func recordPriorState(
        priorState: PriorState,
        priorProcessInstanceID: String? = nil,
        priorLaunchInstanceID: String? = nil,
        resultClass: String)
    {
        self.recordAndFlush(OpenClawDiagnosticEvent(
            kind: .appLifecycle,
            state: priorState.rawValue,
            priorProcessInstanceID: priorProcessInstanceID,
            priorLaunchInstanceID: priorLaunchInstanceID,
            resultClass: resultClass))
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
              marker.schema == self.schemaName,
              self.isDigest(marker.processInstanceID),
              self.isDigest(marker.launchInstanceID)
        else {
            return (.priorStateCorrupt, nil)
        }
        let state: PriorState = switch marker.boundary {
        case .running: .previousRunUnclosed
        case .background: .priorBackgroundBoundaryObserved
        case .orderlyClose: .orderlyCloseObserved
        }
        return (state, marker)
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
