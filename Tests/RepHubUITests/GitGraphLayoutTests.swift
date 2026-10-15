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

    func testWideHistoryKeepsTextSpaceAndEveryLaneIsReachable() {
        let parents = (0..<40).map { "branch-\($0)" }
        let rows = GitGraphLayout.rows(for: [revision("merge", parents: parents)] + parents.map { revision($0) })
        let total = rows.map(\.laneCount).max() ?? 0
        XCTAssertEqual(total, 40)
        var reachable = Set<Int>()
        for first in 0..<total {
            let viewport = HistoryGraphViewport(totalLanes: total, availableWidth: 430, requestedFirstLane: first)
            XCTAssertLessThanOrEqual(viewport.width, 70)
            for lane in 0..<total where viewport.contains(lane) {
                XCTAssertGreaterThanOrEqual(viewport.x(for: lane), 0)
                XCTAssertLessThan(viewport.x(for: lane), viewport.width)
                reachable.insert(lane)
            }
        }
        XCTAssertEqual(reachable.count, total)
    }

    func testGraphViewportClampsAfterFilteringAndNarrowing() {
        let narrow = HistoryGraphViewport(totalLanes: 100, availableWidth: 220, requestedFirstLane: 999)
        XCTAssertLessThanOrEqual(narrow.width, 40)
        XCTAssertTrue(narrow.contains(99))
        XCTAssertFalse(narrow.contains(0))
        let filtered = HistoryGraphViewport(totalLanes: 1, availableWidth: 430, requestedFirstLane: 90)
        XCTAssertEqual(filtered.firstLane, 0)
        XCTAssertEqual(filtered.width, 26)
        XCTAssertFalse(filtered.hasOverflow)
    }

    func testLoadingOlderComplicatedHistoryDoesNotGrowGraphBeyondBudget() {
        let simple = HistoryGraphViewport(totalLanes: 1, availableWidth: 640)
        let many = HistoryGraphViewport(totalLanes: 25, availableWidth: 640)
        let more = HistoryGraphViewport(totalLanes: 80, availableWidth: 640)
        XCTAssertEqual(simple.width, 26)
        XCTAssertEqual(many.width, more.width)
        XCTAssertLessThanOrEqual(more.width, 70)
    }

    func testCancelledGraphPreparationStopsBeforeProcessingRemainingHistory() {
        var checks = 0
        let history = (0..<1_000).map { revision("node-\($0)", parents: ["node-\($0 + 1)"]) }
        let rows = GitGraphLayout.rows(for: history) {
            checks += 1
            return checks == 5
        }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(checks, 5)
    }

    private func revision(_ id: String, parents: [String] = []) -> Revision {
        Revision(id: id, author: "test", date: .distantPast, message: id, parents: parents)
    }
}
