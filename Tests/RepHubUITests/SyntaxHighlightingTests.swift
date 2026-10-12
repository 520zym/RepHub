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
}
