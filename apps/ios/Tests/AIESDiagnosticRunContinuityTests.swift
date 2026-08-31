import Foundation
import OpenClawKit
import os
import Testing
@testable import OpenClaw

@Suite(.serialized)
struct AIESDiagnosticRunContinuityTests {
    private static let build104 = AIESDiagnosticRunContinuity.BuildIdentity(
        buildNumber: "104",
        sourceSHA: "22f90eacf93ba05f16aea6b106bd3c063f95d79d",
        mainExecutableUUID: "bec23370-891f-3fa9-91d4-d5021a687519")!

    @Test func rotatesIdentityAndDetectsUnclosedPriorRunInSameBuild() throws {
        try self.withMarkerURL { markerURL in
            let first = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222",
                buildIdentity: Self.build104)
            #expect(first.priorState == .noPriorRun)
            #expect(first.priorBuildIdentity == nil)
            #expect(first.currentBuildIdentity == Self.build104)
            #expect(first.markerWriteSucceeded)

            let second = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444",
                buildIdentity: Self.build104)
            #expect(second.priorState == .previousRunUnclosedSameBuild)
            #expect(second.priorProcessInstanceID == "1111111111111111")
            #expect(second.priorLaunchInstanceID == "2222222222222222")
            #expect(second.priorBuildIdentity == Self.build104)
            #expect(second.currentBuildIdentity == Self.build104)
            #expect(second.markerWriteSucceeded)
            let markerData = try Data(contentsOf: markerURL)
            #expect(markerData.count <= AIESDiagnosticRunContinuity.maximumMarkerBytes)
            let marker = try #require(JSONSerialization.jsonObject(with: markerData) as? [String: Any])
            #expect(marker["schema"] as? String == AIESDiagnosticRunContinuity.schemaName)
            #expect(marker["build_number"] as? String == "104")
            #expect(marker["source_sha"] as? String == Self.build104.sourceSHA)
            #expect(marker["main_executable_uuid"] as? String == Self.build104.mainExecutableUUID)
        }
    }

    @Test func readsLegacyV1MarkerAsUnclosedIdentityUnknownThenReplacesItWithV2() throws {
        try self.withMarkerURL { markerURL in
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let legacy = try JSONSerialization.data(withJSONObject: [
                "boundary": "running",
                "launch_instance_id": "2222222222222222",
                "process_instance_id": "1111111111111111",
                "schema": AIESDiagnosticRunContinuity.legacySchemaName,
            ], options: [.sortedKeys])
            try legacy.write(to: markerURL)

            let result = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444",
                buildIdentity: Self.build104)

            #expect(result.priorState == .previousRunUnclosedIdentityUnknown)
            #expect(result.priorProcessInstanceID == "1111111111111111")
            #expect(result.priorLaunchInstanceID == "2222222222222222")
            #expect(result.priorBuildIdentity == nil)
            #expect(result.currentBuildIdentity == Self.build104)
            let replacement = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
            #expect(replacement["schema"] as? String == AIESDiagnosticRunContinuity.schemaName)
            #expect(replacement["build_number"] as? String == "104")
        }
    }

    @Test func classifiesAnyKnownBuildIdentityChangeAsBuildTransition() throws {
        let transitions = [
            AIESDiagnosticRunContinuity.BuildIdentity(
                buildNumber: "105",
                sourceSHA: Self.build104.sourceSHA,
                mainExecutableUUID: Self.build104.mainExecutableUUID)!,
            AIESDiagnosticRunContinuity.BuildIdentity(
                buildNumber: Self.build104.buildNumber,
                sourceSHA: "1111111111111111111111111111111111111111",
                mainExecutableUUID: Self.build104.mainExecutableUUID)!,
            AIESDiagnosticRunContinuity.BuildIdentity(
                buildNumber: Self.build104.buildNumber,
                sourceSHA: Self.build104.sourceSHA,
                mainExecutableUUID: "11111111-1111-4111-8111-111111111111")!,
        ]

        for currentBuild in transitions {
            try self.withMarkerURL { markerURL in
                _ = AIESDiagnosticRunContinuity.beginRun(
                    markerURL: markerURL,
                    processInstanceID: "1111111111111111",
                    launchInstanceID: "2222222222222222",
                    buildIdentity: Self.build104)
                let result = AIESDiagnosticRunContinuity.beginRun(
                    markerURL: markerURL,
                    processInstanceID: "3333333333333333",
                    launchInstanceID: "4444444444444444",
                    buildIdentity: currentBuild)
                #expect(result.priorState == .previousRunUnclosedBuildTransition)
                #expect(result.priorBuildIdentity == Self.build104)
                #expect(result.currentBuildIdentity == currentBuild)
            }
        }
    }

    @Test func classifiesMissingV2IdentityAsUnknownAndPartialV2IdentityAsCorrupt() throws {
        try self.withMarkerURL { markerURL in
            _ = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222")
            let unknown = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444",
                buildIdentity: Self.build104)
            #expect(unknown.priorState == .previousRunUnclosedIdentityUnknown)
        }

        try self.withMarkerURL { markerURL in
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let partial = try JSONSerialization.data(withJSONObject: [
                "boundary": "running",
                "build_number": "104",
                "launch_instance_id": "2222222222222222",
                "process_instance_id": "1111111111111111",
                "schema": AIESDiagnosticRunContinuity.schemaName,
            ], options: [.sortedKeys])
            try partial.write(to: markerURL)
            let result = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444",
                buildIdentity: Self.build104)
            #expect(result.priorState == .priorStateCorrupt)
            #expect(result.priorBuildIdentity == nil)
            #expect(result.markerWriteSucceeded)
        }
    }

    @Test func rejectsNoncanonicalBuildIdentityFields() throws {
        #expect(AIESDiagnosticRunContinuity.BuildIdentity(
            buildNumber: "104-beta",
            sourceSHA: Self.build104.sourceSHA,
            mainExecutableUUID: Self.build104.mainExecutableUUID) == nil)
        #expect(AIESDiagnosticRunContinuity.BuildIdentity(
            buildNumber: "104",
            sourceSHA: "not-a-source-sha",
            mainExecutableUUID: Self.build104.mainExecutableUUID) == nil)
        #expect(AIESDiagnosticRunContinuity.BuildIdentity(
            buildNumber: "104",
            sourceSHA: Self.build104.sourceSHA,
            mainExecutableUUID: "not-an-executable-uuid") == nil)

        try self.withMarkerURL { markerURL in
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let noncanonical = try JSONSerialization.data(withJSONObject: [
                "boundary": "running",
                "build_number": "104",
                "launch_instance_id": "2222222222222222",
                "main_executable_uuid": "BEC23370-891F-3FA9-91D4-D5021A687519",
                "process_instance_id": "1111111111111111",
                "schema": AIESDiagnosticRunContinuity.schemaName,
                "source_sha": "22F90EACF93BA05F16AEA6B106BD3C063F95D79D",
            ], options: [.sortedKeys])
            try noncanonical.write(to: markerURL)
            let result = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444",
                buildIdentity: Self.build104)
            #expect(result.priorState == .priorStateCorrupt)
            #expect(result.markerWriteSucceeded)
        }
    }

    @Test func classifiesBackgroundAndOrderlyBoundariesWithoutCallingThemCrashes() throws {
        try self.withMarkerURL { markerURL in
            _ = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222",
                buildIdentity: Self.build104)
            #expect(AIESDiagnosticRunContinuity.persistBoundary(
                .background,
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222",
                buildIdentity: Self.build104))

            let afterBackground = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444",
                buildIdentity: Self.build104)
            #expect(afterBackground.priorState == .priorBackgroundBoundaryObserved)
            #expect(afterBackground.priorProcessInstanceID == "1111111111111111")
            #expect(afterBackground.priorLaunchInstanceID == "2222222222222222")

            #expect(AIESDiagnosticRunContinuity.persistBoundary(
                .orderlyClose,
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444",
                buildIdentity: Self.build104))
            let afterOrderlyClose = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "5555555555555555",
                launchInstanceID: "6666666666666666",
                buildIdentity: Self.build104)
            #expect(afterOrderlyClose.priorState == .orderlyCloseObserved)
        }
    }

    @Test func returningActiveReestablishesRunningBoundary() throws {
        try self.withMarkerURL { markerURL in
            _ = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222",
                buildIdentity: Self.build104)
            #expect(AIESDiagnosticRunContinuity.persistBoundary(
                .background,
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222",
                buildIdentity: Self.build104))
            #expect(AIESDiagnosticRunContinuity.persistBoundary(
                .running,
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222",
                buildIdentity: Self.build104))

            let nextLaunch = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444",
                buildIdentity: Self.build104)
            #expect(nextLaunch.priorState == .previousRunUnclosedSameBuild)
            #expect(nextLaunch.priorProcessInstanceID == "1111111111111111")
            #expect(nextLaunch.priorLaunchInstanceID == "2222222222222222")
        }
    }

    @Test func corruptPriorStateIsBoundedAndReplacedAtomically() throws {
        try self.withMarkerURL { markerURL in
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data("private-content-that-must-not-be-decoded".utf8).write(to: markerURL)

            let result = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222")
            #expect(result.priorState == .priorStateCorrupt)
            #expect(result.priorProcessInstanceID == nil)
            #expect(result.priorLaunchInstanceID == nil)
            #expect(result.markerWriteSucceeded)
            let replacement = String(decoding: try Data(contentsOf: markerURL), as: UTF8.self)
            #expect(!replacement.contains("private-content"))
        }
    }

    @Test func rejectsInvalidCurrentIdentityWithoutPersistingIt() throws {
        try self.withMarkerURL { markerURL in
            let result = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "raw-process-identity",
                launchInstanceID: "raw-launch-identity")
            #expect(result.priorState == .priorStateUnknown)
            #expect(!result.markerWriteSucceeded)
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func lifecycleEvidenceIsRecordedBeforeItsBoundedFlushBarrier() throws {
        let order = OSAllocatedUnfairLock(initialState: [String]())
        OpenClawDiagnosticRecorder.installSink { _ in
            order.withLock { $0.append("record") }
        }
        defer { OpenClawDiagnosticRecorder.clearSink() }

        let result = AIESDiagnosticRunContinuity.recordAndFlush(
            OpenClawDiagnosticEvent(kind: .appLifecycle, state: "previous_run_unclosed"),
            flush: {
                order.withLock { $0.append("flush") }
                return .completed
            })

        #expect(result == .completed)
        #expect(order.withLock { $0 } == ["record", "flush"])
    }

    @Test func buildTransitionEvidenceRetainsPriorAndCurrentIdentity() throws {
        let build105 = try #require(AIESDiagnosticRunContinuity.BuildIdentity(
            buildNumber: "105",
            sourceSHA: "1111111111111111111111111111111111111111",
            mainExecutableUUID: "11111111-1111-4111-8111-111111111111"))
        let event = AIESDiagnosticRunContinuity.makePriorStateEvent(
            priorState: .previousRunUnclosedBuildTransition,
            priorProcessInstanceID: "1111111111111111",
            priorLaunchInstanceID: "2222222222222222",
            priorBuildIdentity: Self.build104,
            currentBuildIdentity: build105,
            resultClass: "marker_replaced")

        let retainedLine = OSAllocatedUnfairLock<String?>(initialState: nil)
        OpenClawDiagnosticRecorder.installSink { line in
            retainedLine.withLock { $0 = line }
        }
        defer { OpenClawDiagnosticRecorder.clearSink() }
        OpenClawDiagnosticRecorder.record(event)
        let decoded = try #require(
            retainedLine.withLock { $0 }.flatMap(OpenClawDiagnosticRecorder.decodeRecord))

        #expect(decoded.kind == .appLifecycle)
        #expect(decoded.state == "previous_run_unclosed_build_transition")
        #expect(decoded.priorProcessInstanceID == "1111111111111111")
        #expect(decoded.priorLaunchInstanceID == "2222222222222222")
        #expect(decoded.priorBuildNumber == "104")
        #expect(decoded.priorSourceSHA == Self.build104.sourceSHA)
        #expect(decoded.priorMainExecutableUUID == Self.build104.mainExecutableUUID)
        #expect(decoded.currentBuildNumber == "105")
        #expect(decoded.currentSourceSHA == build105.sourceSHA)
        #expect(decoded.currentMainExecutableUUID == build105.mainExecutableUUID)
    }

    private func withMarkerURL(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aies-run-continuity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("diagnostic-run-marker-v1.json"))
    }
}
