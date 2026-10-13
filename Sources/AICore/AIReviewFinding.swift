import Foundation

/// AI 审查结果中的单个问题。位置必须通过本次只读快照校验后才能用于界面跳转。
public struct AIReviewFinding: Identifiable, Codable, Hashable, Sendable {
    public enum Severity: String, Codable, CaseIterable, Sendable {
        case critical, warning, suggestion

        public var title: String {
            switch self {
            case .critical: "严重"
            case .warning: "警告"
            case .suggestion: "建议"
            }
        }
    }

    public enum Resolution: String, Codable, Sendable {
        case open, resolved, ignored
    }

    public let id: UUID
    public let severity: Severity
    /// 相对路径，只接受和本次 `AIContext.files` 完全相同的值。
    public let path: String
    /// Unified diff 中已出现的新版本行号；不接受旧版本行号。
    public let newLine: Int
    public let reason: String
    public let suggestion: String
    public var resolution: Resolution

    public init(id: UUID = UUID(), severity: Severity, path: String, newLine: Int,
                reason: String, suggestion: String, resolution: Resolution = .open) {
        self.id = id
        self.severity = severity
        self.path = path
        self.newLine = newLine
        self.reason = reason
        self.suggestion = suggestion
        self.resolution = resolution
    }
}

public extension AIContext {
    /// 返回本次提供给模型的 unified diff 中可确认的新版本行。只使用已发送的 patch，不读取仓库。
    func newLineNumbers(for path: String) -> Set<Int> {
        guard let patch = files.first(where: { $0.path == path })?.patch else { return [] }
        var result = Set<Int>()
        var currentLine: Int?
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if let lineNumber = Self.newHunkStart(in: value) {
                currentLine = lineNumber
                continue
            }
            guard let lineNumber = currentLine else { continue }
            if value.hasPrefix("\\ No newline at end of file") { continue }
            if value.hasPrefix("+") {
                if !value.hasPrefix("+++") {
                    result.insert(lineNumber)
                    Self.advance(&currentLine)
                }
            } else if value.hasPrefix("-") {
                // 旧版本行不影响新版本计数。
            } else if value.hasPrefix(" ") {
                result.insert(lineNumber)
                Self.advance(&currentLine)
            }
        }
        return result
    }

    func validates(_ finding: AIReviewFinding) -> Bool {
        files.contains(where: { $0.path == finding.path }) && finding.newLine > 0 && newLineNumbers(for: finding.path).contains(finding.newLine)
    }

    private static func newHunkStart(in line: String) -> Int? {
        guard line.hasPrefix("@@") else { return nil }
        // 例如：@@ -8,3 +12,5 @@；只取新版本起始行。
        guard let plus = line.firstIndex(of: "+") else { return nil }
        let rest = line[line.index(after: plus)...]
        let digits = rest.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private static func advance(_ value: inout Int?) {
        guard let line = value else { return }
        value = line == Int.max ? nil : line + 1
    }
}
