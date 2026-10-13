import Foundation

/// 单个文本内容冲突的三个只读版本与当前工作区文本。
/// `stateToken` 只能回传给生成它的适配器，界面不能从中推断版本控制语义。
public struct RepositoryContentConflict: Sendable, Equatable {
    public let binding: RepositoryBinding
    public let path: String
    public let stateToken: String
    public let base: String
    public let local: String
    public let incoming: String
    public let working: String

    public init(binding: RepositoryBinding, path: String, stateToken: String,
                base: String, local: String, incoming: String, working: String) {
        self.binding = binding
        self.path = path
        self.stateToken = stateToken
        self.base = base
        self.local = local
        self.incoming = incoming
        self.working = working
    }
}

public struct RepositoryConflictResolutionRequest: Sendable, Equatable {
    public let path: String
    public let stateToken: String
    /// 用户最终确认的 UTF-8 文本；服务端会再次核验冲突和令牌，再以原子方式写入。
    public let content: String

    public init(path: String, stateToken: String, content: String) {
        self.path = path
        self.stateToken = stateToken
        self.content = content
    }
}

public enum RepositoryConflictResolutionOutcome: Sendable, Equatable {
    case succeeded, failed, cancelled, unknown
}

public struct RepositoryConflictResolutionResult: Sendable, Equatable {
    public let outcome: RepositoryConflictResolutionOutcome
    public let summary: String
    public let details: String

    public init(outcome: RepositoryConflictResolutionOutcome, summary: String, details: String = "") {
        self.outcome = outcome
        self.summary = summary
        self.details = details
    }
}

/// 适配器负责读取各自的基准／本地／传入版本，并在保存前后复核冲突状态。
/// 不将 Git index 或 SVN 冲突文件命名规则泄漏到界面和业务层。
public protocol RepositoryConflictEditingProvider: VersionControlProvider {
    func contentConflict(in binding: RepositoryBinding, path: String) async throws -> RepositoryContentConflict
    func resolveContentConflict(_ request: RepositoryConflictResolutionRequest,
                                in binding: RepositoryBinding) async throws -> RepositoryConflictResolutionResult
}

public enum RepositoryConflictChoice: String, CaseIterable, Identifiable, Sendable {
    case local, incoming, both
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .local: "采用本地"
        case .incoming: "采用传入"
        case .both: "保留两边"
        }
    }
}

public struct RepositoryConflictBlock: Identifiable, Sendable, Equatable {
    public let id: Int
    public let local: String
    public let base: String?
    public let incoming: String

    public init(id: Int, local: String, base: String?, incoming: String) {
        self.id = id
        self.local = local
        self.base = base
        self.incoming = incoming
    }
}

/// 仅处理标准 Git/SVN 文本冲突标记。不能解析时不改动原文，用户仍可直接编辑最终结果。
public enum RepositoryConflictTextResolver {
    public static func containsMarkers(in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains {
            $0.hasPrefix("<<<<<<<") || $0.hasPrefix("|||||||") || $0.hasPrefix("=======") || $0.hasPrefix(">>>>>>>")
        }
    }

    public static func blocks(in text: String) -> [RepositoryConflictBlock] {
        parsed(in: text).enumerated().map { index, item in
            RepositoryConflictBlock(id: index, local: item.local, base: item.base, incoming: item.incoming)
        }
    }

    public static func applying(_ choice: RepositoryConflictChoice, to blockID: Int, in text: String) -> String {
        let items = parsed(in: text)
        guard items.indices.contains(blockID) else { return text }
        let item = items[blockID]
        let replacement: String
        switch choice {
        case .local: replacement = item.local
        case .incoming: replacement = item.incoming
        case .both: replacement = joined(item.local, item.incoming)
        }
        return text.replacingCharacters(in: item.range, with: replacement)
    }

    private struct ParsedBlock {
        let range: Range<String.Index>
        let local: String
        let base: String?
        let incoming: String
    }

    private static func parsed(in text: String) -> [ParsedBlock] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return [] }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var result: [ParsedBlock] = []
        var cursor = text.startIndex
        var lineIndex = 0
        while lineIndex < lines.count {
            let value = String(lines[lineIndex])
            guard value.hasPrefix("<<<<<<<") else {
                cursor = advance(cursor, by: value, newline: newline, in: text)
                lineIndex += 1
                continue
            }
            let start = cursor
            var marker = lineIndex + 1
            var baseStart: Int?
            var divider: Int?
            while marker < lines.count {
                let candidate = String(lines[marker])
                if candidate.hasPrefix("|||||||") { baseStart = marker + 1 }
                if candidate.hasPrefix("=======") { divider = marker; break }
                marker += 1
            }
            guard let divider else {
                cursor = advance(cursor, by: value, newline: newline, in: text)
                lineIndex += 1
                continue
            }
            var end = divider + 1
            while end < lines.count, !String(lines[end]).hasPrefix(">>>>>>>") { end += 1 }
            guard end < lines.count else {
                cursor = advance(cursor, by: value, newline: newline, in: text)
                lineIndex += 1
                continue
            }
            let localEnd = baseStart.map { $0 - 1 } ?? divider
            let local = joinedLines(lines, from: lineIndex + 1, to: localEnd, newline: newline)
            let base = baseStart.map { joinedLines(lines, from: $0, to: divider, newline: newline) }
            let incoming = joinedLines(lines, from: divider + 1, to: end, newline: newline)
            var endCursor = start
            for index in lineIndex...end { endCursor = advance(endCursor, by: String(lines[index]), newline: newline, in: text) }
            result.append(ParsedBlock(range: start..<endCursor, local: local, base: base, incoming: incoming))
            cursor = endCursor
            lineIndex = end + 1
        }
        return result
    }

    private static func joinedLines(_ lines: [Substring], from: Int, to: Int, newline: String) -> String {
        guard from < to else { return "" }
        return lines[from..<to].map(String.init).joined(separator: newline) + newline
    }

    private static func joined(_ first: String, _ second: String) -> String {
        guard !first.isEmpty, !second.isEmpty else { return first + second }
        return first.hasSuffix("\n") || first.hasSuffix("\r") ? first + second : first + "\n" + second
    }

    private static func advance(_ index: String.Index, by line: String, newline: String, in text: String) -> String.Index {
        let afterLine = text.index(index, offsetBy: line.count, limitedBy: text.endIndex) ?? text.endIndex
        guard afterLine < text.endIndex else { return afterLine }
        return text.index(afterLine, offsetBy: newline.count, limitedBy: text.endIndex) ?? text.endIndex
    }
}
