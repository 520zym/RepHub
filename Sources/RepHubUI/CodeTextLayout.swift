import AppKit

/// 代码预览和可编辑区域共享的排版约束。
///
/// 显式指定行高可避免 AppKit 根据中文、Emoji 或字体回退改变单行高度，
/// 让代码正文、空行与左侧行号保持稳定节奏。
enum CodeTextLayout {
    static let fontSize: CGFloat = 13
    static let lineHeight: CGFloat = 24

    static var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineHeightMultiple = 1
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style.copy() as! NSParagraphStyle
    }

    static func attributes(font: NSFont = CodeTextLayout.font,
                           foreground: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: foreground,
            .paragraphStyle: paragraphStyle()
        ]
    }

    static func applyBaseAttributes(to storage: NSTextStorage,
                                    font: NSFont = CodeTextLayout.font,
                                    foreground: NSColor) {
        guard storage.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(attributes(font: font, foreground: foreground),
                              range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }
}
