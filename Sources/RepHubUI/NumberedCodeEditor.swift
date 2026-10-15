import AppKit
import SwiftUI
import DesignSystem

/// 可编辑的纯文本代码区。行号是独立的 ruler，不属于文本内容，复制和撤销都只作用于代码。
struct NumberedCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let palette: CodePalette
    let isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = Self.makeTextView(delegate: context.coordinator)
        scrollView.documentView = textView
        scrollView.verticalRulerView = CodeLineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.hasHorizontalRuler = false
        scrollView.rulersVisible = true
        update(textView: textView, scrollView: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    /// 维持 AppKit 原生响应链和窗口撤销栈；不可用私有 UndoManager 替代，
    /// 否则文本系统录入的撤销动作不会进入 Edit 菜单。
    static func makeTextView(delegate: NSTextViewDelegate?) -> NSTextView {
        let textView = NSTextView()
        let font = CodeTextLayout.font
        textView.delegate = delegate
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 14)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = font
        textView.typingAttributes = CodeTextLayout.attributes(font: font, foreground: .labelColor)
        return textView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView: textView, scrollView: scrollView, coordinator: context.coordinator)
    }

    private func update(textView: NSTextView, scrollView: NSScrollView, coordinator: Coordinator) {
        let font = CodeTextLayout.font
        let foreground = NSColor(palette.foreground)
        let background = NSColor(palette.background)
        let hasMarkedText = textView.hasMarkedText()
        let textChanged = textView.string != text
        let replacesModelText = textChanged && !hasMarkedText
        if textChanged && hasMarkedText {
            // 输入法组合期间绝不替换全文；等候本次组合提交后再应用“采用某一版本”等模型更新。
            coordinator.synchronizer.receivedModelText(text, whileMarked: true)
        } else if replacesModelText {
            // 仅模型替换（例如“采用本地版本”）会重设全文；用户输入由 delegate 回写 binding，
            // 因而不会在输入法组合或撤销过程中被 SwiftUI 反向覆盖。
            coordinator.isApplyingModelText = true
            textView.undoManager?.removeAllActions(withTarget: textView)
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: text,
                attributes: CodeTextLayout.attributes(font: font, foreground: foreground)
            ))
            textView.undoManager?.removeAllActions(withTarget: textView)
            coordinator.isApplyingModelText = false
            Self.resize(textView: textView, in: scrollView)
        } else if coordinator.themeChanged(palette: palette) {
            let storage = textView.textStorage
            if let storage, storage.length > 0 {
                storage.addAttributes(
                    CodeTextLayout.attributes(font: font, foreground: foreground),
                    range: NSRange(location: 0, length: storage.length)
                )
            }
        }

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = font
        textView.typingAttributes = CodeTextLayout.attributes(font: font, foreground: foreground)
        textView.backgroundColor = background
        textView.insertionPointColor = foreground
        textView.selectedTextAttributes = [.backgroundColor: NSColor(palette.selection), .foregroundColor: foreground]
        scrollView.backgroundColor = background
        (scrollView.verticalRulerView as? CodeLineNumberRuler)?.update(
            text: replacesModelText ? text : nil, palette: palette, font: font
        )
        coordinator.latestPalette = palette
        coordinator.synchronizer.receivedModelText(text, whileMarked: false)
        coordinator.updateTheme(palette: palette)
    }

    private static func resize(textView: NSTextView, in scrollView: NSScrollView) {
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
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var isApplyingModelText = false
        var latestPalette: CodePalette?
        var synchronizer = NumberedCodeEditorSynchronizer()
        private var colorSignature: [NSColor]?

        init(text: Binding<String>) { _text = text }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingModelText,
                  let textView = notification.object as? NSTextView else { return }
            if textView.hasMarkedText() { return }
            let edited = textView.string
            if let pendingModelText = synchronizer.committedMarkedText() {
                applyModelText(pendingModelText, to: textView)
                if text != pendingModelText { text = pendingModelText }
                return
            }
            guard text != edited else { return }
            text = edited
            if let scrollView = textView.enclosingScrollView, let palette = latestPalette {
                let font = CodeTextLayout.font
                (scrollView.verticalRulerView as? CodeLineNumberRuler)?.update(
                    text: edited,
                    palette: palette,
                    font: font
                )
                NumberedCodeEditor.resize(textView: textView, in: scrollView)
            }
        }

        private func applyModelText(_ modelText: String, to textView: NSTextView) {
            guard let scrollView = textView.enclosingScrollView, let palette = latestPalette else { return }
            let font = CodeTextLayout.font
            isApplyingModelText = true
            textView.undoManager?.removeAllActions(withTarget: textView)
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: modelText,
                attributes: CodeTextLayout.attributes(font: font, foreground: NSColor(palette.foreground))
            ))
            textView.undoManager?.removeAllActions(withTarget: textView)
            textView.setSelectedRange(NSRange(location: min(textView.selectedRange().location, (modelText as NSString).length), length: 0))
            (scrollView.verticalRulerView as? CodeLineNumberRuler)?.update(text: modelText, palette: palette, font: font)
            NumberedCodeEditor.resize(textView: textView, in: scrollView)
            isApplyingModelText = false
        }

        func themeChanged(palette: CodePalette) -> Bool {
            let next = Self.signature(for: palette)
            return colorSignature?.count != next.count || !zip(colorSignature ?? [], next).allSatisfy { $0.isEqual($1) }
        }

        func updateTheme(palette: CodePalette) { colorSignature = Self.signature(for: palette) }

        private static func signature(for palette: CodePalette) -> [NSColor] {
            [palette.foreground, palette.background, palette.selection, palette.lineNumber].map(NSColor.init)
        }
    }
}

/// 区分输入法组合期间的本地临时文本与真正来自模型的替换。
/// 仅在模型值自上次渲染后发生变化时才排队，避免普通 SwiftUI 刷新误把旧值覆盖为待应用内容。
struct NumberedCodeEditorSynchronizer {
    private(set) var lastModelText: String?
    private(set) var pendingModelText: String?

    mutating func receivedModelText(_ text: String, whileMarked: Bool) {
        defer { lastModelText = text }
        guard whileMarked, let lastModelText, lastModelText != text else { return }
        pendingModelText = text
    }

    mutating func committedMarkedText() -> String? {
        defer { pendingModelText = nil }
        return pendingModelText
    }
}
