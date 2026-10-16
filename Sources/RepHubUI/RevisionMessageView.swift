import DesignSystem
import Foundation
import SwiftUI

/// 提交说明的轻量阅读模型。只识别提交记录中常见的段落、清单与代码围栏；
/// 无法识别的内容始终作为普通文本保留，避免为了排版而丢失原始说明。
struct RevisionMessageBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading
        case paragraph
        case unorderedList
        case orderedList
        case code(language: String, isOpenEnded: Bool)
    }

    let id: Int
    let kind: Kind
    let content: String
    /// 清单的项目结构独立保存，`content` 仍保留原始行文本供回退与测试使用。
    let listItems: [RevisionMessageListItem]

    init(id: Int, kind: Kind, content: String, listItems: [RevisionMessageListItem] = []) {
        self.id = id
        self.kind = kind
        self.content = content
        self.listItems = listItems
    }
}

struct RevisionMessageListItem: Equatable, Sendable {
    let marker: String
    let content: String
}

enum RevisionMessageInlineParser {
    enum Token: Equatable, Sendable {
        case text(String)
        case bold(String)
        case code(String)
    }

    /// 只处理提交说明常用的 `代码` 与 **强调**。不完整标记保留原文，避免阅读视图吞字。
    static func tokens(in value: String) -> [Token] {
        let characters = Array(value)
        var result: [Token] = []
        var plain = ""
        var index = 0

        func appendPlain() {
            guard !plain.isEmpty else { return }
            result.append(.text(plain))
            plain.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            if characters[index] == "`", index + 1 < characters.count,
               let close = characters[(index + 1)...].firstIndex(of: "`"), close > index + 1 {
                appendPlain()
                result.append(.code(String(characters[(index + 1)..<close])))
                index = close + 1
                continue
            }
            if characters[index] == "*", index + 1 < characters.count, characters[index + 1] == "*",
               let close = nextBoldClosingMarker(in: characters, after: index + 2), close > index + 2 {
                appendPlain()
                result.append(.bold(String(characters[(index + 2)..<close])))
                index = close + 2
                continue
            }
            plain.append(characters[index])
            index += 1
        }
        appendPlain()
        return result
    }

    private static func nextBoldClosingMarker(in characters: [Character], after start: Int) -> Int? {
        guard start < characters.count else { return nil }
        var index = start
        while index + 1 < characters.count {
            if characters[index] == "*", characters[index + 1] == "*" { return index }
            index += 1
        }
        return nil
    }
}

enum RevisionMessageParser {
    static func blocks(in message: String) -> [RevisionMessageBlock] {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [RevisionMessageBlock] = []
        var paragraph: [String] = []
        var listLines: [String] = []
        var listItems: [RevisionMessageListItem] = []
        var listKind: RevisionMessageBlock.Kind?
        var index = 0

        func append(_ kind: RevisionMessageBlock.Kind, _ content: String, listItems: [RevisionMessageListItem] = []) {
            guard !content.isEmpty else { return }
            result.append(RevisionMessageBlock(id: result.count, kind: kind, content: content, listItems: listItems))
        }

        func flushParagraph() {
            append(.paragraph, paragraph.joined(separator: "\n"))
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard let kind = listKind else { return }
            append(kind, listLines.joined(separator: "\n"), listItems: listItems)
            listLines.removeAll(keepingCapacity: true)
            listItems.removeAll(keepingCapacity: true)
            listKind = nil
        }

        while index < lines.count {
            let line = lines[index]

            if let fence = openingFence(in: line) {
                flushParagraph()
                flushList()
                index += 1
                var code: [String] = []
                var closed = false
                while index < lines.count {
                    if closesFence(lines[index], fence: fence) {
                        closed = true
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                append(.code(language: fence.language, isOpenEnded: !closed), code.joined(separator: "\n"))
                continue
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushParagraph()
                flushList()
                index += 1
                continue
            }

            if let heading = headingText(in: line) {
                flushParagraph()
                flushList()
                append(.heading, heading)
                index += 1
                continue
            }

            if let item = unorderedListItem(in: line) {
                flushParagraph()
                if listKind != .unorderedList {
                    flushList()
                    listKind = .unorderedList
                }
                listLines.append(line)
                listItems.append(item)
                index += 1
                continue
            }

            if let item = orderedListItem(in: line) {
                flushParagraph()
                if listKind != .orderedList {
                    flushList()
                    listKind = .orderedList
                }
                listLines.append(line)
                listItems.append(item)
                index += 1
                continue
            }

            if listKind != nil, line.first?.isWhitespace == true, !listItems.isEmpty {
                // 缩进续行属于前一个项目，不另起项目，也不丢失用户用于表达层级的空白。
                listLines.append(line)
                let previous = listItems.removeLast()
                listItems.append(RevisionMessageListItem(marker: previous.marker, content: previous.content + "\n" + line))
                index += 1
                continue
            }

            flushList()
            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        flushList()
        return result
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String
    }

    private static func openingFence(in line: String) -> Fence? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines)
        let language = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return Fence(marker: marker, length: length, language: language.lowercased())
    }

    private static func closesFence(_ line: String, fence: Fence) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == fence.marker else { return false }
        let length = trimmed.prefix(while: { $0 == fence.marker }).count
        return length >= fence.length && trimmed.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func headingText(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).first?.isWhitespace == true {
            return String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 中文提交说明常用“模块：”作为分段标题。只将简短、无路径或代码符号的独立行
        // 作为标题，`/path:`、`key: value` 等普通内容仍会完整按正文显示。
        guard trimmed.count <= 48, trimmed.hasSuffix(":") || trimmed.hasSuffix("：") else { return nil }
        let title = String(trimmed.dropLast())
        guard !title.isEmpty,
              !title.contains(where: { "/\\=;`(){}[]".contains($0) }),
              !title.contains(":"),
              !title.contains("：")
        else { return nil }
        return trimmed
    }

    private static func unorderedListItem(in line: String) -> RevisionMessageListItem? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        let remainder = trimmed.dropFirst()
        guard remainder.first?.isWhitespace == true else { return nil }
        let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : RevisionMessageListItem(marker: "•", content: text)
    }

