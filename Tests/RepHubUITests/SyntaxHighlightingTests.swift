import Testing
@testable import RepHubUI

struct SyntaxHighlightingTests {
    @Test
    func javaStringsKeepURLsAheadOfCommentDetection() {
        let kinds = SyntaxHighlighting.highlightedKinds(in: "String endpoint = \"http://server/api\"; // production")

        #expect(kinds == [.type, .string, .comment])
    }

    @Test
    func swiftKeywordsAndSingleLineBlockCommentsAreHighlighted() {
        let kinds = SyntaxHighlighting.highlightedKinds(in: "actor Client { func load() async throws { /* once */ } }")

        #expect(kinds.contains(.keyword))
        #expect(kinds.contains(.comment))
    }

    @Test
    func sqlSupportsKeywordsStringsAndDashComments() {
        let kinds = SyntaxHighlighting.highlightedKinds(in: "SELECT * FROM audit WHERE name = 'zym' -- current user")

        #expect(kinds.filter { $0 == .keyword }.count == 3)
        #expect(kinds.contains(.string))
        #expect(kinds.last == .comment)
    }

    @Test
    func xmlSupportsTagsStringsAndComments() {
        let kinds = SyntaxHighlighting.highlightedKinds(in: "<bean name=\"service\"><!-- runtime --></bean>")

        #expect(kinds == [.markupTag, .string, .comment, .markupTag])
    }

    @Test
    func languageDetectionUsesPathAndFenceWithoutGuessingUnknownExtensions() {
        #expect(SyntaxHighlighting.language(for: "Sources/App/Main.swift") == .swift)
        #expect(SyntaxHighlighting.language(for: "config/application.yml") == .yaml)
        #expect(SyntaxHighlighting.language(for: "README.unknown") == .plain)
        #expect(SyntaxHighlighting.language(forFence: "typescript title=example") == .typescript)
        #expect(SyntaxHighlighting.highlightedKinds(in: "String \"value\" 42 // text", language: .plain).isEmpty)
    }

    @Test
    func languageSpecificCommentMarkersDoNotLeakAcrossLanguages() {
        #expect(SyntaxHighlighting.highlightedKinds(in: "int a = b--;", language: .java).contains(.comment) == false)
        #expect(SyntaxHighlighting.highlightedKinds(in: "select 1 -- audit", language: .sql).last == .comment)
        #expect(SyntaxHighlighting.highlightedKinds(in: "url = \"https://host//ok\" # note", language: .properties) == [.propertyKey, .string, .comment])
    }

    @Test
    func blockAndTripleStringsCarryStateBetweenLines() {
        var state = SyntaxHighlighting.State()
        let first = SyntaxHighlighting.tokenize("/* still open", language: .java, state: &state)
        let second = SyntaxHighlighting.tokenize("closed */ class A {}", language: .java, state: &state)
        #expect(first.allSatisfy { $0.kind == .comment })
        #expect(second.first?.kind == .comment)
        #expect(second.contains { $0.kind == .keyword && $0.value == "class" })

        var python = SyntaxHighlighting.State()
        _ = SyntaxHighlighting.tokenize("value = \"\"\"not # a comment", language: .python, state: &python)
        let tail = SyntaxHighlighting.tokenize("still text\"\"\"", language: .python, state: &python)
        #expect(tail.allSatisfy { $0.kind == .string })

        var pythonSingle = SyntaxHighlighting.State()
        _ = SyntaxHighlighting.tokenize("doc = '''not # a comment", language: .python, state: &pythonSingle)
        #expect(SyntaxHighlighting.tokenize("still doc'''", language: .python, state: &pythonSingle).allSatisfy { $0.kind == .string })

        var java = SyntaxHighlighting.State()
        _ = SyntaxHighlighting.tokenize("String text = \"\"\"not // a comment", language: .java, state: &java)
        #expect(SyntaxHighlighting.tokenize("still text\"\"\";", language: .java, state: &java).first?.kind == .string)
    }

    @Test
    func templateStringAndConfigurationKeysAreColored() {
        var state = SyntaxHighlighting.State()
        _ = SyntaxHighlighting.tokenize("const text = `hello", language: .javascript, state: &state)
        let tail = SyntaxHighlighting.tokenize("// text`;", language: .javascript, state: &state)
        #expect(tail.first?.kind == .string)
        #expect(SyntaxHighlighting.highlightedKinds(in: "server.port: 8080", language: .yaml) == [.propertyKey, .number])
        #expect(SyntaxHighlighting.highlightedKinds(in: "@Override public String id()", language: .java).prefix(3) == [.annotation, .keyword, .type])
        #expect(SyntaxHighlighting.highlightedKinds(in: "{\"String\": 42}", language: .json) == [.propertyKey, .number])
        #expect(SyntaxHighlighting.highlightedKinds(in: "<String>42</String>", language: .xml) == [.markupTag, .number, .markupTag])
    }

    @Test
    func sourceTokenizationPreservesEmptyLinesAndOriginalContents() {
        let source = "let emoji = \"你好👋\"\n\n// note"
        let lines = SyntaxHighlighting.tokenize(source, language: .swift)
        #expect(lines.count == 3)
        #expect(lines[1].isEmpty)
        #expect(lines.map { $0.map(\.value).joined() }.joined(separator: "\n") == source)
        #expect(SyntaxHighlighting.tokenize(String(repeating: "x", count: 300_000), language: .swift).first?.first?.kind == .plain)
    }
}
