import XCTest
@testable import RepHubUI

final class SideBySideDiffParserTests: XCTestCase {
    func testPairsRemovalsAndAdditionsWithoutLosingContextOrMetadata() {
        let rows = SideBySideDiffParser.parse("""
        diff --git a/file.swift b/file.swift
        @@ -10,4 +20,3 @@
         retained()
        -removeOne()
        -removeTwo()
        +addOne()
         after()
        """)

        XCTAssertEqual(rows[0], .metadata("diff --git a/file.swift b/file.swift", isHunk: false))
        XCTAssertEqual(rows[1], .metadata("@@ -10,4 +20,3 @@", isHunk: true))
        XCTAssertEqual(rows[2], .paired(old: DiffSideLine(number: 10, text: "retained()", kind: .context), new: DiffSideLine(number: 20, text: "retained()", kind: .context)))
        XCTAssertEqual(rows[3], .paired(old: DiffSideLine(number: 11, text: "removeOne()", kind: .removed), new: DiffSideLine(number: 21, text: "addOne()", kind: .added)))
        XCTAssertEqual(rows[4], .paired(old: DiffSideLine(number: 12, text: "removeTwo()", kind: .removed), new: nil))
        XCTAssertEqual(rows[5], .paired(old: DiffSideLine(number: 13, text: "after()", kind: .context), new: DiffSideLine(number: 22, text: "after()", kind: .context)))
    }

    func testKeepsNoNewlineMarkerAsMetadata() {
        let rows = SideBySideDiffParser.parse("@@ -1 +1 @@\n-old\n+new\n\\ No newline at end of file")
        XCTAssertEqual(rows.last, .metadata("\\ No newline at end of file", isHunk: false))
    }

    func testTreatsTriplePlusAsCodeInsideHunk() {
        let rows = SideBySideDiffParser.parse("@@ -1 +1 @@\n-old\n+++literalPlusCode")
        XCTAssertEqual(rows[1], .paired(
            old: DiffSideLine(number: 1, text: "old", kind: .removed),
            new: DiffSideLine(number: 1, text: "++literalPlusCode", kind: .added)
        ))
    }
}
