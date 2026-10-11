import XCTest
@testable import RepHubUI

final class PatchLineParserTests: XCTestCase {
    func testParsesOldAndNewLineNumbersWithinHunk() {
        let lines = PatchLineParser.parse("""
        diff --git a/File.swift b/File.swift
        --- a/File.swift
        +++ b/File.swift
        @@ -10,3 +20,4 @@ func run() {
         let retained = true
        -let removed = true
        +let added = true
        +let second = true
         return retained
        """)

        XCTAssertEqual(lines[0].oldLine, nil)
        XCTAssertEqual(lines[3].oldLine, nil)
        XCTAssertEqual(lines[4], PatchDisplayLine(text: " let retained = true", oldLine: 10, newLine: 20))
        XCTAssertEqual(lines[5], PatchDisplayLine(text: "-let removed = true", oldLine: 11, newLine: nil))
        XCTAssertEqual(lines[6], PatchDisplayLine(text: "+let added = true", oldLine: nil, newLine: 21))
        XCTAssertEqual(lines[7], PatchDisplayLine(text: "+let second = true", oldLine: nil, newLine: 22))
        XCTAssertEqual(lines[8], PatchDisplayLine(text: " return retained", oldLine: 12, newLine: 23))
    }

    func testMetadataAndNoNewlineMarkerHaveNoLineNumber() {
        let lines = PatchLineParser.parse("""
        --- a/file
        +++ b/file
        @@ -1 +1 @@
        -before
        +after
        \\ No newline at end of file
        """)

        XCTAssertEqual(lines[0].oldLine, nil)
        XCTAssertEqual(lines[1].newLine, nil)
        XCTAssertEqual(lines[5].oldLine, nil)
        XCTAssertEqual(lines[5].newLine, nil)
    }

    func testNormalizesMixedLineEndingsAndKeepsEmptyLineNumbers() {
        let lines = PatchLineParser.parse("@@ -4,3 +4,3 @@\r\n retained\r\n \n-old\r\n+new\n")

        XCTAssertEqual(lines[1], PatchDisplayLine(text: " retained", oldLine: 4, newLine: 4))
        XCTAssertEqual(lines[2], PatchDisplayLine(text: " ", oldLine: 5, newLine: 5))
        XCTAssertEqual(lines[3], PatchDisplayLine(text: "-old", oldLine: 6, newLine: nil))
        XCTAssertEqual(lines[4], PatchDisplayLine(text: "+new", oldLine: nil, newLine: 6))
        XCTAssertFalse(lines.contains { $0.text.contains("\r") })
    }
}
