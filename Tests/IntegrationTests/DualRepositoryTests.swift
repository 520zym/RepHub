import Foundation
import Testing
import GitAdapter
import RepositoryApplication
import SVNAdapter
import ToolExecution
import VersionControlCore

@Suite("Git 与 SVN 同目录集成")
struct DualRepositoryTests {
    @Test("RepositoryService 可识别同目录 Git 和 SVN，并读取两侧状态与差异")
    func readsDualRepositoryWorkingCopy() async throws {
        guard ToolLocator.find("svn") != nil,
              ToolLocator.find("svnadmin") != nil,
              ToolLocator.find("git") != nil else {
            throw FixtureError.toolUnavailable
        }

        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }

        let repository = temporary.appendingPathComponent("repository", isDirectory: true)
        let seed = temporary.appendingPathComponent("seed", isDirectory: true)
        let checkout = temporary.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        let sharedFile = seed.appendingPathComponent("shared.txt")
        try "before\n".write(to: sharedFile, atomically: true, encoding: .utf8)

        try await command("svnadmin", ["create", repository.path], directory: nil)
        try await command("svn", ["import", seed.path, repository.absoluteURL.absoluteString, "-m", "initial"], directory: nil)
        try await command("svn", ["checkout", repository.absoluteURL.absoluteString, checkout.path], directory: nil)

        try await command("git", ["init", "-q"], directory: checkout)
        try await command("git", ["config", "user.name", "RepHub Integration"], directory: checkout)
        try await command("git", ["config", "user.email", "integration@example.invalid"], directory: checkout)
        try await command("git", ["add", "--", "shared.txt"], directory: checkout)
        try await command("git", ["commit", "-qm", "initial"], directory: checkout)

        try "after\n".write(to: checkout.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)

        let service = RepositoryService(providers: [GitProvider(), SVNProvider()])
        let workspace = try await service.open(directory: checkout)
        #expect(workspace.issues.isEmpty)
        #expect(workspace.bindings.count == 2)

        let gitBinding = try #require(workspace.bindings.first { $0.providerID == .git })
        let svnBinding = try #require(workspace.bindings.first { $0.providerID == .svn })
        let gitSnapshot = await service.load(gitBinding)
        let svnSnapshot = await service.load(svnBinding)
        #expect(gitSnapshot.issues.isEmpty)
        #expect(svnSnapshot.issues.isEmpty)
        #expect(gitSnapshot.changes.contains { $0.path == "shared.txt" && $0.kind == .modified })
        #expect(svnSnapshot.changes.contains { $0.path == "shared.txt" && $0.kind == .modified })

        let gitPatch = try await service.diff(in: gitBinding, path: "shared.txt", revision: nil)
        let svnPatch = try await service.diff(in: svnBinding, path: "shared.txt", revision: nil)
        #expect(gitPatch.text.contains("-before"))
        #expect(gitPatch.text.contains("+after"))
        #expect(svnPatch.text.contains("-before"))
        #expect(svnPatch.text.contains("+after"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rephub-dual-repository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func command(_ executable: String, _ arguments: [String], directory: URL?) async throws {
        let result = try await CommandRunner().run(executable: executable, arguments: arguments, directory: directory)
        guard result.exitCode == 0 else {
            throw FixtureError.command(executable, result.error)
        }
    }

    private enum FixtureError: Error {
        case toolUnavailable
        case command(String, String)
    }
}
