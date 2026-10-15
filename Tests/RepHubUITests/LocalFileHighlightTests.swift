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
    func previewKeepsAStableCodeLineHeightAcrossCRLFEmptyAndEmojiLines() {
        let source = "首行\r\n\n😀 emoji\n末行\n"
        let font = CodeTextLayout.font
        let rendered = LocalFilePreviewView.highlightedAttributedString(
            text: source,
            tokens: SyntaxHighlighting.tokenize(source, language: .swift),
            palette: palette(keyword: .red),
            font: font
        )
        let storage = NSTextStorage(attributedString: rendered)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 2_000, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let index = CodeLineIndex(source)
        let lineOrigins = index.starts.dropLast().map { start -> CGFloat in
            let glyph = layout.glyphIndexForCharacter(at: start)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        let paragraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        #expect(rendered.string == source)
        #expect(paragraph?.minimumLineHeight == CodeTextLayout.lineHeight)
        #expect(paragraph?.maximumLineHeight == CodeTextLayout.lineHeight)
        #expect(lineOrigins.count == 4)
        #expect(abs(lineOrigins[1] - lineOrigins[0] - CodeTextLayout.lineHeight) < 0.01)
        #expect(abs(lineOrigins[2] - lineOrigins[1] - CodeTextLayout.lineHeight) < 0.01)
        #expect(abs(lineOrigins[3] - lineOrigins[2] - CodeTextLayout.lineHeight) < 0.01)
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
