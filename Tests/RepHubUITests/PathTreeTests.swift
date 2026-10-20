import XCTest
@testable import RepHubUI

final class PathTreeTests: XCTestCase {
    func testBuildsStableDirectoriesAndLeavesFromVersionControlPaths() {
        let roots = PathTree.make([
            PathTreeElement(id: "a", path: "origin/feature/one", payload: "one"),
            PathTreeElement(id: "b", path: "origin/main", payload: "main"),
            PathTreeElement(id: "c", path: "upstream/release", payload: "release")
        ], namespace: "branch/remote")

        XCTAssertEqual(roots.map(\.title), ["origin", "upstream"])
        XCTAssertEqual(roots[0].id, "branch/remote/origin")
        XCTAssertEqual(roots[0].children.map(\.title), ["feature", "main"])
        XCTAssertEqual(roots[0].children[0].children.first?.payload, "one")
        XCTAssertEqual(roots.flatMap(\.directoryIDs), ["branch/remote/origin", "branch/remote/origin/feature", "branch/remote/upstream"])
    }

    func testWorkspaceTreeStateKeepsEachAreaIndependent() {
        let state = WorkspaceTreeState()
        state.branchCollapsed.insert("branch/remote/origin")
        state.revisionCollapsed.insert("revision/Sources")

        XCTAssertTrue(state.branchCollapsed.contains("branch/remote/origin"))
        XCTAssertFalse(state.branchCollapsed.contains("revision/Sources"))
        XCTAssertTrue(state.revisionCollapsed.contains("revision/Sources"))
        XCTAssertTrue(state.workingCollapsed.isEmpty)
    }

    func testTreeIndentationKeepsIncreasingAfterFiveLevels() {
        let fifthLevel = TreeIndentation.leading(base: 12, perDepth: 14, depth: 5)
        let sixthLevel = TreeIndentation.leading(base: 12, perDepth: 14, depth: 6)
        let seventhLevel = TreeIndentation.leading(base: 12, perDepth: 14, depth: 7)
        let ninthLevel = TreeIndentation.leading(base: 12, perDepth: 14, depth: 9)

        XCTAssertEqual(fifthLevel, 82)
        XCTAssertEqual(sixthLevel, 96)
        XCTAssertEqual(seventhLevel, 110)
        XCTAssertEqual(ninthLevel, 138)
        XCTAssertGreaterThan(sixthLevel, fifthLevel)
        XCTAssertGreaterThan(seventhLevel, sixthLevel)
        XCTAssertGreaterThan(ninthLevel, seventhLevel)
    }
}
