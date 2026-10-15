import AppKit
import DesignSystem

/// UTF-16 偏移与 AppKit 文本布局使用同一坐标；CRLF 只计一行，末尾空行仍可定位。
struct CodeLineIndex {
    let starts: [Int]
    var count: Int { starts.count }

    init(_ text: String) {
        var starts = [0]
        var offset = 0
        var previousWasCR = false
        for unit in text.utf16 {
            offset += 1
            if unit == 10, previousWasCR {
                starts[starts.count - 1] = offset
            } else if unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029 {
                starts.append(offset)
            }
            previousWasCR = unit == 13
        }
        self.starts = starts
    }

    /// 零基行索引。滚动时二分定位首个可见行，不从文件开头遍历。
    func line(containingUTF16 offset: Int) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, lower - 1)
    }
}

/// 原生固定行号栏，独立于文本内容；复制代码时不会带上行号。
@MainActor
final class CodeLineNumberRuler: NSRulerView {
    private(set) var lineIndex = CodeLineIndex("")
    private var numberFont = CodeTextLayout.font
    private var numberColor = NSColor.secondaryLabelColor
    private var fillColor = NSColor.textBackgroundColor

    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("代码行号")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func update(text: String?, palette: CodePalette, font: NSFont) {
        if let text { lineIndex = CodeLineIndex(text) }
        numberFont = font
        numberColor = NSColor(palette.lineNumber)
        fillColor = NSColor(palette.background)
        let digitsWidth = (String(lineIndex.count) as NSString).size(withAttributes: [.font: font]).width
        ruleThickness = max(48, ceil(digitsWidth) + 24)
        setAccessibilityValue("共 \(lineIndex.count) 行")
        needsDisplay = true
    }

    @objc private func viewportChanged(_ notification: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        fillColor.setFill()
        bounds.fill()
        // 只以淡背景区分行号栏，不绘制分隔线。
        numberColor.withAlphaComponent(0.045).setFill()
        bounds.fill()
        guard let textView = clientView as? NSTextView,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let firstLine = lineIndex.line(containingUTF16: characterRange.location)
        let lastLine = lineIndex.line(containingUTF16: NSMaxRange(characterRange))
        let length = (textView.string as NSString).length

        for index in firstLine...lastLine {
            let start = lineIndex.starts[index]
            guard let textY = Self.labelTop(forLineStart: start,
                                            textLength: length,
                                            layoutManager: layout,
                                            textContainer: container,
                                            textOrigin: origin,
                                            font: numberFont) else { continue }
            let point = convert(NSPoint(x: 0, y: textY), from: textView)
            let label = String(index + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor]
            let size = label.size(withAttributes: attributes)
            guard point.y + size.height >= rect.minY, point.y <= rect.maxY else { continue }
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: point.y), withAttributes: attributes)
        }
    }

    /// 使用文本系统给出的基线，而不是按行号或字符数估算位置。
    /// 这能同时覆盖中文、Emoji、空行和末尾换行生成的 extra line fragment。
    static func labelTop(forLineStart start: Int,
                         textLength: Int,
                         layoutManager: NSLayoutManager,
                         textContainer: NSTextContainer,
                         textOrigin: NSPoint,
                         font: NSFont) -> CGFloat? {
        let fragment: NSRect
        if start < textLength {
            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            guard glyph < layoutManager.numberOfGlyphs else { return nil }
            fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            guard layoutManager.extraLineFragmentTextContainer === textContainer else { return nil }
            fragment = layoutManager.extraLineFragmentRect
        }

        // 换行符 glyph 的位置会与普通代码字形不同，空行和末尾 extra fragment 甚至没有
        // 可用 glyph。用固定行框、默认行高和默认基线偏移来构造同一个代码基线。
        let baselineOffset = fragment.height
            - layoutManager.defaultLineHeight(for: font)
            + layoutManager.defaultBaselineOffset(for: font)
        return fragment.minY + baselineOffset - font.ascender + textOrigin.y
    }
}
