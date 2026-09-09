import SwiftUI
import UIKit
import Vision
import XCTest
@testable import OpenClawChatUI
@testable import Textual

final class ChatMarkdownRenderingTests: XCTestCase {
    @MainActor
    func testManyAttributedRunsInBothChatStyles() async throws {
        // One paragraph forces thousands of inline runs through Textual's TextBuilder.
        // Separate paragraphs would hide the recursive interpolation failure.
        let markdown = String(repeating: "**bold** plain ", count: 1250)
        for variant in ChatMarkdownVariant.allCases {
            for context in [ChatMarkdownRenderer.Context.user, .assistant] {
                let image = try await self.render(
                    markdown,
                    context: context,
                    variant: variant,
                    expectedWords: ["bold", "plain"])
                XCTAssertGreaterThan(image.size.width, 300)
                XCTAssertGreaterThan(image.size.height, 500)
            }
        }
    }

    @MainActor
    func testLongAttributedParagraphInScrollingChat() async throws {
        // A long paragraph must remain rich text without building a linear
        // SwiftUI Text tree. Exercise the scrolling/prefetch owner as well.
        let markdown = String(repeating: "**bold** plain ", count: 16000) + " **ENDOFPARAGRAPH**"
        let image = try await self.render(
            markdown, context: .assistant, variant: .standard,
            expectedWords: ["bold", "plain"], scrolling: true, tailMarker: "endofparagraph")
        let attachment = XCTAttachment(image: image)
        attachment.name = "chat-long-rich-paragraph-scrolling-synthetic"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    func testActualTextualCompositionRetainsEveryFragmentWithBoundedDepth() throws {
        struct Fragment {
            let runs: [Int]
            let depth: Int
        }
        for count in [0, 1, 2, 3, 1025, 32000] {
            let result = balancedTextReduction((0..<count).map { Fragment(runs: [$0], depth: 0) }) {
                Fragment(runs: $0.runs + $1.runs, depth: max($0.depth, $1.depth) + 1)
            }
            if count == 0 {
                XCTAssertNil(result)
            } else {
                let combined = try XCTUnwrap(result)
                XCTAssertEqual(combined.runs, Array(0..<count))
                XCTAssertLessThanOrEqual(combined.depth, Int(ceil(log2(Double(count)))))
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
            let image = try await self.render(
                markdown,
                context: .assistant,
                variant: variant,
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
        expectedWords: [String],
        scrolling: Bool = false,
        tailMarker: String? = nil) async throws -> UIImage
    {
        // Textual uses UIKit-backed layout. ImageRenderer can return a nonnil
        // unsupported-view placeholder, so force real presentation and verify text.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let renderer = ChatMarkdownRenderer(
            text: markdown, context: context, variant: variant,
            font: .system(size: 14), textColor: .white)
        let content = Group {
            if scrolling {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        renderer
                    }
                }
            } else {
                renderer
            }
        }
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
        var deadline = clock.now.advanced(by: .seconds(scrolling ? 20 : 5))
        var words = expectedWords
        var scrolled = false
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
            request.customWords = words
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
            observedText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").lowercased()
            if rendered, words.allSatisfy({ observedText.contains($0) }) {
                if let tailMarker, !scrolled {
                    let first = XCTAttachment(image: image)
                    first.name = "chat-long-rich-paragraph-start-synthetic"
                    first.lifetime = .keepAlways
                    self.add(first)
                    let scroll = try XCTUnwrap(self.verticalScrollView(in: host.view))
                    XCTAssertGreaterThan(scroll.contentSize.height, 10000)
                    scroll.setContentOffset(
                        CGPoint(x: 0, y: max(
                            0,
                            scroll.contentSize.height - scroll.bounds
                                .height + scroll.adjustedContentInset.bottom)),
                        animated: false)
                    scrolled = true
                    words = [tailMarker]
                    deadline = clock.now.advanced(by: .seconds(20))
                    continue
                }
                return image
            }
            try await Task.sleep(for: .milliseconds(50))
        } while clock.now < deadline
        XCTFail("Hosted Chat content did not render expected fixture words: " + observedText)
        throw NSError(domain: "ChatMarkdownRenderingTests", code: 1)
    }

    @MainActor
    private func verticalScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView,
           scroll.isScrollEnabled, scroll.contentSize.height > scroll.bounds.height
        {
            return scroll
        }
        for child in view.subviews {
            if let scroll = self.verticalScrollView(in: child) {
                return scroll
            }
        }
        return nil
    }
}
