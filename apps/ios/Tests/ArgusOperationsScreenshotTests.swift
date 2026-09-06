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
            source: "fixture:simulator", project: "Argus", kind: "test fixture", state: "observed",
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
}
