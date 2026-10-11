import Foundation
import Testing
import GitAdapter
import RepositoryApplication
import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("隔离仓库更新集成")
struct RepositoryUpdateIntegrationTests {
    @Test("共管目录仅更新 SVN 时保留 Git 提交指针并刷新两侧状态", .timeLimit(.minutes(1)))
    func updatingSVNLeavesGitHeadUntouched() async throws {
        guard ToolLocator.find("git") != nil,
              ToolLocator.find("svn") != nil,
              ToolLocator.find("svnadmin") != nil else {
            return
        }

        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        #expect(FileManager.default.fileExists(atPath: fixture.dualWorkingCopy.appendingPathComponent(".svn").path))

        let beforeHeadResult = try await fixture.run(
            executable: "git", arguments: ["rev-parse", "HEAD"], directory: fixture.dualWorkingCopy
        )
        let beforeGitHead = try requireSuccess(beforeHeadResult, tool: "git")
            .output.trimmingCharacters(in: .whitespacesAndNewlines)

        let remoteReadme = fixture.svnWriter.appendingPathComponent("README.md")
        try Data("updated by isolated SVN fixture\n".utf8).write(to: remoteReadme, options: .atomic)
        let commitResult = try await fixture.run(
            executable: "svn", arguments: ["commit", "-m", "fixture svn README update"], directory: fixture.svnWriter
        )
        _ = try requireSuccess(commitResult, tool: "svn")

        let service = RepositoryService(providers: [
            GitProvider(runner: fixture.runner),
            SVNProvider(runner: fixture.runner),
        ])
        let workspace = try await service.open(directory: fixture.dualWorkingCopy)
        #expect(workspace.issues.isEmpty)
        #expect(workspace.bindings.count == 2)
        let svnBinding = try #require(workspace.bindings.first { $0.providerID == .svn })
        #expect(svnBinding.id.hasPrefix("svn:"))

        let operation = try await service.perform(.update, bindingID: svnBinding.id, in: workspace, progress: { _ in })
        if case .succeeded = operation.result.outcome {
            // Expected: the only write target was the local fixture's SVN working copy.
        } else {
            Issue.record("SVN 更新未成功：\(operation.result.details)")
        }
        #expect(operation.result.bindingID == svnBinding.id)
        #expect(operation.snapshots.count == 2)

        let afterHeadResult = try await fixture.run(
            executable: "git", arguments: ["rev-parse", "HEAD"], directory: fixture.dualWorkingCopy
        )
        let afterGitHead = try requireSuccess(afterHeadResult, tool: "git")
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(afterGitHead == beforeGitHead)

        let gitSnapshot = try #require(operation.snapshots.first { $0.binding.providerID == .git })
        let svnSnapshot = try #require(operation.snapshots.first { $0.binding.providerID == .svn })
        #expect(gitSnapshot.issues.isEmpty)
        #expect(svnSnapshot.issues.isEmpty)
        #expect(gitSnapshot.changes.contains { $0.path == "README.md" && $0.kind == .modified })
        #expect(svnSnapshot.changes.allSatisfy { change in
            change.path == ".git" || change.path.hasPrefix(".git/")
        })
    }
}
