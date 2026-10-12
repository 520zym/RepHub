import Foundation
import SwiftUI
import DesignSystem

/// 轻量级、无网络依赖的逐行词法着色；只服务于阅读体验，不替代语言服务。
enum SyntaxHighlighting {
    enum Language: String, Sendable, Hashable {
        case automatic, plain, java, swift, kotlin, javascript, typescript, python, sql
        case xml, html, json, yaml, properties, shell, css, markdown
    }

    enum TokenKind: Equatable, Sendable {
        case plain, comment, string, number, keyword, type, markupTag
        case annotation, propertyKey
    }

    struct Token: Sendable, Equatable {
        let value: String
        let kind: TokenKind
    }

    struct State: Sendable {
        fileprivate var mode: Mode = .normal
        init() {}
    }

    fileprivate enum Mode: Sendable {
        case normal
        case blockComment(String)
        case tripleString(String)
        case templateString
    }

    private static let maxHighlightedLineLength = 262_144

    private static let keywords: Set<String> = [
        "import", "package", "let", "var", "val", "func", "fun", "struct", "enum", "class", "interface", "protocol", "extension", "public", "private", "protected", "internal", "static", "final", "abstract", "override", "open", "data", "sealed", "object", "companion", "const", "export", "default", "function", "typeof", "namespace", "module",
        "if", "else", "guard", "return", "case", "switch", "when", "for", "while", "do", "break", "continue", "try", "catch", "finally", "throw", "throws", "async", "await", "defer", "in", "is", "as", "with", "yield", "pass", "raise", "except", "elif", "global", "nonlocal", "assert", "del", "not", "and", "or", "def", "lambda", "from",
        "new", "this", "super", "extends", "implements", "synchronized", "volatile", "transient", "native", "strictfp", "instanceof", "null", "true", "false", "void", "actor", "some", "any", "where", "associatedtype", "init", "get", "set", "willSet", "didSet", "mutating", "nonmutating", "weak", "unowned", "lazy", "convenience", "required", "indirect", "nonisolated", "sending", "borrowing", "consuming", "rethrows", "isolated", "None", "True", "False"
    ]
    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "update", "delete", "create", "alter", "drop", "table", "view", "index", "join", "inner", "left", "right", "outer", "on", "as", "distinct", "group", "by", "having", "order", "limit", "offset", "union", "all", "values", "set", "null", "primary", "key", "foreign", "references", "constraint", "and", "or", "not", "in", "exists", "between", "like", "case", "when", "then", "else", "end", "commit", "rollback"
    ]
    private static let types: Set<String> = [
        "String", "Int", "Integer", "Long", "Double", "Float", "Boolean", "Bool", "Character", "Char", "Byte", "Short", "Void", "Unit", "Any", "AnyObject", "Nothing", "Object", "Class", "Exception", "Throwable", "Error", "IOException", "List", "ArrayList", "Map", "HashMap", "Set", "HashSet", "Optional", "Result", "Path", "URL", "File", "Data", "Date", "Decimal", "UUID"
    ]
    private static let programmingLanguages: Set<Language> = [.java, .swift, .kotlin, .javascript, .typescript, .python]

    static func language(for path: String?) -> Language {
        guard let path, let dot = path.lastIndex(of: ".") else { return .plain }
        return switch path[path.index(after: dot)...].lowercased() {
        case "java": .java
        case "swift": .swift
        case "kt", "kts": .kotlin
        case "js", "mjs", "cjs": .javascript
        case "ts", "tsx": .typescript
        case "py", "pyw": .python
        case "sql": .sql
        case "xml", "xsd", "xsl", "xhtml": .xml
        case "html", "htm": .html
        case "json": .json
        case "yml", "yaml": .yaml
        case "properties", "prop": .properties
        case "sh", "bash", "zsh", "fish": .shell
        case "css", "scss", "less": .css
        case "md", "markdown": .markdown
        default: .plain
        }
    }

    static func language(forFence info: String) -> Language {
        let value = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
        return switch value {
        case "java": .java; case "swift": .swift; case "kotlin", "kt": .kotlin
        case "javascript", "js", "node": .javascript; case "typescript", "ts": .typescript
        case "python", "py": .python; case "sql": .sql; case "xml": .xml
        case "html", "htm": .html; case "json", "jsonc": .json; case "yaml", "yml": .yaml
        case "properties", "prop": .properties; case "shell", "sh", "bash", "zsh": .shell
        case "css", "scss": .css; case "markdown", "md": .markdown
        default: .plain
        }
    }

    static func tokenize(_ source: String, language: Language) -> [[Token]] {
        var state = State()
        return source.components(separatedBy: "\n").map { tokenize($0, language: language, state: &state) }
    }

    static func tokenize(_ line: String, language: Language, state: inout State) -> [Token] {
        guard !line.isEmpty else { return [] }
        // 无法识别的扩展名不套用“通用”规则，避免把普通文本误染成源码。
        guard language != .plain else { return [Token(value: line, kind: .plain)] }
        // 压缩的 base64/lockfile 行不生成海量片段，但始终完整保留原文本。
        guard line.utf8.count <= maxHighlightedLineLength else { return [Token(value: line, kind: .plain)] }
        struct Fragment {
            let lower: String.Index
            var upper: String.Index
            let kind: TokenKind
        }
        var fragments: [Fragment] = []
        var index = line.startIndex
        func append(_ range: Range<String.Index>, _ kind: TokenKind) {
            guard range.lowerBound < range.upperBound else { return }
            if fragments.last?.kind == kind, fragments.last?.upper == range.lowerBound {
                fragments[fragments.count - 1].upper = range.upperBound
            } else { fragments.append(Fragment(lower: range.lowerBound, upper: range.upperBound, kind: kind)) }
        }
        func finish() -> [Token] { fragments.map { Token(value: String(line[$0.lower..<$0.upper]), kind: $0.kind) } }

        while index < line.endIndex {
            switch state.mode {
            case .blockComment(let close):
                if let end = line[index...].range(of: close) {
                    let after = end.upperBound; append(index..<after, .comment); index = after; state.mode = .normal
                } else { append(index..<line.endIndex, .comment); return finish() }
                continue
            case .tripleString(let delimiter):
                if let end = line[index...].range(of: delimiter) {
                    let after = end.upperBound; append(index..<after, .string); index = after; state.mode = .normal
                } else { append(index..<line.endIndex, .string); return finish() }
                continue
            case .templateString:
                let end = quotedEnd(in: line, from: index, quote: "`")
                if end < line.endIndex, line[end] == "`" {
                    let after = line.index(after: end); append(index..<after, .string); index = after; state.mode = .normal
                } else { append(index..<end, .string); return finish() }
                continue
            case .normal: break
            }

            let remainder = line[index...]
            if allowsMarkup(language), remainder.hasPrefix("<!--") {
                if let end = remainder.range(of: "-->") {
                    let after = end.upperBound; append(index..<after, .comment); index = after
                } else { append(index..<line.endIndex, .comment); state.mode = .blockComment("-->"); return finish() }
                continue
            }
            if allowsBlockComment(language), remainder.hasPrefix("/*") {
                if let end = remainder.range(of: "*/") {
                    let after = end.upperBound; append(index..<after, .comment); index = after
                } else { append(index..<line.endIndex, .comment); state.mode = .blockComment("*/"); return finish() }
                continue
            }
            if allowsLineComment(language, marker: "//"), remainder.hasPrefix("//") { append(index..<line.endIndex, .comment); return finish() }
            if allowsLineComment(language, marker: "--"), remainder.hasPrefix("--") { append(index..<line.endIndex, .comment); return finish() }
            if allowsLineComment(language, marker: "#"), remainder.hasPrefix("#") { append(index..<line.endIndex, .comment); return finish() }

            if (language == .java || language == .swift), remainder.hasPrefix("@") {
                let afterAt = line.index(after: index), end = identifierEnd(in: line, from: afterAt)
                if end > afterAt { append(index..<end, .annotation); index = end; continue }
            }
            if allowsMarkup(language), line[index] == "<" {
                var nameStart = line.index(after: index)
                if nameStart < line.endIndex, line[nameStart] == "/" { nameStart = line.index(after: nameStart) }
                let nameEnd = identifierEnd(in: line, from: nameStart)
                if nameEnd > nameStart {
                    append(index..<nameEnd, .markupTag); index = nameEnd; continue
                }
            }
            let tripleDelimiter: String? = {
                guard allowsTripleString(language) else { return nil }
                if remainder.hasPrefix("\"\"\"") { return "\"\"\"" }
                if language == .python, remainder.hasPrefix("'''") { return "'''" }
                return nil
            }()
            if let delimiter = tripleDelimiter {
                let start = line.index(index, offsetBy: 3)
                if let end = line[start...].range(of: delimiter) {
                    let after = end.upperBound; append(index..<after, .string); index = after
                } else { append(index..<line.endIndex, .string); state.mode = .tripleString(delimiter); return finish() }
                continue
            }
            if allowsTemplate(language), line[index] == "`" {
                let start = line.index(after: index), end = quotedEnd(in: line, from: start, quote: "`")
                if end < line.endIndex, line[end] == "`" {
                    let after = line.index(after: end); append(index..<after, .string); index = after
                } else { append(index..<end, .string); state.mode = .templateString; return finish() }
                continue
            }
            if line[index] == "\"" || line[index] == "'" {
                let quote = line[index], start = line.index(after: index), end = quotedEnd(in: line, from: start, quote: quote)
                let afterQuote = end < line.endIndex ? line.index(after: end) : end
                let kind: TokenKind = language == .json && isJSONStringKey(in: line, after: afterQuote) ? .propertyKey : .string
                if end < line.endIndex, line[end] == quote {
                    let after = line.index(after: end); append(index..<after, kind); index = after
                } else { append(index..<end, kind); index = end }
                continue
            }
            if line[index].isNumber {
                var end = line.index(after: index)
                while end < line.endIndex, line[end].isNumber || line[end] == "." || line[end] == "_" { end = line.index(after: end) }
                append(index..<end, .number); index = end; continue
            }
            if isIdentifierStart(line[index]) {
                let end = identifierEnd(in: line, from: index), value = String(line[index..<end])
                append(index..<end, tokenKind(for: value, language: language, line: line, end: end)); index = end; continue
            }
            let end = line.index(after: index); append(index..<end, .plain); index = end
        }
        return finish()
    }

    static func text(_ line: String, palette: CodePalette, language: Language = .automatic) -> Text {
        var state = State()
        return text(tokens: tokenize(line, language: language, state: &state), palette: palette)
    }

    static func text(tokens: [Token], palette: CodePalette) -> Text {
        var rendered = AttributedString()
        for token in tokens { append(token.value, color: color(for: token.kind, palette: palette), to: &rendered) }
        return Text(rendered)
    }

    static func highlightedKinds(in line: String, language: Language = .automatic) -> [TokenKind] {
        var state = State()
        return tokenize(line, language: language, state: &state).compactMap { $0.kind == .plain ? nil : $0.kind }
    }

    private static func allowsLineComment(_ language: Language, marker: String) -> Bool {
        switch marker {
        case "//": return [.automatic, .java, .swift, .kotlin, .javascript, .typescript, .css].contains(language)
        case "--": return language == .sql || language == .automatic
        case "#": return [.automatic, .python, .yaml, .properties, .shell, .markdown].contains(language)
        default: return false
        }
    }
    private static func allowsBlockComment(_ language: Language) -> Bool { [.automatic, .java, .swift, .kotlin, .javascript, .typescript, .sql, .css].contains(language) }
    private static func allowsMarkup(_ language: Language) -> Bool { [.automatic, .xml, .html].contains(language) }
    private static func allowsTripleString(_ language: Language) -> Bool { [.java, .python, .swift, .kotlin].contains(language) }
    private static func allowsTemplate(_ language: Language) -> Bool { [.javascript, .typescript].contains(language) }
    private static func quotedEnd(in line: String, from start: String.Index, quote: Character) -> String.Index {
        var cursor = start, escaped = false
        while cursor < line.endIndex {
            let character = line[cursor]
            if character == quote && !escaped { return cursor }
            if character == "\\" && !escaped { escaped = true } else { escaped = false }
            cursor = line.index(after: cursor)
        }
        return line.endIndex
    }
    private static func isIdentifierStart(_ character: Character) -> Bool { character == "_" || character == "$" || character.isLetter }
    private static func isIdentifierPart(_ character: Character) -> Bool { isIdentifierStart(character) || character.isNumber }
    private static func identifierEnd(in line: String, from start: String.Index) -> String.Index {
        var end = start
        while end < line.endIndex, isIdentifierPart(line[end]) { end = line.index(after: end) }
        return end
    }
    private static func isJSONStringKey(in line: String, after quote: String.Index) -> Bool {
        var cursor = quote
        while cursor < line.endIndex, line[cursor].isWhitespace { cursor = line.index(after: cursor) }
        return cursor < line.endIndex && line[cursor] == ":"
    }
    private static func tokenKind(for value: String, language: Language, line: String, end: String.Index) -> TokenKind {
        if language == .properties || language == .yaml {
            var cursor = end
            while cursor < line.endIndex, line[cursor].isWhitespace { cursor = line.index(after: cursor) }
            if cursor < line.endIndex, line[cursor] == ":" || line[cursor] == "=" { return .propertyKey }
        }
        if language == .sql { return sqlKeywords.contains(value.lowercased()) ? .keyword : .plain }
        if programmingLanguages.contains(language) {
            if types.contains(value) { return .type }
            return keywords.contains(value) ? .keyword : .plain
        }
        // automatic 是旧 API 的宽松兼容模式；按路径识别后的格式文件不会走这里。
        if language == .automatic {
            if types.contains(value) { return .type }
            return keywords.contains(value) || sqlKeywords.contains(value.lowercased()) ? .keyword : .plain
        }
        return .plain
    }

    static func color(for kind: TokenKind, palette: CodePalette) -> Color {
        switch kind {
        case .plain: palette.foreground
        case .comment: palette.comment
        case .string: palette.string
        case .number: palette.number
        case .keyword, .annotation: palette.keyword
        case .type, .markupTag, .propertyKey: palette.type
        }
    }
    private static func append(_ value: String, color: Color, to output: inout AttributedString) {
        var fragment = AttributedString(value); fragment.foregroundColor = color; output += fragment
    }
}
