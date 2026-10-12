import AppKit
import DesignSystem
import SwiftUI
import Testing
@testable import RepHubUI

@MainActor
struct LocalFileHighlightTests {
    @Test
    func highlightedPreviewKeepsOriginalTextIncludingEmptyLines() {
        let source = "class Flight {\n\n    let name = \"MU\"\n}\n"
        let tokens = SyntaxHighlighting.tokenize(source, language: .swift)

        let rendered = LocalFilePreviewView.highlightedAttributedString(
            text: source,
            tokens: tokens,
            palette: palette(keyword: .red),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        #expect(rendered.string == source)
    }

    @Test
    func languageChangeUsesPlainTokensUntilAFileTypeIsRecognized() {
        let source = "class Flight { }"
        let plain = SyntaxHighlighting.tokenize(source, language: .plain)
        let swift = SyntaxHighlighting.tokenize(source, language: .swift)

        #expect(plain.flatMap { $0 }.allSatisfy { $0.kind == .plain })
        #expect(swift.flatMap { $0 }.contains { $0.kind == .keyword })
    }

    @Test
    func recoloringThemeDoesNotChangePreviewContent() {
        let source = "class Flight { }"
        let tokens = SyntaxHighlighting.tokenize(source, language: .swift)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let warm = LocalFilePreviewView.highlightedAttributedString(text: source, tokens: tokens, palette: palette(keyword: .red), font: font)
        let cool = LocalFilePreviewView.highlightedAttributedString(text: source, tokens: tokens, palette: palette(keyword: .blue), font: font)
        let range = (source as NSString).range(of: "class")

        #expect(warm.string == source)
        #expect(cool.string == source)
        let warmColor = warm.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        let coolColor = cool.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        #expect(warmColor?.isEqual(coolColor) == false)
    }

    @Test
    func tokenizationCanFinishAwayFromTheMainActor() async {
        let source = "func load() async throws { return 42 }"
        let tokens = await Task.detached {
            SyntaxHighlighting.tokenize(source, language: .swift)
        }.value

        #expect(tokens.flatMap { $0 }.contains { $0.kind == .keyword })
    }

    private func palette(keyword: Color) -> CodePalette {
        CodePalette(
            background: .white,
            foreground: .black,
            secondary: .gray,
            lineNumber: .gray,
            keyword: keyword,
            string: .orange,
            comment: .green,
            type: .purple,
            number: .pink,
            addedBackground: .green.opacity(0.12),
            removedBackground: .red.opacity(0.12),
            addedForeground: .green,
            removedForeground: .red,
            selection: .blue.opacity(0.2),
            isDark: false
        )
    }
}
