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
}
