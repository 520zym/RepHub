import Foundation
import VersionControlCore

/// 可跨差异布局和外观复用的、与颜色无关的差异数据。
/// 解析结果保存结构、行号、词法 token 和估算宽度，配色在渲染时从当前主题读取。
struct PreparedDiff: Sendable {
    enum Content: Sendable {
        case unified(PreparedUnifiedDiff)
        case binary(String)
        case unsupported(String)
    }

    let content: Content
    /// 缓存按源文本、副本行结构和数组槽位的保守估算计费，避免只按输入大小低估内存。
    let estimatedStorageBytes: Int
}

struct PreparedUnifiedDiff: Sendable {
    let rows: [PreparedDiffRow]
    let columnRows: [PreparedDiffRow]
    let oldColumnWidth: CGFloat
    let newColumnWidth: CGFloat
    let maximumLineNumberDigits: Int
}

struct PreparedDiffCacheStatistics: Sendable {
    let entries: Int
    let bytes: Int
    let hits: Int
    let builds: Int
}

enum PreparedDiffRow: Sendable {
    case metadata(String, isHunk: Bool)
    case paired(old: PreparedDiffLine?, new: PreparedDiffLine?)
}

extension PreparedDiffRow {
    var isWhitespaceOnlyChange: Bool {
        guard case let .paired(old, new) = self, let old, let new else { return false }
        return old.isWhitespaceOnlyChange && new.isWhitespaceOnlyChange
    }

    func contains(line number: Int) -> Bool {
        guard case let .paired(old, new) = self else { return false }
        return old?.number == number || new?.number == number
    }
}

struct PreparedDiffLine: Sendable {
    let number: Int?
    let text: String
    let kind: PreparedDiffSideKind
    var tokens: [SyntaxHighlighting.Token] = []
    /// 以 Character 偏移表示，避免持有跨线程的 String.Index。
    var inlineChangeRanges: [Range<Int>] = []
    var isWhitespaceOnlyChange = false
}

enum PreparedDiffSideKind: Sendable, Equatable {
    case context
    case added
    case removed
}

