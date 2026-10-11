import XCTest
@testable import RepHubUI
import VersionControlCore

final class GitGraphLayoutTests: XCTestCase {
    func testMergeKeepsEachParentInOneLane() {
        let rows = GitGraphLayout.rows(for: [
            revision("merge", parents: ["left", "right"]),
            revision("left", parents: ["base"]),
            revision("right", parents: ["base"]),
            revision("base")
        ])

        XCTAssertEqual(rows[0].parentLanes, [0, 1])
        XCTAssertEqual(rows[0].outgoingLaneIDs, ["left", "right"])
        XCTAssertEqual(rows[2].outgoingLaneIDs, ["base"])
        XCTAssertEqual(Set(rows[2].outgoingLaneIDs).count, rows[2].outgoingLaneIDs.count)
    }

    func testUnrelatedCommitDoesNotShiftExistingLanes() {
        let rows = GitGraphLayout.rows(for: [
            revision("merge", parents: ["left", "right"]),
            revision("unrelated"),
            revision("left", parents: ["base"])
        ])

        XCTAssertEqual(rows[1].currentLane, 2)
        XCTAssertEqual(rows[1].passThrough.map { $0.source }, [0, 1])
        XCTAssertEqual(rows[1].passThrough.map { $0.target }, [0, 1])
        XCTAssertEqual(rows[1].outgoingLaneIDs, ["left", "right"])
    }

    func testParentAlreadyInAnotherLaneIsNotDuplicated() {
        let rows = GitGraphLayout.rows(for: [
            revision("merge", parents: ["left", "right"]),
            revision("left", parents: ["base"]),
            revision("right", parents: ["base"])
        ])

        XCTAssertEqual(rows[2].parentLanes, [0])
        XCTAssertEqual(rows[2].outgoingLaneIDs, ["base"])
        XCTAssertEqual(Set(rows[2].outgoingLaneIDs).count, rows[2].outgoingLaneIDs.count)
    }

    private func revision(_ id: String, parents: [String] = []) -> Revision {
        Revision(id: id, author: "test", date: .distantPast, message: id, parents: parents)
    }
}
