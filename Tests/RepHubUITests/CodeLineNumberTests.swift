import AppKit
import DesignSystem
import SwiftUI
import Testing
@testable import RepHubUI

struct CodeLineIndexTests {
    @Test func emptyAndTrailingLinesRemainAddressable() {
        #expect(CodeLineIndex("").starts == [0])
        #expect(CodeLineIndex("first\n\nlast\n").starts == [0, 6, 7, 12])
    }

    @Test func unicodeOffsetsMatchAppKitAndMixedLineEndings() {
        let index = CodeLineIndex("中文😀\r\n\rnext\nend\u{2028}last\u{2029}")
        #expect(index.starts == [0, 6, 7, 12, 16, 21])
        #expect(index.line(containingUTF16: 3) == 0)
        #expect(index.line(containingUTF16: 5) == 0)
        #expect(index.line(containingUTF16: 6) == 1)
        #expect(index.line(containingUTF16: 21) == 5)
    }

    @Test func deepScrollFindsTheCorrectLine() {
        let index = CodeLineIndex(String(repeating: "abcdef\n", count: 20_000))
        #expect(index.count == 20_001)
        #expect(index.line(containingUTF16: 98_003) == 14_000)
        #expect(index.line(containingUTF16: 140_000) == 20_000)
    }
}

@MainActor
struct CodeLineNumberRulerTests {
    @Test func labelBaselinesFollowStableLayoutForEmptyAndTrailingLines() {
        let source = "首\r\n\n😀\n尾\n"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 1_200, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: source,
            attributes: CodeTextLayout.attributes(foreground: .labelColor)
        ))
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            Issue.record("缺少 AppKit 文本布局对象")
            return
        }
        layout.ensureLayout(for: container)
        let index = CodeLineIndex(source)
        let positions = index.starts.compactMap {
            CodeLineNumberRuler.labelTop(
                forLineStart: $0,
                textLength: (source as NSString).length,
                layoutManager: layout,
                textContainer: container,
                textOrigin: textView.textContainerOrigin,
                font: CodeTextLayout.font
            )
        }

        #expect(positions.count == 5)
        #expect(abs(positions[1] - positions[0] - CodeTextLayout.lineHeight) < 0.01)
        #expect(abs(positions[2] - positions[1] - CodeTextLayout.lineHeight) < 0.01)
        #expect(abs(positions[3] - positions[2] - CodeTextLayout.lineHeight) < 0.01)
        #expect(abs(positions[4] - positions[3] - CodeTextLayout.lineHeight) < 0.01)
    }

    @Test func wideningAndRecoloringPreserveTextSelectionAndScroll() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 1200, height: 2000))
        let source = "中文😀\n\nlast\n"
        textView.string = source
        scroll.documentView = textView
        let ruler = CodeLineNumberRuler(scrollView: scroll, textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ruler.update(text: source, palette: palette(.gray), font: font)
        let shortWidth = ruler.ruleThickness
        #expect(ruler.lineIndex.count == 4)
        ruler.update(text: String(repeating: "x\n", count: 100_000), palette: palette(.gray), font: font)
        #expect(ruler.ruleThickness > shortWidth)
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 200))
        let origin = scroll.contentView.bounds.origin
        ruler.update(text: nil, palette: palette(.blue), font: font)
        #expect(textView.string == source)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 4))
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(ruler.lineIndex.count == 100_001)
    }

    private func palette(_ number: Color) -> CodePalette {
        CodePalette(background: .white, foreground: .black, secondary: .gray, lineNumber: number,
                    keyword: .blue, string: .orange, comment: .green, type: .purple, number: .pink,
                    addedBackground: .green.opacity(0.12), removedBackground: .red.opacity(0.12),
                    addedForeground: .green, removedForeground: .red, selection: .blue.opacity(0.2), isDark: false)
    }
}