/// 有界 LRU 缓存。键使用完整 patch 文本的 String 相等比较，而非哈希值，因此不会把哈希冲突视为命中。
actor PreparedDiffCache {
    static let shared = PreparedDiffCache()

    private struct Entry: Sendable {
        let source: String
        let language: SyntaxHighlighting.Language
        let usesPatchPaths: Bool
        let prepared: PreparedDiff
        let estimatedCost: Int
    }

    private let maximumEntries: Int
    private let maximumCachedBytes: Int
    private var entries: [Entry] = []
    private var cachedBytes = 0
    private var hits = 0
    private var builds = 0

    init(maximumEntries: Int = 4, maximumCachedBytes: Int = 12 * 1_024 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumCachedBytes = max(1, maximumCachedBytes)
    }

    func prepare(_ text: String, path: String? = nil) throws -> PreparedDiff {
        try Task.checkCancellation()
        let language = SyntaxHighlighting.language(for: path)
        let usesPatchPaths = path == nil
        if let index = entries.firstIndex(where: { $0.source == text && $0.language == language && $0.usesPatchPaths == usesPatchPaths }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            hits += 1
            return entry.prepared
        }

        builds += 1
        let prepared = try Self.build(text, language: language, usesPatchPaths: usesPatchPaths)
        try Task.checkCancellation()
        let estimatedCost = prepared.estimatedStorageBytes
        // 单个超大输出只交给当前视图，不占用缓存；避免几个大型 patch 长期驻留内存。
        guard estimatedCost <= maximumCachedBytes else { return prepared }
        while !entries.isEmpty && (entries.count >= maximumEntries || cachedBytes + estimatedCost > maximumCachedBytes) {
            let removed = entries.removeFirst()
            cachedBytes -= removed.estimatedCost
        }
        entries.append(Entry(source: text, language: language, usesPatchPaths: usesPatchPaths, prepared: prepared, estimatedCost: estimatedCost))
        cachedBytes += estimatedCost
        return prepared
    }

    func cacheStatistics() -> PreparedDiffCacheStatistics {
        PreparedDiffCacheStatistics(entries: entries.count, bytes: cachedBytes, hits: hits, builds: builds)
    }

    private static func build(_ text: String, language: SyntaxHighlighting.Language, usesPatchPaths: Bool) throws -> PreparedDiff {
        try Task.checkCancellation()
        guard containsUnifiedHunk(text) else {
            if isBinary(text) { return PreparedDiff(content: .binary(text), estimatedStorageBytes: estimatedTextCost(text)) }
            return PreparedDiff(content: .unsupported(text), estimatedStorageBytes: estimatedTextCost(text))
        }
        // Parser 本身不依赖 AppKit / SwiftUI；它在 actor 上执行，避免 TAB 重建时在主线程重复拆分大文本。
        let parsedRows = SideBySideDiffParser.parse(text)
        try Task.checkCancellation()
        var oldState = SyntaxHighlighting.State()
        var newState = SyntaxHighlighting.State()
        var currentLanguage = language
        var tokenCost = 0
        var rows: [PreparedDiffRow] = []
        rows.reserveCapacity(parsedRows.count)
        for row in parsedRows {
            try Task.checkCancellation()
            switch row {
            case let .metadata(text, isHunk):
                if usesPatchPaths {
                    if text.hasPrefix("diff ") || text.hasPrefix("Index: ") { currentLanguage = .plain }
                    if let path = sourcePath(from: text) { currentLanguage = SyntaxHighlighting.language(for: path) }
                }
                // hunk 之间省略了源码，不能把前一段未闭合的注释状态带到另一段。
                if isHunk || text.hasPrefix("diff ") || text.hasPrefix("Index: ") {
                    oldState = SyntaxHighlighting.State(); newState = SyntaxHighlighting.State()
                }
                rows.append(.metadata(text, isHunk: isHunk))
            case let .paired(old, new):
                var oldLine = makePreparedLine(old, language: currentLanguage, state: &oldState)
                var newLine = makePreparedLine(new, language: currentLanguage, state: &newState)
                if var comparedOld = oldLine, var comparedNew = newLine,
                   comparedOld.kind == .removed, comparedNew.kind == .added {
                    let comparison = DiffTextComparison.compare(old: comparedOld.text, new: comparedNew.text)
                    comparedOld.inlineChangeRanges = comparison.oldRanges
                    comparedNew.inlineChangeRanges = comparison.newRanges
                    comparedOld.isWhitespaceOnlyChange = comparison.isWhitespaceOnly
                    comparedNew.isWhitespaceOnlyChange = comparison.isWhitespaceOnly
                    oldLine = comparedOld
                    newLine = comparedNew
                }
                tokenCost += ((oldLine?.tokens.count ?? 0) + (newLine?.tokens.count ?? 0)) * 64
                rows.append(.paired(old: oldLine, new: newLine))
            }
        }
        let columnRows = rows.filter { row in
            if case let .metadata(_, isHunk) = row { return isHunk }
            return true
        }
        var oldWidth = 0
        var newWidth = 0
        var maximumLineNumberDigits = 1
        for row in columnRows {
            try Task.checkCancellation()
            switch row {
            case let .metadata(text, _):
                let width = displayUnits(of: text)
                oldWidth = max(oldWidth, width)
                newWidth = max(newWidth, width)
            case let .paired(old, new):
                oldWidth = max(oldWidth, displayUnits(of: old?.text ?? ""))
                newWidth = max(newWidth, displayUnits(of: new?.text ?? ""))
                for number in [old?.number, new?.number].compactMap({ $0 }) {
                    maximumLineNumberDigits = max(maximumLineNumberDigits, String(number).count)
                }
            }
        }
        let prepared = PreparedUnifiedDiff(
            rows: rows,
            columnRows: columnRows,
            oldColumnWidth: contentWidth(for: oldWidth),
            newColumnWidth: contentWidth(for: newWidth),
            maximumLineNumberDigits: maximumLineNumberDigits
        )
        return PreparedDiff(
            content: .unified(prepared),
            estimatedStorageBytes: estimatedTextCost(text) + text.utf8.count + rows.count * 112 + columnRows.count * 24 + tokenCost
        )
    }

    private static func containsUnifiedHunk(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("@@ ") }
    }

    private static func sourcePath(from header: String) -> String? {
        guard header.hasPrefix("+++ ") || header.hasPrefix("--- ") else { return nil }
        // Git 的引号路径与 SVN 的 tab 修订后缀；这里只取扩展名，不访问文件系统。
        var path = String(header.dropFirst(4).split(separator: "\t", maxSplits: 1).first ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if let suffix = path.range(of: #" \((?:revision [0-9]+|working copy|nonexistent)\)$"#, options: .regularExpression) {
            path.removeSubrange(suffix)
        }
        return path.isEmpty || path == "/dev/null" ? nil : path
    }

    private static func isBinary(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("binary files") || text.localizedCaseInsensitiveContains("二进制文件")
    }

    private static func makePreparedLine(_ line: DiffSideLine?, language: SyntaxHighlighting.Language,
                                         state: inout SyntaxHighlighting.State) -> PreparedDiffLine? {
        guard let line else { return nil }
        let kind: PreparedDiffSideKind = switch line.kind {
        case .context: .context
        case .added: .added
        case .removed: .removed
        }
        return PreparedDiffLine(number: line.number, text: line.text, kind: kind,
                                tokens: SyntaxHighlighting.tokenize(line.text, language: language, state: &state))
    }


    /// SF Mono 对同一列大多为等宽；中文、全角符号和 emoji 按两格估算，组合标记不另占格。
    /// 只用于预留可横向滚动的最小内容宽度，绝不截断代码行。
    private static func displayUnits(of text: String) -> Int {
        var result = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .spacingMark:
                continue
            default:
                break
            }
            if scalar.value == 9 {
                result += 4 - (result % 4)
            } else {
                result += isWide(scalar.value) ? 2 : 1
            }
        }
        return result
    }

    private static func isWide(_ value: UInt32) -> Bool {
        (value >= 0x1100 && value <= 0x115F) ||
        (value >= 0x2E80 && value <= 0xA4CF) ||
        (value >= 0xAC00 && value <= 0xD7A3) ||
        (value >= 0xF900 && value <= 0xFAFF) ||
        (value >= 0xFE10 && value <= 0xFE6F) ||
        (value >= 0xFF01 && value <= 0xFF60) ||
        (value >= 0xFFE0 && value <= 0xFFE6) ||
        (value >= 0x1F300 && value <= 0x1FAFF)
    }

    private static func contentWidth(for units: Int) -> CGFloat {
        // 13pt monospaced system font 的字格近似宽度；行号、标记、左右内边距合计 80pt。
        max(620, ceil(CGFloat(units) * 7.85) + 80)
    }

    private static func estimatedTextCost(_ text: String) -> Int {
        // 缓存键和解析后的行文本都可能保有其各自的 String 存储，按两份 UTF-8 文本保守计费。
        max(1, text.utf8.count) * 2
    }
}
