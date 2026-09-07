import SwiftUI
import UIKit
import XCTest
@testable import OpenClaw

final class ArgusOperationsScreenshotTests: XCTestCase {
    @MainActor
    func testProductionEvidenceCardsAtStandardAndAccessibilitySizes() throws {
        let store = ArgusOperationsStore()
        store.selectGateway("simulator-fixture")
        let item = ArgusOperation(
            operationId: "fixture-operation", taskId: "fixture-task", eventId: "fixture-event",
            title: "Synthetic result: checkpoint retry verified",
            source: "federation:fixture-simulator", project: "Argus", kind: "test fixture", state: "observed",
            occurredAt: "2026-09-06T00:00:00Z", observedAt: "2026-09-06T00:01:00Z",
            artifacts: [], supersedesEventId: nil, ownerAccepted: false)
        try store.accept(ArgusOperationsPage(
            items: [item],
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
            let renderer = ImageRenderer(content: root)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
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
        let (item, work) = try ArgusWorkContractTests.fixture(relation: "previous_attempt")
        try work.validate(for: item)
        let root = VStack(alignment: .leading, spacing: 12) {
            Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
            ArgusWorkSummary(work: work, artifactContext: item.artifactContext)
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
        XCTAssertGreaterThan(image.size.height, 300)
        let attachment = XCTAttachment(image: image)
        attachment.name = "argus-work-simulator-fixture-previous-attempt-accessibility"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    @MainActor
    func testProductionRunningBeforeFirstArtifactSummary() throws {
        let (item, work) = try ArgusWorkContractTests.fixture(relation: "unknown", preArtifact: true)
        try work.validate(for: item)
        let root = VStack(alignment: .leading, spacing: 12) {
            Text("SIMULATOR FIXTURE — NOT LIVE EVIDENCE").font(.caption.bold())
            ArgusWorkSummary(work: work, artifactContext: item.artifactContext)
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
        .environment(\.colorScheme, .dark)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 200)
        let attachment = XCTAttachment(image: image)
        attachment.name = "argus-work-simulator-fixture-running-no-artifact"
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
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 400)
        let attachment = XCTAttachment(image: image)
        attachment.name = "argus-mikobots-project-simulator-fixture-accessibility"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

}
