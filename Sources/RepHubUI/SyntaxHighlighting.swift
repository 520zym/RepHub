import Foundation
import SwiftUI
import DesignSystem

/// 轻量级、跨语言的词法着色；不替代语言服务或完整语法树。
enum SyntaxHighlighting {
    private static let keywords: Set<String> = [
        // Swift / Java / Kotlin
        "import", "package", "let", "var", "val", "func", "fun", "struct", "enum", "class", "interface", "protocol", "extension", "public", "private", "protected", "internal", "static", "final", "abstract", "override", "open", "data", "sealed", "object", "companion",
        // 控制流与异常
        "if", "else", "guard", "return", "case", "switch", "when", "for", "while", "do", "break", "continue", "try", "catch", "finally", "throw", "throws", "async", "await", "defer", "in", "is", "as",
        // Python
        "def", "lambda", "from", "with", "yield", "pass", "raise", "except", "elif", "global", "nonlocal", "assert", "del", "not", "and", "or", "None", "True", "False",
        // Java / Swift declarations and modifiers
        "new", "this", "super", "extends", "implements", "default", "synchronized", "volatile", "transient", "native", "strictfp", "instanceof", "null", "true", "false", "void", "actor", "some", "any", "where", "associatedtype", "init", "get", "set", "willSet", "didSet", "mutating", "nonmutating", "weak", "unowned", "lazy", "convenience", "required", "indirect", "nonisolated", "sending", "borrowing", "consuming", "rethrows", "isolated"
    ]

    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "update", "delete", "create", "alter", "drop", "table", "view", "index", "join", "inner", "left", "right", "outer", "on", "as", "distinct", "group", "by", "having", "order", "limit", "offset", "union", "all", "values", "set", "null", "primary", "key", "foreign", "references", "constraint", "and", "or", "not", "in", "exists", "between", "like", "case", "when", "then", "else", "end", "commit", "rollback"
    ]

    private static let types: Set<String> = [
        "String", "Int", "Integer", "Long", "Double", "Float", "Boolean", "Bool", "Character", "Char", "Byte", "Short", "Void", "Unit", "Any", "AnyObject", "Nothing", "Object", "Class", "Exception", "Throwable", "Error", "IOException", "List", "ArrayList", "Map", "HashMap", "Set", "HashSet", "Optional", "Result", "Path", "URL", "File", "Data", "Date", "Decimal", "UUID"
    ]

    private static let expression = try! NSRegularExpression(pattern: #"<!--.*?-->|/\*.*?\*/|//.*|--.*|#.*|\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|</?[A-Za-z_][A-Za-z0-9_.:-]*|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    enum TokenKind: Equatable {
        case plain
        case comment
        case string
        case number
        case keyword
        case type
        case markupTag
    }

    private struct Token {
        let value: String
        let kind: TokenKind
    }

    static func text(_ line: String, palette: CodePalette) -> Text {
        var rendered = AttributedString()
        for token in tokens(in: line) {
            append(token.value, color: color(for: token.kind, palette: palette), to: &rendered)
        }
        return Text(rendered)
    }

    static func highlightedKinds(in line: String) -> [TokenKind] {
        tokens(in: line).compactMap { $0.kind == .plain ? nil : $0.kind }
    }

    private static func tokens(in line: String) -> [Token] {
        var tokens: [Token] = []
        var cursor = line.startIndex
        expression.enumerateMatches(in: line, range: NSRange(line.startIndex..., in: line)) { match, _, _ in
            guard let match, let range = Range(match.range, in: line) else { return }
            if cursor < range.lowerBound { tokens.append(Token(value: String(line[cursor..<range.lowerBound]), kind: .plain)) }
            let token = String(line[range])
            tokens.append(Token(value: token, kind: kind(for: token)))
            cursor = range.upperBound
        }
        if cursor < line.endIndex { tokens.append(Token(value: String(line[cursor...]), kind: .plain)) }
        return tokens
    }

    private static func kind(for token: String) -> TokenKind {
        if token.hasPrefix("//") || token.hasPrefix("#") || token.hasPrefix("--") || token.hasPrefix("/*") || token.hasPrefix("<!--") {
            return .comment
        }
        if token.hasPrefix("\"") || token.hasPrefix("'") { return .string }
        if token.hasPrefix("<") { return .markupTag }
        if token.first?.isNumber == true { return .number }
        if types.contains(token) { return .type }
        if keywords.contains(token) || sqlKeywords.contains(token.lowercased()) { return .keyword }
        return .plain
    }

    private static func color(for kind: TokenKind, palette: CodePalette) -> Color {
        switch kind {
        case .plain: palette.foreground
        case .comment: palette.comment
        case .string: palette.string
        case .number: palette.number
        case .keyword: palette.keyword
        case .type, .markupTag: palette.type
        }
    }

    private static func append(_ value: String, color: Color, to output: inout AttributedString) {
        var fragment = AttributedString(value)
        fragment.foregroundColor = color
        output += fragment
    }
}
