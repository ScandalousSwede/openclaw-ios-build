import Foundation
import OpenClawKit
import os
import Testing
@testable import OpenClaw

@Suite(.serialized)
struct AIESDiagnosticRunContinuityTests {
    @Test func rotatesIdentityAndDetectsUnclosedPriorRun() throws {
        try self.withMarkerURL { markerURL in
            let first = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222")
            #expect(first == .init(
                priorState: .noPriorRun,
                priorProcessInstanceID: nil,
                priorLaunchInstanceID: nil,
                markerWriteSucceeded: true))

            let second = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444")
            #expect(second == .init(
                priorState: .previousRunUnclosed,
                priorProcessInstanceID: "1111111111111111",
                priorLaunchInstanceID: "2222222222222222",
                markerWriteSucceeded: true))
            let markerData = try Data(contentsOf: markerURL)
            #expect(markerData.count <= AIESDiagnosticRunContinuity.maximumMarkerBytes)
        }
    }

    @Test func classifiesBackgroundAndOrderlyBoundariesWithoutCallingThemCrashes() throws {
        try self.withMarkerURL { markerURL in
            _ = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222")
            #expect(AIESDiagnosticRunContinuity.persistBoundary(
                .background,
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222"))

            let afterBackground = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444")
            #expect(afterBackground.priorState == .priorBackgroundBoundaryObserved)
            #expect(afterBackground.priorProcessInstanceID == "1111111111111111")
            #expect(afterBackground.priorLaunchInstanceID == "2222222222222222")

            #expect(AIESDiagnosticRunContinuity.persistBoundary(
                .orderlyClose,
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444"))
            let afterOrderlyClose = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "5555555555555555",
                launchInstanceID: "6666666666666666")
            #expect(afterOrderlyClose.priorState == .orderlyCloseObserved)
        }
    }

    @Test func returningActiveReestablishesRunningBoundary() throws {
        try self.withMarkerURL { markerURL in
            _ = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222")
            #expect(AIESDiagnosticRunContinuity.persistBoundary(
                .background,
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222"))
            #expect(AIESDiagnosticRunContinuity.persistBoundary(
                .running,
                markerURL: markerURL,
                processInstanceID: "1111111111111111",
                launchInstanceID: "2222222222222222"))

            let nextLaunch = AIESDiagnosticRunContinuity.beginRun(
                markerURL: markerURL,
                processInstanceID: "3333333333333333",
                launchInstanceID: "4444444444444444")
            #expect(nextLaunch.priorState == .previousRunUnclosed)
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

    private func withMarkerURL(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aies-run-continuity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("diagnostic-run-marker-v1.json"))
    }
}
