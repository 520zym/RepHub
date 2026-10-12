import AppKit
import DesignSystem
import SwiftUI

/// AI 输出中的 Markdown 围栏代码块。解析只影响展示，原始输出仍由 `AIRunModel` 保存和用于填入提交说明。
struct AICodeOutputBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case prose
        case code(language: String, isOpenEnded: Bool)
    }

    let id: Int
    let kind: Kind
    let content: String
}

enum AICodeOutputParser {
    static func blocks(in output: String) -> [AICodeOutputBlock] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [AICodeOutputBlock] = []
        var prose: [String] = []
        var index = 0

        func appendProse() {
            guard !prose.isEmpty else { return }
            result.append(AICodeOutputBlock(id: result.count, kind: .prose, content: prose.joined(separator: "\n")))
            prose.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            guard let fence = openingFence(in: lines[index]) else {
                prose.append(lines[index])
                index += 1
                continue
            }

            appendProse()
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
            result.append(AICodeOutputBlock(
                id: result.count,
                kind: .code(language: fence.language, isOpenEnded: !closed),
                content: code.joined(separator: "\n")
            ))
        }
        appendProse()
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
}

/// 保持正文可选复制，代码块提供语言标识和独立复制入口。
struct AICodeOutputView: View {
    let output: String
    let palette: CodePalette
    let isRunning: Bool
    @State private var blocks: [AICodeOutputBlock] = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block.kind {
                case .prose:
                    Text(block.content)
                        .font(.system(.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .code(language, isOpenEnded):
                    AICodeBlockView(code: block.content, language: language, isOpenEnded: isOpenEnded,
                                    isRunning: isRunning, palette: palette)
                }
            }
        }
        .task(id: output) {
            // 围栏解析和 SwiftUI 绘制分开，流式输出时不会在 body 中重复扫描全文。
            let parsed = await Task.detached(priority: .userInitiated) {
                AICodeOutputParser.blocks(in: output)
            }.value
            guard !Task.isCancelled else { return }
            blocks = parsed
        }
    }
}

private struct AICodeBlockView: View {
    let code: String
    let language: String
    let isOpenEnded: Bool
    let isRunning: Bool
    let palette: CodePalette
    @State private var tokenLines: [[SyntaxHighlighting.Token]] = []
    @State private var didTokenize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .medium))
                Text(language.isEmpty ? "代码" : language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                if isOpenEnded {
                    Text(isRunning ? "正在生成" : "代码块未闭合")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("复制代码", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
                .help("复制代码")
            }
            .padding(.horizontal, 10)
            .frame(height: 31)
            .foregroundStyle(palette.foreground)
            .background(palette.selection.opacity(palette.isDark ? 0.38 : 0.56))

            ScrollView(.horizontal) {
                highlightedCode
                    .textSelection(.enabled)
                    .padding(11)
                    .frame(minWidth: 0, alignment: .leading)
            }
        }
        .background(palette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(palette.selection.opacity(0.62), lineWidth: 1))
        .task(id: HighlightingInput(code: code, language: language)) {
            guard !Task.isCancelled else { return }
            didTokenize = false
            guard code.utf8.count <= 256 * 1024 else {
                tokenLines = []
                didTokenize = true
                return
            }
            let source = code
            let codeLanguage = SyntaxHighlighting.language(forFence: language)
            let tokens = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighting.tokenize(source, language: codeLanguage)
            }.value
            guard !Task.isCancelled else { return }
            tokenLines = tokens
            didTokenize = true
        }
    }

    @ViewBuilder
    private var highlightedCode: some View {
        // 超大输出仍可复制和阅读，避免为每一行创建大量 SwiftUI 文本片段造成卡顿。
        if code.utf8.count > 256 * 1024 || !didTokenize {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.foreground)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tokenLines.enumerated()), id: \.offset) { _, tokens in
                    SyntaxHighlighting.text(tokens: tokens, palette: palette)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                }
            }
        }
    }

    private struct HighlightingInput: Hashable {
        let code: String
        let language: String
    }
}
