import XCTest
@testable import RepHubUI

final class PreparedDiffCacheTests: XCTestCase {
    func testPreparesUnicodeRowsAndKeepsExactSourceAsSingleCacheEntry() async throws {
        let cache = PreparedDiffCache(maximumEntries: 2, maximumCachedBytes: 16_384)
        let patch = "@@ -1 +1 @@\n-plain\n+中文😀\n"

        let first = try await cache.prepare(patch)
        let second = try await cache.prepare(String(patch))
        let statistics = await cache.cacheStatistics()

        guard case let .unified(firstDiff) = first.content,
              case let .unified(secondDiff) = second.content else {
            return XCTFail("统一差异应在后台准备为可渲染行")
        }
        XCTAssertGreaterThanOrEqual(firstDiff.rows.count, 2)
        XCTAssertEqual(firstDiff.rows.count, secondDiff.rows.count)
        XCTAssertEqual(statistics.entries, 1)
        XCTAssertGreaterThanOrEqual(statistics.bytes, patch.utf8.count * 2)
        XCTAssertGreaterThanOrEqual(firstDiff.newColumnWidth, firstDiff.oldColumnWidth)
    }

    func testEvictsOldPreparedPatchWithinConfiguredBound() async throws {
        let cache = PreparedDiffCache(maximumEntries: 1, maximumCachedBytes: 16_384)
        _ = try await cache.prepare("@@ -1 +1 @@\n-a\n+b\n")
        _ = try await cache.prepare("@@ -1 +1 @@\n-c\n+d\n")

        let statistics = await cache.cacheStatistics()
        XCTAssertEqual(statistics.entries, 1)
        XCTAssertGreaterThan(statistics.bytes, 0)
    }

    func testLargePatchSecondPreparationUsesCachedStructure() async throws {
        let cache = PreparedDiffCache(maximumEntries: 2, maximumCachedBytes: 12 * 1_024 * 1_024)
        let patch = (["@@ -1,10000 +1,10000 @@"] + (1...10_000).map { " context \($0) 中文内容" })
            .joined(separator: "\n") + "\n"

        let coldStart = Date()
        _ = try await cache.prepare(patch)
        let coldElapsed = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        _ = try await cache.prepare(String(patch))
        let warmElapsed = Date().timeIntervalSince(warmStart)
        let statistics = await cache.cacheStatistics()

        print("PreparedDiffCache 10000 行：cold \(coldElapsed)s, warm \(warmElapsed)s")
        XCTAssertEqual(statistics.builds, 1)
        XCTAssertEqual(statistics.hits, 1)
        XCTAssertEqual(statistics.entries, 1)
    }

    func testSamePatchUsesLanguageSpecificCacheEntries() async throws {
        let cache = PreparedDiffCache()
        let patch = "@@ -1 +1 @@\n-value--\n+value--\n"
        let java = try await cache.prepare(patch, path: "Counter.java")
        let sql = try await cache.prepare(patch, path: "Counter.sql")
        _ = try await cache.prepare(patch, path: "Other.java")
        let statistics = await cache.cacheStatistics()
        XCTAssertFalse(try newLines(java).flatMap(\.tokens).contains { $0.kind == .comment })
        XCTAssertTrue(try newLines(sql).flatMap(\.tokens).contains { $0.kind == .comment })
        XCTAssertEqual(statistics.builds, 2)
        XCTAssertEqual(statistics.hits, 1)
    }

    func testOldAndNewSidesKeepSeparateMultilineStateAndResetAcrossHunks() async throws {
        let patch = "@@ -1,2 +1,2 @@\n-/* old comment\n+int count = 1;\n class Example {}\n@@ -40 +40 @@\n class Later {}\n"
        let result = try await PreparedDiffCache().prepare(patch, path: "Example.java")
        guard case let .unified(diff) = result.content else { return XCTFail("Expected unified diff") }
        let pairs = diff.rows.compactMap { row -> (PreparedDiffLine?, PreparedDiffLine?)? in
            if case let .paired(old, new) = row { return (old, new) }
            return nil
        }
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs[1].0?.tokens.map(\.value).joined(), "class Example {}")
        XCTAssertEqual(pairs[1].0?.tokens.map(\.kind), [.comment])
        XCTAssertTrue(pairs[1].1?.tokens.contains { $0.kind == .keyword } == true)
        XCTAssertTrue(pairs[2].0?.tokens.contains { $0.kind == .keyword } == true)
    }

    func testHighlightingContinuesBeyondFirstDisplayPage() async throws {
        let source = (1...650).map { "+public String value\($0) = \"中文😀\";" }
        let patch = (["@@ -0,0 +1,650 @@"] + source).joined(separator: "\n") + "\n"
        let result = try await PreparedDiffCache().prepare(patch, path: "Large.java")
        let lines = try newLines(result)
        XCTAssertEqual(lines.count, 650)
        XCTAssertTrue(lines[649].tokens.contains { $0.kind == .keyword })
        XCTAssertTrue(lines[649].tokens.contains { $0.kind == .string })
        XCTAssertEqual(lines[649].tokens.map(\.value).joined(), String(source[649].dropFirst()))
    }

    func testCombinedPatchUsesEachFileHeaderLanguage() async throws {
        let patch = "diff --git a/A.java b/A.java\n--- a/A.java\n+++ b/A.java\n@@ -1 +1 @@\n-value--\n+value--\ndiff --git a/A.sql b/A.sql\n--- a/A.sql\n+++ b/A.sql\n@@ -1 +1 @@\n-select 0\n+select 1 -- comment\n"
        let result = try await PreparedDiffCache().prepare(patch)
        let lines = try newLines(result)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].tokens.contains { $0.kind == .comment })
        XCTAssertTrue(lines[1].tokens.contains { $0.kind == .comment })
        XCTAssertTrue(lines[1].tokens.contains { $0.kind == .keyword })
    }

    func testSVNHeaderWithSpacesAndRevisionSuffixUsesFileLanguage() async throws {
        let patch = "Index: src/My Example.java\n===================================================================\n--- src/My Example.java (revision 12)\n+++ src/My Example.java (working copy)\n@@ -1 +1 @@\n-class Old {}\n+class New {}\n"
        let result = try await PreparedDiffCache().prepare(patch)
        XCTAssertTrue(try newLines(result).first?.tokens.contains { $0.kind == .keyword } == true)
    }

    private func newLines(_ prepared: PreparedDiff) throws -> [PreparedDiffLine] {
        guard case let .unified(diff) = prepared.content else {
            throw NSError(domain: "PreparedDiffCacheTests", code: 1)
        }
        return diff.rows.compactMap { row in
            if case let .paired(_, new) = row { return new }
            return nil
        }
    }
}
