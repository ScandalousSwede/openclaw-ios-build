import SwiftUI
import UIKit
import Vision
import XCTest
@testable import OpenClaw

final class ArgusOperationsScreenshotTests: XCTestCase {
    @MainActor
    func testProductionEvidenceCardsAtStandardAndAccessibilitySizes() throws {
        let store = ArgusOperationsStore()
        store.selectGateway("simulator-fixture")
        var item = ArgusOperation(
            operationId: "fixture-operation", taskId: "fixture-task", eventId: "fixture-event",
            title: "Synthetic result: checkpoint retry verified",
            source: "federation:fixture-simulator", project: "Argus", kind: "test fixture", state: "observed",
            occurredAt: "2026-09-06T00:00:00Z", observedAt: "2026-09-06T00:01:00Z",
            artifacts: [], supersedesEventId: nil, ownerAccepted: false)
        item.display = .init(label: "Checkpoint retry repaired",
            changeSummary: "A retry now resumes the recorded batch. The validation artifact is available in detail.",
            artifactLabel: nil, continuationLabel: nil)
        let earlier = ArgusOperation(
            operationId: "fixture-earlier", taskId: "fixture-earlier-task", eventId: "fixture-earlier-event",
            title: "Synthetic unfamiliar producer observation with a long title that must remain readable and available in full.",
            source: "federation:fixture-simulator", project: "Argus", kind: "test fixture", state: "observed",
            occurredAt: "2026-09-06T00:00:00Z", observedAt: "2026-09-06T00:00:30Z",
            artifacts: [], supersedesEventId: "fixture-previous-event", ownerAccepted: false)
        try store.accept(ArgusOperationsPage(
            items: [item, earlier],
            coverage: ArgusOperationsCoverage(complete: true, hasMore: false, observedAt: item.observedAt),
            nextCursor: nil, automaticDispatchEnabled: false), more: false)

        for (name, size) in [("standard", DynamicTypeSize.large), ("offline-accessibility", .accessibility1)] {
            if name == "offline-accessibility" { store.markUnavailable() }
            let root = VStack(alignment: .leading, spacing: 12) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE")
                    .font(.caption.bold()).padding(.horizontal)
                ArgusOperationsContent(store: store, client: nil)
            }
            .padding(.top)
            .background(Color(uiColor: .systemBackground))
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            let image = try self.hostedImage(root, selectedProject: store.project.rawValue)
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
                    if brightness > 180 { brightPixels += 1 }
                    if brightness < 60 { darkPixels += 1 }
                }
                return brightPixels > 100 && darkPixels > 100
            }
            XCTAssertTrue(hasVisibleContent, "Evidence below the fixture label must have visible text/background contrast")
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
            if relation == "missing" { item.artifactContext = nil }
            try work.validate(for: item)
            let root = VStack(alignment: .leading, spacing: 12) {
                Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
                ArgusOperationEvidenceContent(
                    detail: .init(item: item, requested: item, timeline: [],
                        coverage: .init(complete: false, hasMore: true, observedAt: item.observedAt),
                        ownerAccepted: false, workContract: work),
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
                detail: .init(item: item, requested: item, timeline: [],
                    coverage: .init(complete: false, hasMore: true, observedAt: item.observedAt),
                    ownerAccepted: false, workContract: work),
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
            structuralVerification: .init(status: "failed_recorded", semanticCorrectnessEstablished: false,
                                          coversAllCurrentArtifacts: false),
            independentVerification: original.independentVerification,
            pendingOwnerFeedback: [.init(eventId: "fixture-request", reason: "Choose the next validation target.")],
            continuation: original.continuation, coverage: original.coverage, ownerAccepted: false, isStateTransition: false)
        try work.validate(for: item)
        let root = ArgusOperationEvidenceContent(
            detail: .init(item: item, requested: item, timeline: [],
                coverage: .init(complete: true, hasMore: false, observedAt: item.observedAt),
                ownerAccepted: false, workContract: work),
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
        try store.accept(ArgusOperationsPage(items: [item],
            coverage: .init(complete: true, hasMore: false, observedAt: item.observedAt),
            nextCursor: nil, automaticDispatchEnabled: false), more: false)
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
            ArgusOperation.Artifact(sha256: String(repeating: "a", count: 64), bytes: 47,
                                    displayName: "review.json"),
            ArgusOperation.Artifact(sha256: String(repeating: "b", count: 64), bytes: 93,
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
        requiredText: [String] = []) throws -> UIImage
    {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = .dark
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 4000))
        XCTAssertTrue(size.height.isFinite && size.height > 0 && size.height < 4000)
        guard size.height.isFinite, size.height > 0, size.height < 4000 else {
            throw NSError(domain: "ArgusScreenshot", code: 1)
        }
        window.frame = CGRect(origin: .zero, size: CGSize(width: 390, height: ceil(size.height)))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
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
            let timestamp = try XCTUnwrap(words.first { $0.0.hasPrefix("Last observed:") })
            let aboveTimestamp = words.filter { $0.1.minY > timestamp.1.maxY }
            XCTAssertTrue(aboveTimestamp.contains {
                Self.containsProjectLabel($0.0, project: selectedProject)
            }, "The selected project menu label must be visible above the timestamp; fixture OCR: " +
                aboveTimestamp.prefix(12).map { String($0.0.prefix(160)) }.joined(separator: " | "))
        }
        for name in artifactNames {
            XCTAssertTrue(words.contains { Self.containsProjectLabel($0.0, project: name) },
                          "Each corresponding artifact filename must render: \(name)")
        }
        let renderedText = words.map(\.0).joined(separator: " ")
        for phrase in requiredText {
            XCTAssertTrue(renderedText.localizedCaseInsensitiveContains(phrase),
                          "The production detail must visibly render: \(phrase)")
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
