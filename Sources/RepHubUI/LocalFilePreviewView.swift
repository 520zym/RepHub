import AppKit
import SwiftUI
import DesignSystem

/// 使用 AppKit 文本系统显示有界的只读文件内容，避免 SwiftUI `Text` 对大型文件逐行构建视图。
///
/// 分词在后台完成；主线程只将已经定位的 token 颜色应用到 `NSTextStorage`，因此主题切换不需要再次分词。
struct LocalFilePreviewView: NSViewRepresentable {
    /// 比工作区文件读取上限更保守。超出时仍完整显示已读取的内容，只不进行语法着色，避免主线程应用大量属性造成停顿。
    static let syntaxHighlightLimit = 512 * 1_024

    let text: String
    let palette: CodePalette
    let language: SyntaxHighlighting.Language

    init(text: String, palette: CodePalette, language: SyntaxHighlighting.Language = .plain) {
        self.text = text
        self.palette = palette
        self.language = language
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.usesFindPanel = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 14)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        scrollView.verticalRulerView = CodeLineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.hasHorizontalRuler = false
        scrollView.rulersVisible = true
        update(textView: textView, scrollView: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView: textView, scrollView: scrollView, coordinator: context.coordinator)
    }

    private func update(textView: NSTextView, scrollView: NSScrollView, coordinator: Coordinator) {
        let font = CodeTextLayout.font
        coordinator.latestPalette = palette
        let foreground = NSColor(palette.foreground)
        let background = NSColor(palette.background)
        let selection = NSColor(palette.selection)
        let textChanged = coordinator.lastText != text
        let languageChanged = coordinator.lastLanguage != language
        let themeChanged = !coordinator.matchesTheme(palette: palette)

        if textChanged {
            coordinator.cancelHighlighting()
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: text,
                attributes: CodeTextLayout.attributes(font: font, foreground: foreground)
            ))
            coordinator.lastText = text
            coordinator.lastLanguage = language
            coordinator.cachedTokens = nil
            resize(textView: textView, in: scrollView)
        }

        if textChanged || languageChanged {
            if languageChanged, !textChanged {
                coordinator.cancelHighlighting()
                coordinator.lastLanguage = language
                coordinator.cachedTokens = nil
                applyBaseAttributes(to: textView, font: font, foreground: foreground)
            }
            coordinator.scheduleHighlighting(
                text: text,
                language: language,
                palette: palette,
                font: font,
                textView: textView,
                scrollView: scrollView
            )
        } else if themeChanged {
            if let tokens = coordinator.cachedTokens {
                Self.apply(tokens: tokens, to: textView, scrollView: scrollView, palette: palette, font: font)
            } else {
                applyBaseAttributes(to: textView, font: font, foreground: foreground)
            }
        }

        if textChanged || languageChanged || themeChanged {
            (scrollView.verticalRulerView as? CodeLineNumberRuler)?.update(
                text: textChanged ? text : nil, palette: palette, font: font
            )
            scrollView.backgroundColor = background
            textView.backgroundColor = background
            textView.insertionPointColor = foreground
            textView.selectedTextAttributes = [.backgroundColor: selection, .foregroundColor: foreground]
            coordinator.updateTheme(palette: palette)
        }
    }

    private func applyBaseAttributes(to textView: NSTextView, font: NSFont, foreground: NSColor) {
        guard let storage = textView.textStorage else { return }
        CodeTextLayout.applyBaseAttributes(to: storage, font: font, foreground: foreground)
    }

    /// 建立着色属性供 AppKit 预览和测试共同使用；token 与原文不一致时安全地退回未着色文本。
    static func highlightedAttributedString(text: String,
                                            tokens: [[SyntaxHighlighting.Token]],
                                            palette: CodePalette,
                                            font: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: text,
            attributes: CodeTextLayout.attributes(font: font, foreground: NSColor(palette.foreground))
        )
        let rebuilt = tokens.map { $0.map(\.value).joined() }.joined(separator: "\n")
        guard rebuilt == text else { return output }
        let source = text as NSString
        var cursor = 0
        for (lineIndex, line) in tokens.enumerated() {
            for token in line {
                let length = (token.value as NSString).length
                guard length > 0 else { continue }
                guard cursor + length <= source.length else { return output }
                output.addAttributes(
                    [.font: font,
                     .foregroundColor: NSColor(SyntaxHighlighting.color(for: token.kind, palette: palette))],
                    range: NSRange(location: cursor, length: length)
                )
                cursor += length
            }
            if lineIndex < tokens.count - 1 { cursor += 1 }
        }
        return output
    }

    /// 只覆盖字体和前景色，不替换字符串，避免因主题变化丢失选择范围或滚动位置。
    static func apply(tokens: [[SyntaxHighlighting.Token]],
                              to textView: NSTextView,
                              scrollView: NSScrollView,
                              palette: CodePalette,
                              font: NSFont) {
        guard let storage = textView.textStorage else { return }
        let selectedRanges = textView.selectedRanges
        let visibleOrigin = scrollView.contentView.bounds.origin
        let source = storage.string as NSString
        let allRange = NSRange(location: 0, length: source.length)
        let rendered = highlightedAttributedString(text: storage.string, tokens: tokens, palette: palette, font: font)
        storage.beginEditing()
        rendered.enumerateAttributes(in: allRange, options: []) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        textView.selectedRanges = selectedRanges.compactMap { range in
            let clipped = NSIntersectionRange(range.rangeValue, allRange)
            return clipped.length > 0 || clipped.location <= allRange.length ? NSValue(range: clipped) : nil
        }
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func resize(textView: NSTextView, in scrollView: NSScrollView) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let inset = textView.textContainerInset
        let viewport = scrollView.contentView.bounds.size
        textView.setFrameSize(NSSize(
            width: max(viewport.width, ceil(used.width) + inset.width * 2),
            height: max(viewport.height, ceil(used.height) + inset.height * 2)
        ))
    }

    @MainActor
    final class Coordinator {
        var lastText: String?
        var lastLanguage: SyntaxHighlighting.Language?
        var cachedTokens: [[SyntaxHighlighting.Token]]?
        var latestPalette: CodePalette?
        private var colorSignature: [NSColor]?
        private var highlightTask: Task<Void, Never>?
        private var generation = 0

        deinit { highlightTask?.cancel() }

        func cancelHighlighting() {
            generation &+= 1
            highlightTask?.cancel()
            highlightTask = nil
        }

        func scheduleHighlighting(text: String,
                                  language: SyntaxHighlighting.Language,
                                  palette: CodePalette,
                                  font: NSFont,
                                  textView: NSTextView,
                                  scrollView: NSScrollView) {
            cancelHighlighting()
            guard text.utf8.count <= LocalFilePreviewView.syntaxHighlightLimit, language != .plain else { return }
            let requestGeneration = generation
            highlightTask = Task { [weak self, text, language, font, weak textView, weak scrollView] in
                let tokens = await Task.detached(priority: .userInitiated) {
                    SyntaxHighlighting.tokenize(text, language: language)
                }.value
                guard let self, let textView, let scrollView, let palette = self.latestPalette,
                      self.generation == requestGeneration,
                      self.lastText == text,
                      self.lastLanguage == language,
                      !Task.isCancelled else { return }
                self.cachedTokens = tokens
                LocalFilePreviewView.apply(tokens: tokens, to: textView, scrollView: scrollView, palette: palette, font: font)
                self.highlightTask = nil
            }
        }

        func matchesTheme(palette: CodePalette) -> Bool {
            let latest = Self.signature(for: palette)
            return colorSignature?.count == latest.count && zip(colorSignature ?? [], latest).allSatisfy { $0.isEqual($1) }
        }

        func updateTheme(palette: CodePalette) {
            colorSignature = Self.signature(for: palette)
        }

        private static func signature(for palette: CodePalette) -> [NSColor] {
            [palette.foreground, palette.background, palette.selection, palette.keyword,
             palette.string, palette.comment, palette.type, palette.number, palette.lineNumber].map(NSColor.init)
        }
    }
}
