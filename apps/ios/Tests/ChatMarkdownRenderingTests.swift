import SwiftUI
import UIKit
import Vision
import XCTest
@testable import OpenClawChatUI

final class ChatMarkdownRenderingTests: XCTestCase {
    @MainActor
    func testManyAttributedRunsInBothChatStyles() async throws {
        // One paragraph forces thousands of inline runs through Textual's TextBuilder.
        // Separate paragraphs would hide the recursive interpolation failure.
        let markdown = String(repeating: "**bold** plain ", count: 1_250)
        for variant in ChatMarkdownVariant.allCases {
            for context in [ChatMarkdownRenderer.Context.user, .assistant] {
                let image = try await self.render(markdown, context: context, variant: variant, expectedWords: ["bold", "plain"])
                XCTAssertGreaterThan(image.size.width, 300)
                XCTAssertGreaterThan(image.size.height, 500)
            }
        }
    }

    @MainActor
    func testRichMarkdownProducesInspectableChatImage() async throws {
        let markdown = """
        # Synthetic rendering fixture
        **Bold** and *italic* with `inline code` and [a link](https://example.com).

        > A quoted technical result.

        - First item
        - Second item

        ```swift
        let result = "verified"
        ```

        | Work | State |
        | --- | --- |
        | Synthetic fixture | Rendered |
        """
        for variant in ChatMarkdownVariant.allCases {
            let image = try await self.render(markdown, context: .assistant, variant: variant,
                                              expectedWords: ["synthetic", "quoted", "first", "verified", "rendered"])
            let attachment = XCTAttachment(image: image)
            attachment.name = "chat-markdown-simulator-fixture-\(variant.rawValue)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    @MainActor
    private func render(
        _ markdown: String,
        context: ChatMarkdownRenderer.Context,
        variant: ChatMarkdownVariant,
        expectedWords: [String]) async throws -> UIImage
    {
        // Textual uses UIKit-backed layout. ImageRenderer can return a nonnil
        // unsupported-view placeholder, so force real presentation and verify text.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let content = ChatMarkdownRenderer(
            text: markdown, context: context, variant: variant,
            font: .system(size: 14), textColor: .white)
            .padding(16)
            .frame(width: 390, height: 700, alignment: .topLeading)
            .clipped()
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = .dark
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var observedText = ""
        repeat {
            try Task.checkCancellation()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.customWords = expectedWords
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
            observedText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").lowercased()
            if rendered && expectedWords.allSatisfy({ observedText.contains($0) }) {
                return image
            }
            try await Task.sleep(for: .milliseconds(50))
        } while clock.now < deadline
        XCTFail("Hosted Chat content did not render expected fixture words: " + observedText)
        throw NSError(domain: "ChatMarkdownRenderingTests", code: 1)
    }
}
