import XCTest
@testable import RepHubUI

final class DiffTextComparisonTests: XCTestCase {
    func testWhitespaceOnlyChangeIsIdentifiedWithoutChangingText() {
        let result = DiffTextComparison.compare(old: "let value = 1", new: "let  value = 1  ")
        XCTAssertTrue(result.isWhitespaceOnly)
        XCTAssertFalse(result.newRanges.isEmpty)
    }

    func testChangedCharactersAreNarrowedToChangedMiddle() {
        let result = DiffTextComparison.compare(old: "return oldValue;", new: "return newValue;")
        XCTAssertEqual(result.oldRanges, [7..<10])
        XCTAssertEqual(result.newRanges, [7..<10])
        XCTAssertFalse(result.usedFallback)
    }

    func testLongLinesFallBackToWholeLineRanges() {
        let old = String(repeating: "a", count: DiffTextComparison.maximumComparableCharacters + 1)
        let new = String(repeating: "b", count: DiffTextComparison.maximumComparableCharacters + 1)
        let result = DiffTextComparison.compare(old: old, new: new)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.oldRanges, [0..<old.count])
        XCTAssertEqual(result.newRanges, [0..<new.count])
    }

    func testPreparedRowsCarryWhitespaceAndInlineMetadata() async throws {
        let patch = "@@ -1 +1 @@\n-let value = 1\n+let  value = 1\n"
        let prepared = try await PreparedDiffCache().prepare(patch, path: "Example.swift")
        guard case let .unified(diff) = prepared.content,
              case let .paired(old?, new?) = diff.rows.first(where: { if case .paired(let old?, let new?) = $0 { return old.kind == .removed && new.kind == .added }; return false }) else {
            return XCTFail("expected paired changed row")
        }
        XCTAssertTrue(old.isWhitespaceOnlyChange)
        XCTAssertTrue(new.isWhitespaceOnlyChange)
        XCTAssertEqual(old.text, "let value = 1")
        XCTAssertFalse(new.inlineChangeRanges.isEmpty)
    }
}
