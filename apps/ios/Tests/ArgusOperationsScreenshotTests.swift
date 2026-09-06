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
                ScrollView { ArgusOperationsContent(store: store, client: nil) }
            }
            .padding(.top)
            .background(Color(uiColor: .systemBackground))
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 390, height: 844)
            let renderer = ImageRenderer(content: root)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let cgImage = try XCTUnwrap(image.cgImage)
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
                return stride(from: 0, to: bytes.count, by: 4).contains { offset in
                    bytes[offset] > 32 || bytes[offset + 1] > 32 || bytes[offset + 2] > 32
                }
            }
            XCTAssertTrue(hasVisibleContent, "The fixture must render visible content, not an empty black image")
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-home-simulator-fixture-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }
}
