import XCTest
@testable import RepHubUI
import VersionControlCore

final class WorkspaceCommitSelectionTests: XCTestCase {
    func testSharedWorkingCopyKeepsOneSelectionWhenSwitchingBindings() {
        let root = URL(fileURLWithPath: "/tmp/rephub-commit-selection/shared", isDirectory: true)
        let git = binding(.git, root: root)
        let svn = binding(.svn, root: root)
        let changes = [
            change("Sources/App.swift"),
            change("README.md"),
            FileChange(path: "Sources/Conflict.swift", kind: .conflicted),
        ]
        var selection = WorkspaceCommitSelection()

        selection.reconcile(changes: changes, in: git)
        selection.setPaths(["Sources/App.swift"], in: git)
        selection.reconcile(changes: changes, in: svn)

        XCTAssertEqual(selection.paths(in: git), ["Sources/App.swift"])
        XCTAssertEqual(selection.paths(in: svn), ["Sources/App.swift"])
        XCTAssertEqual(selection.count(in: [git, svn]), 1)

        selection.reconcile(changes: changes, in: git)
        XCTAssertEqual(selection.paths(in: git), ["Sources/App.swift"], "切换来源不能重新勾选用户已取消的文件")
        XCTAssertFalse(selection.paths(in: svn).contains("Sources/Conflict.swift"))
    }

    func testDifferentRootsKeepSelectionsSeparateIncludingPrefixSiblings() {
        let git = binding(.git, root: URL(fileURLWithPath: "/tmp/rephub-commit-selection/repo", isDirectory: true))
        let svn = binding(.svn, root: URL(fileURLWithPath: "/tmp/rephub-commit-selection/repository", isDirectory: true))
        let changes = [change("Sources/App.swift")]
        var selection = WorkspaceCommitSelection()

        selection.reconcile(changes: changes, in: git)
        selection.reconcile(changes: changes, in: svn)
        selection.setPaths([], in: git)

        XCTAssertTrue(selection.paths(in: git).isEmpty)
        XCTAssertEqual(selection.paths(in: svn), ["Sources/App.swift"])
        XCTAssertEqual(selection.count(in: [git, svn]), 1, "repo 与 repository 不能因路径前缀混为同一工作副本")
    }

    func testNestedRootsKeepSelectionsIsolated() {
        let git = binding(.git, root: URL(fileURLWithPath: "/tmp/rephub-commit-selection/repo", isDirectory: true))
        let svn = binding(.svn, root: URL(fileURLWithPath: "/tmp/rephub-commit-selection/repo/sub", isDirectory: true))
        var selection = WorkspaceCommitSelection()

        selection.reconcile(changes: [change("sub/Inner.swift")], in: git)
        selection.setPaths([], in: git)
        selection.reconcile(changes: [change("Inner.swift")], in: svn)

        XCTAssertTrue(selection.paths(in: git).isEmpty)
        XCTAssertEqual(selection.paths(in: svn), ["Inner.swift"])
        XCTAssertEqual(selection.count(in: [git]), 0, "嵌套的独立工作副本不能让父仓库提交入口误以为有已选文件")
    }

    func testUnloadedBindingAtSameRootReusesKnownSharedSelection() {
        let root = URL(fileURLWithPath: "/tmp/rephub-commit-selection/shared-unloaded", isDirectory: true)
        let git = binding(.git, root: root)
        let svn = binding(.svn, root: root)
        var selection = WorkspaceCommitSelection()

        selection.reconcile(changes: [change("Sources/App.swift"), change("README.md")], in: git)
        selection.setPaths(["Sources/App.swift"], in: git)

        XCTAssertEqual(selection.paths(in: svn), ["Sources/App.swift"], "同根共管的未读取目标应携带已知选择进入预检")
        XCTAssertEqual(selection.count(in: [git, svn]), 1)
    }

    func testReconcileDropsDisappearedSelectionWithoutSelectingNewFiles() {
        let git = binding(.git, root: URL(fileURLWithPath: "/tmp/rephub-commit-selection/refresh", isDirectory: true))
        var selection = WorkspaceCommitSelection()

        selection.reconcile(changes: [change("Removed.swift"), change("Kept.swift")], in: git)
        selection.setPaths(["Removed.swift"], in: git)
        selection.reconcile(changes: [change("Kept.swift"), change("New.swift")], in: git)

        XCTAssertTrue(selection.paths(in: git).isEmpty, "已消失文件必须从提交范围移除，新发现文件不能自动补入")
    }

    func testReconcileRetainsExistingSelectionWithoutSelectingLaterNewFiles() {
        let git = binding(.git, root: URL(fileURLWithPath: "/tmp/rephub-commit-selection/retain", isDirectory: true))
        var selection = WorkspaceCommitSelection()

        selection.reconcile(changes: [change("Kept.swift")], in: git)
        selection.reconcile(changes: [change("Kept.swift"), change("New.swift")], in: git)

        XCTAssertEqual(selection.paths(in: git), ["Kept.swift"])
    }

    private func binding(_ providerID: ProviderID, root: URL) -> RepositoryBinding {
        RepositoryBinding(
            providerID: providerID,
            providerName: providerID == .git ? "Git" : "Subversion",
            root: root,
            capabilities: [.status, .commit]
        )
    }

    private func change(_ path: String) -> FileChange {
        FileChange(path: path, kind: .modified)
    }
}
