import AppKit
import SwiftUI
import DesignSystem

/// 使用 AppKit 文本系统显示有界的只读文件内容，避免 SwiftUI `Text` 对大型文件逐行构建视图。
struct LocalFilePreviewView: NSViewRepresentable {
    let text: String
    let palette: CodePalette

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
        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        update(textView: textView, scrollView: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView: textView, scrollView: scrollView, coordinator: context.coordinator)
    }

    private func update(textView: NSTextView, scrollView: NSScrollView, coordinator: Coordinator) {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let foreground = NSColor(palette.foreground)
        let background = NSColor(palette.background)
        let selection = NSColor(palette.selection)
        let textChanged = coordinator.lastText != text
        let themeChanged = !coordinator.matchesTheme(foreground: foreground, background: background, selection: selection)
        if textChanged {
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: foreground]
            ))
            coordinator.lastText = text
            resize(textView: textView, in: scrollView)
        } else if themeChanged {
            textView.textStorage?.addAttributes(
                [.font: font, .foregroundColor: foreground],
                range: NSRange(location: 0, length: textView.textStorage?.length ?? 0)
            )
        }
        if textChanged || themeChanged {
            scrollView.backgroundColor = background
            textView.backgroundColor = background
            textView.insertionPointColor = foreground
            textView.selectedTextAttributes = [.backgroundColor: selection, .foregroundColor: foreground]
            coordinator.updateTheme(foreground: foreground, background: background, selection: selection)
        }
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

    final class Coordinator {
        var lastText: String?
        private var foreground: NSColor?
        private var background: NSColor?
        private var selection: NSColor?

        func matchesTheme(foreground: NSColor, background: NSColor, selection: NSColor) -> Bool {
            self.foreground?.isEqual(foreground) == true &&
            self.background?.isEqual(background) == true &&
            self.selection?.isEqual(selection) == true
        }

        func updateTheme(foreground: NSColor, background: NSColor, selection: NSColor) {
            self.foreground = foreground
            self.background = background
            self.selection = selection
        }
    }
}
