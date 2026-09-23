import OpenClawChatUI
import OpenClawKit
import SwiftUI
import UIKit
import UserNotifications
import Vision
import XCTest
@testable import OpenClaw

final class ArgusOperationsScreenshotTests: XCTestCase {
    @MainActor
    func testCurrentWorkAtBothTextSizesAndRetainedState() async throws {
        let store = ArgusCurrentWorkStore()
        let page = try ArgusOperationsTests.currentWorkFixture()
        store.selectGateway("synthetic-current-work")
        await store.refresh(gatewayID: "synthetic-current-work") { page }
        for (name, size) in [("standard", DynamicTypeSize.large), ("retained-accessibility", .accessibility1)] {
            if name == "retained-accessibility" { store.markUnavailable() }
            let root = VStack(alignment: .leading, spacing: 16) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                ArgusCurrentWorkContent(store: store, client: nil)
            }
            .padding(.vertical)
            .background { CommandControlBackground() }
            .tint(OpenClawBrand.accent)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            let image = try self.hostedImage(root, requiredText: [
                "Current decisions", "Recorded choices for you", "Engineering follow-through",
                "Synthetic research grant", "Synthetic package recovery", "Next: Engineering",
                "Document acceptance recorded", "Recorded report", "activation remains unapproved",
                "Other work may not be included", "Source coverage",
            ] + (name == "retained-accessibility" ? ["Showing the last check", "may have changed"] : []),
            forbiddenText: ["Nothing needs you", "All work complete", "synthetic-operation"])
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-current-work-synthetic-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    func testExactDecisionReceiptAtBothTextSizes() throws {
        for status in ["accepted_exact_artifact", "unavailable"] {
            let (item, work) = try ArgusWorkContractTests.fixture(
                decision: ArgusWorkContractTests.decisionPayload(status: status))
            let detail = ArgusOperationDetail(
                item: item, requested: item, timeline: [],
                coverage: .init(complete: true, hasMore: false, observedAt: item.observedAt),
                ownerAccepted: false, workContract: work)
            try detail.validate(for: item)
            for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility1)] {
                let root = VStack(alignment: .leading, spacing: 16) {
                    Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                    ArgusOperationEvidenceContent(
                        detail: detail, artifactsAvailable: true, openArtifact: { _, _ in })
                }
                .padding(20)
                .background { CommandControlBackground() }
                .environment(\.dynamicTypeSize, size)
                .environment(\.colorScheme, .dark)
                .frame(width: 390)
                .fixedSize(horizontal: false, vertical: true)
                let required = status == "accepted_exact_artifact"
                    ? ["Document acceptance recorded", "Next: Engineering",
                       "Engineering will reconcile the remaining operational work", "Read recorded decision"]
                    : ["Engineering reconciliation needed", "This is not a new request for your approval"]
                let image = try self.hostedImage(
                    root, requiredText: required + ["Decision checked", "Decision details"],
                    forbiddenText: status == "unavailable" ? ["Document acceptance recorded", "Read recorded decision"] : [])
                let attachment = XCTAttachment(image: image)
                attachment.name = "argus-decision-receipt-synthetic-\(status)-\(name)"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
        }
    }