    private static func orderedListItem(in line: String) -> RevisionMessageListItem? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let separator = trimmed.dropFirst(digits.count).first, separator == "." || separator == ")" else { return nil }
        let remainder = trimmed.dropFirst(digits.count + 1)
        guard remainder.first?.isWhitespace == true else { return nil }
        let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : RevisionMessageListItem(marker: "\(digits)\(separator)", content: text)
    }
}

/// 原生、可选择的提交说明阅读视图。解析仅在说明变更时进行，窗口拖动不会重复扫描全文。
struct RevisionMessageView: View {
    let message: String
    let palette: AppPalette
    @State private var blocks: [RevisionMessageBlock] = []
    @State private var parsedMessage: String?

    init(message: String, palette: AppPalette) {
        self.message = message
        self.palette = palette
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: message) {
            // 仅在选择了另一条提交时重新解析，窗口拖动与 ViewThatFits 的测量不会扫描全文。
            guard parsedMessage != message else { return }
            let source = message
            let parsed = await Task.detached(priority: .userInitiated) {
                RevisionMessageParser.blocks(in: source)
            }.value
            guard !Task.isCancelled else { return }
            blocks = parsed
            parsedMessage = source
        }
    }

    @ViewBuilder
    private func blockView(_ block: RevisionMessageBlock) -> some View {
        switch block.kind {
        case .heading:
            formattedText(block.content, size: 14, weight: .semibold)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .padding(.top, 2)
        case .paragraph:
            formattedText(block.content, size: 14)
                .foregroundStyle(palette.text)
                .lineSpacing(4)
                .textSelection(.enabled)
        case .unorderedList, .orderedList:
            listView(block)
        case let .code(language, isOpenEnded):
            codeView(content: block.content, language: language, isOpenEnded: isOpenEnded)
        }
    }

    private func listView(_ block: RevisionMessageBlock) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(block.listItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.marker)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .frame(width: 26, alignment: .trailing)
                    formattedText(item.content, size: 14)
                        .foregroundStyle(palette.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 1)
    }

    private func codeView(content: String, language: String, isOpenEnded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !language.isEmpty || isOpenEnded {
                HStack(spacing: 5) {
                    if !language.isEmpty {
                        Text(language)
                    }
                    if isOpenEnded {
                        Text("代码块未闭合")
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
            }
            ScrollView(.horizontal) {
                Text(content.isEmpty ? " " : content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(palette.controlBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func formattedText(_ value: String, size: CGFloat, weight: Font.Weight = .regular) -> Text {
        RevisionMessageInlineParser.tokens(in: value).reduce(Text("")) { partial, token in
            switch token {
            case let .text(content):
                Text("\(partial)\(Text(content).font(.system(size: size, weight: weight)))")
            case let .bold(content):
                Text("\(partial)\(Text(content).font(.system(size: size, weight: .semibold)))")
            case let .code(content):
                Text("\(partial)\(Text(content).font(.system(size: max(11, size - 1), design: .monospaced)))")
            }
        }
    }
}
