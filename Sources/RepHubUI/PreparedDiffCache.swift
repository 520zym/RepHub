import Foundation
import VersionControlCore

/// 可跨差异布局和外观复用的、与颜色无关的差异数据。
/// 解析结果只保存结构、行号和估算宽度，实际配色仍在 SwiftUI 渲染时从当前主题读取。
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

struct PreparedDiffLine: Sendable {
    let number: Int?
    let text: String
    let kind: PreparedDiffSideKind
}

enum PreparedDiffSideKind: Sendable {
    case context
    case added
    case removed
}

/// 有界 LRU 缓存。键使用完整 patch 文本的 String 相等比较，而非哈希值，因此不会把哈希冲突视为命中。
actor PreparedDiffCache {
    static let shared = PreparedDiffCache()

    private struct Entry: Sendable {
        let source: String
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

    func prepare(_ text: String) throws -> PreparedDiff {
        try Task.checkCancellation()
        if let index = entries.firstIndex(where: { $0.source == text }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            hits += 1
            return entry.prepared
        }

        builds += 1
        let prepared = try Self.build(text)
        try Task.checkCancellation()
        let estimatedCost = prepared.estimatedStorageBytes
        // 单个超大输出只交给当前视图，不占用缓存；避免几个大型 patch 长期驻留内存。
        guard estimatedCost <= maximumCachedBytes else { return prepared }
        while !entries.isEmpty && (entries.count >= maximumEntries || cachedBytes + estimatedCost > maximumCachedBytes) {
            let removed = entries.removeFirst()
            cachedBytes -= removed.estimatedCost
        }
        entries.append(Entry(source: text, prepared: prepared, estimatedCost: estimatedCost))
        cachedBytes += estimatedCost
        return prepared
    }

    func cacheStatistics() -> PreparedDiffCacheStatistics {
        PreparedDiffCacheStatistics(entries: entries.count, bytes: cachedBytes, hits: hits, builds: builds)
    }

    private static func build(_ text: String) throws -> PreparedDiff {
        try Task.checkCancellation()
        guard containsUnifiedHunk(text) else {
            if isBinary(text) { return PreparedDiff(content: .binary(text), estimatedStorageBytes: estimatedTextCost(text)) }
            return PreparedDiff(content: .unsupported(text), estimatedStorageBytes: estimatedTextCost(text))
        }
        // Parser 本身不依赖 AppKit / SwiftUI；它在 actor 上执行，避免 TAB 重建时在主线程重复拆分大文本。
        let parsedRows = SideBySideDiffParser.parse(text)
        try Task.checkCancellation()
        let rows = parsedRows.map(makePreparedRow)
        let columnRows = rows.filter { row in
            if case let .metadata(_, isHunk) = row { return isHunk }
            return true
        }
        var oldWidth = 0
        var newWidth = 0
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
            }
        }
        let prepared = PreparedUnifiedDiff(
            rows: rows,
            columnRows: columnRows,
            oldColumnWidth: contentWidth(for: oldWidth),
            newColumnWidth: contentWidth(for: newWidth)
        )
        return PreparedDiff(
            content: .unified(prepared),
            estimatedStorageBytes: estimatedTextCost(text) + rows.count * 112 + columnRows.count * 24
        )
    }

    private static func containsUnifiedHunk(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("@@ ") }
    }

    private static func isBinary(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("binary files") || text.localizedCaseInsensitiveContains("二进制文件")
    }

    private static func makePreparedRow(_ row: DiffRow) -> PreparedDiffRow {
        switch row {
        case let .metadata(text, isHunk): .metadata(text, isHunk: isHunk)
        case let .paired(old, new): .paired(old: makePreparedLine(old), new: makePreparedLine(new))
        }
    }

    private static func makePreparedLine(_ line: DiffSideLine?) -> PreparedDiffLine? {
        guard let line else { return nil }
        let kind: PreparedDiffSideKind = switch line.kind {
        case .context: .context
        case .added: .added
        case .removed: .removed
        }
        return PreparedDiffLine(number: line.number, text: line.text, kind: kind)
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