    @MainActor
    func testEmptySessionStateWrapsAtBothSizes() throws {
        for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility1)] {
            let root = VStack(alignment: .leading, spacing: 16) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                CommandPanel(padding: 12) {
                    CommandEmptyStateRow(
                        icon: "wifi.slash",
                        title: "Sessions unavailable",
                        detail: "Recent conversations will appear here when available.")
                }
            }
            .padding(20)
            .background { CommandControlBackground() }
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            let image = try self.hostedImage(root, requiredText: [
                "Sessions unavailable", "Recent conversations will appear here when available",
            ])
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-empty-sessions-wrapping-synthetic-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    func testRetainedSessionListAtStandardAndAccessibilitySizes() async throws {
        let model = NodeAppModel()
        model._test_setChatOutboxGatewayOwnerID("synthetic-session-list-owner")
        model._test_setGatewayRoleStates(node: .offline, operator: .offline)
        let state = CommandSessionListState()
        let owner = try XCTUnwrap(model.commandSessionListOwner)
        let data = try JSONSerialization.data(withJSONObject: [[
            "key": "fixture:retained-conversation",
            "displayName": "Synthetic planning conversation",
            "updatedAt": 1_700_000_000_000,
        ]])
        let entries = try JSONDecoder().decode([OpenClawChatSessionEntry].self, from: data)
        await state.refresh(owner: owner, available: true, currentOwner: { owner }) { entries }
        await state.refresh(owner: owner, available: false, currentOwner: { owner }) { [] }
        for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility1)] {
            let root = VStack(spacing: 0) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                CommandSessionsScreen(sessionList: state, openChat: {})
            }
            .tint(OpenClawBrand.accent)
            .environment(model)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 390, height: 844)
            let image = try self.hostedImage(root, requiredText: [
                "last session list", "Synthetic planning conversation",
            ], forbiddenText: ["Connect to the gateway", "No recent sessions"])
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-retained-sessions-synthetic-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    func testHomeGatewayStatusIgnoresMisleadingTextAtBothSizes() throws {
        let cases: [(String, GatewayNodeRoleState, GatewayOperatorRoleState, String, String)] = [
            ("disconnected", .offline, .offline, "Disconnected: network closed", "Offline"),
            ("timeout", .offline, .offline, "Connection timed out", "Offline"),
            ("scope-blocked", .online, .scopeBlocked(missing: ["operator.read"]),
             "Operator/chat reconnect required", "Needs attention"),
            ("connecting", .connecting, .offline, "Disconnected: previous attempt", "Connecting"),
            ("connected", .online, .online, "Connection timed out", "Connected"),
            ("partial", .online, .offline, "Connected", "Offline"),
        ]
        for (name, node, operatorState, staleText, expected) in cases {
            let model = NodeAppModel()
            model._test_setGatewayRoleStates(node: node, operator: operatorState)
            model.gatewayStatusText = staleText
            for (sizeName, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility1)] {
                let root = VStack(alignment: .leading, spacing: 16) {
                    Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                    CommandGatewayStatus()
                }
                .padding(20)
                .background { CommandControlBackground() }
                .environment(model)
                .environment(\.dynamicTypeSize, size)
                .environment(\.colorScheme, .dark)
                .frame(width: 390)
                .fixedSize(horizontal: false, vertical: true)
                let image = try self.hostedImage(
                    root, requiredText: [expected],
                    forbiddenText: ["Connected", "Connecting", "Needs attention", "Offline"].filter { $0 != expected })
                let attachment = XCTAttachment(image: image)
                attachment.name = "argus-home-gateway-status-synthetic-\(name)-\(sizeName)"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
        }
    }

    @MainActor
    func testEvidenceRecoveryNoticesAtStandardAndAccessibilitySizes() throws {
        for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility1)] {
            let root = VStack(alignment: .leading, spacing: 16) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                ArgusEvidenceRecoveryNotice(retainsDetail: true)
                ArgusEvidenceRecoveryNotice(retainsDetail: false)
            }
            .padding(20)
            .background { CommandControlBackground() }
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            let image = try self.hostedImage(root, requiredText: [
                "Reconnecting", "Your last view is still here", "Waiting for connection", "try again automatically",
            ])
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-evidence-recovery-notices-synthetic-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    func testHomeShowsOrdinaryResultAtStandardAndAccessibilitySizes() throws {
        let model = NodeAppModel()
        let store = ArgusOperationsStore()
        let item = ArgusOperation(
            operationId: "fixture-summary-operation", taskId: "ordinary-summary-fixture-job",
            eventId: "fixture-summary-event", title: "Synthetic morning briefing",
            source: "federation:fixture-ordinary-producer", project: "Argus", kind: "summary",
            state: "observed", occurredAt: "2026-09-22T08:00:00Z", observedAt: "2026-09-22T08:00:01Z",
            artifacts: [], supersedesEventId: nil, ownerAccepted: false)
        try store.accept(.init(
            items: [item], coverage: .init(complete: true, hasMore: false, observedAt: item.observedAt),
            nextCursor: nil, automaticDispatchEnabled: false), more: false)
        store.markUnavailable()
        for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility1)] {
            let root = CommandCenterTab(
                workStore: store, workClient: nil, openWork: {}, openChat: {}, openSettings: {})
                .tint(OpenClawBrand.accent)
                .environment(model)
                .environment(\.dynamicTypeSize, size)
                .environment(\.colorScheme, .dark)
                .frame(width: 390, height: 844)
            let image = try self.hostedImage(root, requiredText: [
                "ARGUS", "Latest report", "Synthetic morning briefing", "All work and results", "Connection details",
            ])
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-home-ordinary-result-synthetic-offline-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    func testConnectionDetailsAndSessionTextReflowWithoutTruncation() throws {
        let item = CommandCenterTab.WorkItem(
            id: "fixture-session", icon: "bubble.left", title: "Synthetic administrative follow-up",
            detail: "No recent activity", state: "open", trailing: "chat", color: OpenClawBrand.accent,
            progress: nil, route: .chat(nil))
        for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility1)] {
            let root = VStack(alignment: .leading, spacing: 16) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                CommandPanel {
                    CommandGatewayFacts(
                        nodeStatus: "Waiting for approval", operatorStatus: "Offline", agentCount: "Unavailable")
                }
                CommandSessionRow(item: item)
            }
            .padding(20)
            .background { CommandControlBackground() }
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            let image = try self.hostedImage(root, requiredText: [
                "Gateway/node", "Operator/chat", "Agents", "Waiting for approval", "Offline", "Unavailable",
                "Synthetic administrative follow-up", "No recent activity", "chat", "open",
            ])
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-home-details-session-reflow-synthetic-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    func testNotificationResumeControlAtStandardAndAccessibilitySizes() throws {
        for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility1)] {
            let root = VStack(alignment: .leading, spacing: 12) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                ArgusEvidenceResumeButton(reopen: {})
            }
            .padding()
            .background(Color(uiColor: .systemBackground))
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            let image = try self.hostedImage(
                root,
                requiredText: ["Reopen last notification", "exact work evidence", "app session"])
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-notification-resume-synthetic-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    func testNotificationReferenceCorrectionUsesProductionEvidenceHierarchy() async throws {
        let (detail, _) = ArgusEvidenceNotificationTests.fixture()
        let reference = try XCTUnwrap(ArgusEvidenceNotificationReference.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["openclaw": [
                "kind": "argus.evidence",
                "gatewayDeviceId": "fixture-gateway",
                "operationId": detail.requested.id,
                "eventId": detail.requested.eventId,
                "artifactSha256": detail.requested.artifacts[0].sha256,
            ]]))
        let resolved = try await reference.resolve(
            identity: { .init(deviceId: "fixture-gateway") },
            detail: { _ in detail },
            stillCurrent: { true })
        let root = VStack(alignment: .leading, spacing: 12) {
            Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
            ArgusOperationEvidenceContent(detail: resolved, artifactsAvailable: true, openArtifact: { _, _ in })
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
        .environment(\.dynamicTypeSize, .accessibility1)
        .environment(\.colorScheme, .dark)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        let image = try self.hostedImage(
            root,
            artifactNames: ["correction.txt"],
            requiredText: [
                "A newer observation",
                "Recorded artifacts",
                "Source and provenance",
            ])
        let attachment = XCTAttachment(image: image)
        attachment.name = "argus-notification-reference-correction-synthetic-accessibility"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    @MainActor
    func testProductionEvidenceCardsAtStandardAndAccessibilitySizes() throws {
        let model = NodeAppModel()
        let client = ArgusOperationsClient(session: model.operatorSession, gatewayID: "simulator-fixture")
        let store = ArgusOperationsStore()
        store.selectGateway("simulator-fixture")
        var item = ArgusOperation(
            operationId: "fixture-operation", taskId: "fixture-task", eventId: "fixture-event",
            title: "Synthetic result: checkpoint retry verified",
            source: "federation:fixture-simulator", project: "Argus", kind: "test fixture", state: "observed",
            occurredAt: "2026-09-06T00:00:00Z", observedAt: "2026-09-06T00:01:00Z",
            artifacts: [.init(sha256: String(repeating: "a", count: 64), bytes: 12)],
            supersedesEventId: nil, ownerAccepted: false)
        item.display = .init(
            label: "Checkpoint retry repaired",
            changeSummary: "A retry now resumes the recorded batch. The validation artifact is available in detail.",
            artifactLabel: nil,
            continuationLabel: nil)
        let earlier = ArgusOperation(
            operationId: "fixture-earlier", taskId: "fixture-earlier-task", eventId: "fixture-earlier-event",
            title: "Synthetic unfamiliar producer observation with a long title that must remain readable and available in full.",
            source: "federation:fixture-simulator", project: "Argus", kind: "test fixture", state: "observed",
            occurredAt: "2026-09-06T00:00:00Z", observedAt: "2026-09-06T00:00:30Z",
            artifacts: [], supersedesEventId: "fixture-previous-event", ownerAccepted: false)
        try store.accept(ArgusOperationsPage(
            items: [item, earlier],
            coverage: ArgusOperationsCoverage(complete: true, hasMore: false, observedAt: "2026-09-22T18:16:00Z"),
            nextCursor: nil, automaticDispatchEnabled: false), more: false)

        for (name, size) in [("standard", DynamicTypeSize.large), ("offline-accessibility", .accessibility1)] {
            if name == "offline-accessibility" {
                store.markUnavailable()
            }
            let root = VStack(alignment: .leading, spacing: 12) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE")
                    .font(.caption.bold()).padding(.horizontal)
                ArgusOperationsContent(store: store, client: name == "standard" ? client : nil)
            }
            .padding(.top)
            .background(Color(uiColor: .systemBackground))
            .environment(model)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            let image = try self.hostedImage(
                root, selectedProject: store.project.rawValue,
                requiredText: [
                    "Report history", "Current progress and requests", "Reports with documents", "Recorded updates",
                    "Checkpoint retry repaired", "A retry now resumes the recorded batch", "Report dated",
                    "Report with documents", "No document is attached to this event", "Correction recorded",
                ] + (name == "standard" ? ["Open report", "View update"] : []),
                forbiddenText: ["Artifact Produced", "Last observed", "Work and results", "Nothing needs you"]
                    + (name == "standard" ? [] : ["Open report", "View update"]))
            let fullImage = try XCTUnwrap(image.cgImage)
            // Exclude the fixture warning: it must not make an empty content render pass.
            let labelExclusionHeight = 200
            XCTAssertGreaterThan(fullImage.height, labelExclusionHeight)
            let cgImage = try XCTUnwrap(fullImage.cropping(to: CGRect(
                x: 0, y: CGFloat(labelExclusionHeight), width: CGFloat(fullImage.width),
                height: CGFloat(fullImage.height - labelExclusionHeight))))
            var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            let hasVisibleContent = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: cgImage.width, height: cgImage.height,
                    bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(cgImage, in: CGRect(
                    x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
                var brightPixels = 0
                var darkPixels = 0
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    let brightness = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
                    if brightness > 180 {
                        brightPixels += 1
                    }
                    if brightness < 60 {
                        darkPixels += 1
                    }
                }
                return brightPixels > 100 && darkPixels > 100
            }
            XCTAssertTrue(
                hasVisibleContent,
                "Evidence below the fixture label must have visible text/background contrast")
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-home-simulator-fixture-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    func testProductionCanonicalWorkSummary() throws {
        for (relation, heading) in [
            ("previous_attempt", "Previous attempt artifacts"),
            ("current_attempt", "Current attempt artifacts"),
            ("unknown", "Recorded artifacts"),
            ("federation_observation", "Recorded artifacts"),
            ("missing", "Recorded artifacts"),
        ] {
            var (item, work) = try ArgusWorkContractTests.fixture(relation: relation)
            if relation == "missing" {
                item.artifactContext = nil
            }
            try work.validate(for: item)
            let root = VStack(alignment: .leading, spacing: 12) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                ArgusOperationEvidenceContent(
                    detail: .init(
                        item: item,
                        requested: item,
                        timeline: [],
                        coverage: .init(complete: false, hasMore: true, observedAt: item.observedAt),
                        ownerAccepted: false,
                        workContract: work),
                    artifactsAvailable: true, openArtifact: { _, _ in })
            }
            .padding()
            .background(Color(uiColor: .systemBackground))
            .environment(\.dynamicTypeSize, .accessibility1)
            .environment(\.colorScheme, .dark)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            let image = try self.hostedImage(root, requiredText: [heading, "Verification and scope"])
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-work-simulator-fixture-\(relation)-accessibility"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    func testProductionRunningBeforeFirstArtifactSummary() throws {
        let (item, work) = try ArgusWorkContractTests.fixture(relation: "unknown", preArtifact: true)
        try work.validate(for: item)
        let root = VStack(alignment: .leading, spacing: 12) {
            Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
            ArgusOperationEvidenceContent(
                detail: .init(
                    item: item,
                    requested: item,
                    timeline: [],
                    coverage: .init(complete: false, hasMore: true, observedAt: item.observedAt),
                    ownerAccepted: false,
                    workContract: work),
                artifactsAvailable: true, openArtifact: { _, _ in })
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
        .environment(\.colorScheme, .dark)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        let image = try self.hostedImage(root, requiredText: ["No artifact is recorded yet", "Verification and scope"])
        let attachment = XCTAttachment(image: image)
        attachment.name = "argus-work-simulator-fixture-running-no-artifact"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    @MainActor
    func testProductionOwnerRequestAndFailureRemainVisibleWithoutOpeningDisclosure() throws {
        let (item, original) = try ArgusWorkContractTests.fixture()
        let work = ArgusWorkContract(
            schema: original.schema, operationId: original.operationId, latestEventId: original.latestEventId,
            canonicalState: original.canonicalState,
            structuralVerification: .init(
                status: "failed_recorded",
                semanticCorrectnessEstablished: false,
                coversAllCurrentArtifacts: false),
            independentVerification: original.independentVerification,
            pendingOwnerFeedback: [.init(eventId: "fixture-request", reason: "Choose the next validation target.")],
            continuation: original.continuation, coverage: original.coverage, ownerAccepted: false,
            isStateTransition: false)
        try work.validate(for: item)
        let root = ArgusOperationEvidenceContent(
            detail: .init(
                item: item,
                requested: item,
                timeline: [],
                coverage: .init(complete: true, hasMore: false, observedAt: item.observedAt),
                ownerAccepted: false,
                workContract: work),
            artifactsAvailable: true, openArtifact: { _, _ in })
            .padding()
            .background(Color(uiColor: .systemBackground))
            .environment(\.dynamicTypeSize, .accessibility1)
            .environment(\.colorScheme, .dark)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
        let image = try self.hostedImage(root, requiredText: [
            "Choose the next validation target", "Structural check failed", "Verification and scope",
        ])
        let attachment = XCTAttachment(image: image)
        attachment.name = "argus-detail-simulator-fixture-owner-request-failure-accessibility"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    @MainActor
    func testProductionRecordedReviewHistoryAtAccessibilitySize() throws {
        let (item, payload) = try ArgusOperationsTests.reviewHistoryFixture()
        let history = try ArgusOperationsTests.decodeReviewHistory(payload)
        try history.validate(for: item)
        let root = VStack(alignment: .leading, spacing: 12) {
            Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
            ArgusReviewHistorySummary(history: history)
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
        .environment(\.dynamicTypeSize, .accessibility1)
        .environment(\.colorScheme, .dark)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 400)
        let attachment = XCTAttachment(image: image)
        attachment.name = "argus-recorded-review-history-simulator-fixture-accessibility"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    @MainActor
    func testProductionMiKobotsProjectScope() throws {
        let store = ArgusOperationsStore()
        store.selectGateway("simulator-fixture")
        store.selectProject(.miKobots)
        let item = ArgusOperation(
            operationId: "fixture-mikobots", taskId: "fixture-task", eventId: "fixture-event",
            title: "Synthetic MiKobots technical observation", source: "federation:simulator-fixture",
            project: "MiKobots", kind: "test fixture", state: "observed",
            occurredAt: "2026-09-07T00:00:00Z", observedAt: "2026-09-07T00:01:00Z",
            artifacts: [], supersedesEventId: nil, ownerAccepted: false)
        try store.accept(ArgusOperationsPage(
            items: [item],
            coverage: .init(
                complete: true,
                hasMore: false,
                observedAt: item.observedAt),
            nextCursor: nil,
            automaticDispatchEnabled: false), more: false)
        let root = VStack(alignment: .leading, spacing: 12) {
            Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
            ArgusOperationsContent(store: store, client: nil)
        }
        .padding(.top)
        .background(Color(uiColor: .systemBackground))
        .environment(\.dynamicTypeSize, .accessibility1)
        .environment(\.colorScheme, .dark)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        let image = try self.hostedImage(root, selectedProject: store.project.rawValue)
        XCTAssertGreaterThan(image.size.height, 400)
        let attachment = XCTAttachment(image: image)
        attachment.name = "argus-mikobots-project-simulator-fixture-accessibility"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    @MainActor
    func testProductionNamedArtifactLabels() throws {
        let artifacts = [
            ArgusOperation.Artifact(
                sha256: String(repeating: "a", count: 64),
                bytes: 47,
                displayName: "review.json"),
            ArgusOperation.Artifact(
                sha256: String(repeating: "b", count: 64),
                bytes: 93,
                displayName: "validation.txt"),
        ]
        XCTAssertNotEqual(artifacts[0].id, artifacts[1].id)
        let root = VStack(alignment: .leading, spacing: 20) {
            Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
            Text("Artifact evidence").font(.headline)
            ForEach(artifacts) { artifact in
                Button {} label: {
                    ArgusArtifactButtonLabel(artifact: artifact, operationLabel: "Run output")
                }
            }
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
        .environment(\.dynamicTypeSize, .accessibility1)
        .environment(\.colorScheme, .dark)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        let image = try self.hostedImage(root, artifactNames: ["review.json", "validation.txt"])
        let attachment = XCTAttachment(image: image)
        attachment.name = "argus-named-artifact-labels-simulator-fixture-accessibility"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    /// ImageRenderer replaces UIKit-backed menu controls with placeholders. Keep the
    /// production control and capture its real hosted view hierarchy instead.
    @MainActor
    private func hostedImage(
        _ content: some View, selectedProject: String? = nil, artifactNames: [String] = [],
        requiredText: [String] = [], forbiddenText: [String] = []) throws -> UIImage
    {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = .dark
        let window = UIWindow(windowScene: scene)
        let container = ScreenshotContainerController()
        window.rootViewController = container
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 4000))
        XCTAssertTrue(size.height.isFinite && size.height > 0 && size.height < 4000)
        guard size.height.isFinite, size.height > 0, size.height < 4000 else {
            throw NSError(domain: "ArgusScreenshot", code: 1)
        }
        window.frame = CGRect(origin: .zero, size: CGSize(width: 390, height: ceil(size.height)))
        window.makeKeyAndVisible()
        // Own child appearance synchronously. A temporary window can otherwise
        // defer its root's appearance until after this capture has torn it down,
        // leaving NavigationStack with overlapping appearance transitions.
        container.addChild(host)
        host.beginAppearanceTransition(true, animated: false)
        host.view.frame = window.bounds
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        host.endAppearanceTransition()
        defer {
            host.willMove(toParent: nil)
            host.beginAppearanceTransition(false, animated: false)
            host.view.removeFromSuperview()
            host.endAppearanceTransition()
            host.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        XCTAssertTrue(host.view.window === window)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered, "The complete UIKit hierarchy must render")
        let cgImage = try XCTUnwrap(image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.customWords = selectedProject.map { [$0] } ?? artifactNames
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let words = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox)
        }
        // Card text alone must not satisfy the menu assertion: the selected project
        // must be visible ABOVE the observation timestamp, where the control lives.
        if let selectedProject {
            let timestamp = try XCTUnwrap(words.first { $0.0.hasPrefix("List checked:") })
            let aboveTimestamp = words.filter { $0.1.minY > timestamp.1.maxY }
            XCTAssertTrue(
                aboveTimestamp.contains {
                    Self.containsProjectLabel($0.0, project: selectedProject)
                },
                "The selected project menu label must be visible above the timestamp; fixture OCR: " +
                    aboveTimestamp.prefix(12).map { String($0.0.prefix(160)) }.joined(separator: " | "))
        }
        for name in artifactNames {
            XCTAssertTrue(
                words.contains { Self.containsProjectLabel($0.0, project: name) },
                "Each corresponding artifact filename must render: \(name)")
        }
        let renderedText = words.map(\.0).joined(separator: " ")
        for phrase in requiredText {
            XCTAssertTrue(
                renderedText.localizedCaseInsensitiveContains(phrase),
                "The production detail must visibly render: \(phrase)")
        }
        for phrase in forbiddenText {
            XCTAssertFalse(
                renderedText.localizedCaseInsensitiveContains(phrase),
                "The production view must not display a contradictory state: \(phrase)")
        }
        return image
    }

    private static func containsProjectLabel(_ text: String, project: String) -> Bool {
        // OCR may include the adjacent menu chevrons in the same text observation.
        // Preserve a complete project token, never a prefix of another project name.
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: project) + "(?![A-Za-z0-9])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func testMenuOCRRequiresCompleteProjectToken() {
        XCTAssertTrue(Self.containsProjectLabel("Argus", project: "Argus"))
        XCTAssertTrue(Self.containsProjectLabel("MiKobots ⌃⌄", project: "MiKobots"))
        XCTAssertTrue(Self.containsProjectLabel("Argus v", project: "Argus"))
        XCTAssertFalse(Self.containsProjectLabel("MiKobotsOther", project: "MiKobots"))
        XCTAssertFalse(Self.containsProjectLabel("NotArgus", project: "Argus"))
        XCTAssertFalse(Self.containsProjectLabel("EPC", project: "Argus"))
        XCTAssertFalse(Self.containsProjectLabel("🚫", project: "Argus"))
    }
}

/// The screenshot helper forwards each child appearance transition explicitly;
/// the window's deferred root lifecycle must not forward it a second time.
@MainActor
private final class ScreenshotContainerController: UIViewController {
    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
}
