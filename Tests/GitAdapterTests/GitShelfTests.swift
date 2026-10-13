import Foundation
import Testing
import GitAdapter
import ToolExecution
import TestSupport
import VersionControlCore

@Suite("Git 搁置")
struct GitShelfTests {
    @Test("只保存快照会保留工作区，恢复后记录仍存在")
    func saveOnlyAndRestoreKeepsRecord() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["config", "user.name", "Fixture"], directory: fixture.gitReader), tool: "git")
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["config", "user.email", "fixture@example.invalid"], directory: fixture.gitReader), tool: "git")
        try "changed\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: fixture.gitReader.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let preview = try await provider.shelfPreview(in: binding, includeUntracked: true)
        #expect(preview.files.map(\.path).sorted() == ["README.md", "note.txt"])
        let record = try await provider.createShelf(in: binding, name: "fixture", includeUntracked: true,
                                                    mode: .saveOnly, expectedStateToken: preview.stateToken)
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent("README.md"), encoding: .utf8) == "changed\n")
        #expect(FileManager.default.fileExists(atPath: fixture.gitReader.appendingPathComponent("note.txt").path))
        try requireSuccess(try await fixture.run(executable: "git", arguments: ["reset", "--hard", "HEAD"], directory: fixture.gitReader), tool: "git")
        try? FileManager.default.removeItem(at: fixture.gitReader.appendingPathComponent("note.txt"))
        _ = try await provider.restoreShelf(in: binding, record: record)
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent("README.md"), encoding: .utf8) == "changed\n")
        #expect(FileManager.default.fileExists(atPath: fixture.gitReader.appendingPathComponent("note.txt").path))
        #expect(try await provider.shelves(in: binding).contains { $0.id == record.id })
    }
}
