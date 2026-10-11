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
        "def", "lambda", "from", "with", "yield", "pass", "raise", "except", "elif", "global", "nonlocal", "assert", "del", "not", "and", "or", "None", "True", "False"
    ]

    private static let types: Set<String> = [
        "String", "Int", "Integer", "Long", "Double", "Float", "Boolean", "Bool", "Character", "Char", "Byte", "Short", "Void", "Unit", "Any", "AnyObject", "Nothing", "Object", "Class", "Exception", "Throwable", "Error", "IOException", "List", "ArrayList", "Map", "HashMap", "Set", "HashSet", "Optional", "Result", "Path", "URL", "File", "Data", "Date", "Decimal", "UUID"
    ]

    private static let expression = try! NSRegularExpression(pattern: #"//.*|#.*|\"(?:[^\"\\]|\\.)*\"|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    static func text(_ line: String, palette: CodePalette) -> Text {
        var rendered = AttributedString()
        var cursor = line.startIndex
        expression.enumerateMatches(in: line, range: NSRange(line.startIndex..., in: line)) { match, _, _ in
            guard let match, let range = Range(match.range, in: line) else { return }
            if cursor < range.lowerBound { append(String(line[cursor..<range.lowerBound]), color: palette.foreground, to: &rendered) }
            let token = String(line[range])
            let color: Color
            if token.hasPrefix("//") || token.hasPrefix("#") { color = palette.comment }
            else if token.hasPrefix("\"") { color = palette.string }
            else if token.first?.isNumber == true { color = palette.number }
            else if types.contains(token) { color = palette.type }
            else if keywords.contains(token) { color = palette.keyword }
            else { color = palette.foreground }
            append(token, color: color, to: &rendered)
            cursor = range.upperBound
        }
        if cursor < line.endIndex { append(String(line[cursor...]), color: palette.foreground, to: &rendered) }
        return Text(rendered)
    }

    private static func append(_ value: String, color: Color, to output: inout AttributedString) {
        var fragment = AttributedString(value)
        fragment.foregroundColor = color
        output += fragment
    }
}
