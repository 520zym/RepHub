import XCTest
@testable import GitAdapter

final class GitTransferProgressTests: XCTestCase {
    func testParsesReceivingObjectsPercentageAndTransferDetail() {
        let update = GitTransferProgressParser.parse(
            "Receiving objects:  67% (2/3), 1.25 MiB | 5.00 MiB/s"
        )

        XCTAssertEqual(update?.stage, "receiving")
        XCTAssertEqual(update?.message, "正在接收 Git 对象…")
        XCTAssertEqual(update?.fraction, 0.67)
        XCTAssertEqual(update?.detail, "2/3 · 1.25 MiB | 5.00 MiB/s")
    }

    func testParsesRemoteDeltaProgressAndPhaseFallback() {
        let deltas = GitTransferProgressParser.parse("remote: Resolving deltas:  50% (1/2)")
        XCTAssertEqual(deltas?.stage, "resolving")
        XCTAssertEqual(deltas?.fraction, 0.5)
        XCTAssertEqual(deltas?.detail, "1/2")

        let enumerating = GitTransferProgressParser.parse("remote: Enumerating objects: 42, done.")
        XCTAssertEqual(enumerating?.stage, "enumerating")
        XCTAssertNil(enumerating?.fraction)
    }

    func testParsesPushWritingObjectsAndLocalEnumeration() {
        let writing = GitTransferProgressParser.parse("Writing objects:  42% (42/100), 1.25 MiB | 5.00 MiB/s")
        XCTAssertEqual(writing?.stage, "writing")
        XCTAssertEqual(writing?.message, "正在上传 Git 对象…")
        XCTAssertEqual(writing?.fraction, 0.42)
        XCTAssertEqual(writing?.detail, "42/100 · 1.25 MiB | 5.00 MiB/s")
        XCTAssertEqual(GitTransferProgressParser.parse("Enumerating objects: 100, done.")?.stage, "enumerating")
        XCTAssertNil(GitTransferProgressParser.parse("Writing objects: 101% (101/100)"))
    }

    func testDoesNotTreatArbitraryRemoteTextAsTransferProgress() {
        XCTAssertNil(GitTransferProgressParser.parse("remote: deployment succeeded at https://example.invalid/token=secret"))
        XCTAssertNil(GitTransferProgressParser.parse("Receiving objects: ready"))
        XCTAssertNil(GitTransferProgressParser.parse("Updating files: 101% (4/3)"))
    }
}
