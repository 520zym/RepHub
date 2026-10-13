import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("Git 逐行追溯")
struct GitInspectionTests {
    @Test("固定 HEAD 提交追溯，不读取未提交修改")
    func blamesCommittedContentOnly() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let file = fixture.gitReader.appendingPathComponent("trace.swift")
        try "let value = 1\nlet stable = true\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["add", "trace.swift"], directory: fixture.gitReader), tool: "git")
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["commit", "-m", "add trace"], directory: fixture.gitReader), tool: "git")
        let committed = try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-parse", "HEAD"], directory: fixture.gitReader), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        try "let value = 99\nlet stable = true\n".write(to: file, atomically: true, encoding: .utf8)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let result = try await provider.blame(in: binding, path: "trace.swift", reference: nil)

        #expect(result.reference == committed)
        #expect(result.lines.map(\.content) == ["let value = 1", "let stable = true"])
        #expect(result.lines.allSatisfy { $0.revision.id == committed })
    }

    @Test("未跟踪文件明确不能追溯")
    func rejectsUntrackedFile() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try "temporary\n".write(to: fixture.gitReader.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        await #expect(throws: VersionControlError.self) {
            try await provider.blame(in: binding, path: "new.txt", reference: nil)
        }
    }
}
