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
        scrollView.autohidesScrollers = true
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
        if coordinator.lastText != text {
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: foreground]
            ))
            coordinator.lastText = text
        } else {
            textView.textStorage?.addAttributes(
                [.font: font, .foregroundColor: foreground],
                range: NSRange(location: 0, length: textView.textStorage?.length ?? 0)
            )
        }
        let background = NSColor(palette.background)
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.insertionPointColor = foreground
        textView.selectedTextAttributes = [.backgroundColor: NSColor(palette.selection), .foregroundColor: foreground]
    }

    final class Coordinator {
        var lastText: String?
    }
}
