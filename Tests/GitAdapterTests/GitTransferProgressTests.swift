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

    func testDoesNotTreatArbitraryRemoteTextAsTransferProgress() {
        XCTAssertNil(GitTransferProgressParser.parse("remote: deployment succeeded at https://example.invalid/token=secret"))
        XCTAssertNil(GitTransferProgressParser.parse("Receiving objects: ready"))
        XCTAssertNil(GitTransferProgressParser.parse("Updating files: 101% (4/3)"))
    }
}
