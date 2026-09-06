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
            .preferredColorScheme(.dark)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            window.rootViewController?.view.setNeedsLayout()
            window.rootViewController?.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "argus-home-simulator-fixture-\(name)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }
}
