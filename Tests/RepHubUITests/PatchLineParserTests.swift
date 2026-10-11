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
}
