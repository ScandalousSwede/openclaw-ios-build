import SwiftUI
import UIKit
import XCTest
@testable import OpenClawChatUI

final class ChatMarkdownRenderingTests: XCTestCase {
    @MainActor
    func testManyAttributedRunsInBothChatStyles() throws {
        // One paragraph forces thousands of inline runs through Textual's TextBuilder.
        // Separate paragraphs would hide the recursive interpolation failure.
        let markdown = String(repeating: "**bold** plain ", count: 1_250)
        for variant in ChatMarkdownVariant.allCases {
            for context in [ChatMarkdownRenderer.Context.user, .assistant] {
                let image = try self.render(markdown, context: context, variant: variant)
                XCTAssertGreaterThan(image.size.width, 300)
                XCTAssertGreaterThan(image.size.height, 500)
            }
        }
    }

    @MainActor
    func testRichMarkdownProducesInspectableChatImage() throws {
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
            let image = try self.render(markdown, context: .assistant, variant: variant)
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
        variant: ChatMarkdownVariant) throws -> UIImage
    {
        let renderer = ImageRenderer(content:
            ChatMarkdownRenderer(
                text: markdown, context: context, variant: variant,
                font: .system(size: 14), textColor: .white)
                .padding(16)
                .frame(width: 390, height: 700, alignment: .topLeading)
                .clipped()
                .background(Color.black)
                .environment(\.colorScheme, .dark))
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }
}
