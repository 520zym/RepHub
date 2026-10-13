import Foundation
import Testing
import GitAdapter
import RepositoryApplication
import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("忽略规则服务")
struct RepositoryIgnoreIntegrationTests {
    @Test("Git 忽略规则经服务预览后写入，不创建提交")
    func writesGitIgnoreWithoutCommit() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try "scratch\n".write(to: fixture.gitReader.appendingPathComponent("scratch.log"), atomically: true, encoding: .utf8)
        let git = GitProvider(runner: fixture.runner)
        let service = RepositoryService(providers: [git])
        let binding = try #require(await git.detect(at: fixture.gitReader))
        let prepared = try await service.prepareIgnore(in: binding)
        let candidate = try #require(prepared.candidates.first { $0.path == "scratch.log" })
        let request = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: candidate.defaultRule, scope: .repository)
        let preview = try await service.previewIgnore(request, in: binding)
        #expect(preview.after.contains("/scratch.log"))
        let confirmed = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: candidate.defaultRule,
                                                scope: .repository, previewToken: preview.stateToken)
        let result = try await service.applyIgnore(confirmed, in: binding, progress: { _ in })
        #expect(result.summary.contains("尚未暂存或提交"))
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent(".gitignore"), encoding: .utf8) == "/scratch.log\n")
        let subject = try requireSuccess(try await fixture.run(executable: "git", arguments: ["log", "-1", "--format=%s"], directory: fixture.gitReader), tool: "git").output
        #expect(subject.trimmingCharacters(in: .whitespacesAndNewlines) == "fixture initial commit")
    }

    @Test("Git 当前文件夹规则命中嵌套未跟踪文件")
    func nestedGitIgnoreMatchesCandidate() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let logs = fixture.gitReader.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "trace\n".write(to: logs.appendingPathComponent("runtime.log"), atomically: true, encoding: .utf8)
        let git = GitProvider(runner: fixture.runner)
        let service = RepositoryService(providers: [git])
        let binding = try #require(await git.detect(at: fixture.gitReader))
        let candidate = try #require((try await service.prepareIgnore(in: binding)).candidates.first { $0.path == "logs/runtime.log" })
        let previewRequest = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: "runtime.log", scope: .currentDirectory)
        let preview = try await service.previewIgnore(previewRequest, in: binding)
        let request = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: "runtime.log", scope: .currentDirectory, previewToken: preview.stateToken)
        _ = try await service.applyIgnore(request, in: binding, progress: { _ in })
        let check = try await fixture.run(executable: "git", arguments: ["check-ignore", "-q", "--", "logs/runtime.log"], directory: fixture.gitReader)
        #expect(check.exitCode == 0)
        #expect(try String(contentsOf: logs.appendingPathComponent(".gitignore"), encoding: .utf8) == "runtime.log\n")
    }

    @Test("Git 预览后 .gitignore 变化会拒绝写入")
    func rejectsGitIgnoreChangedAfterPreview() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try "draft\n".write(to: fixture.gitReader.appendingPathComponent("draft.log"), atomically: true, encoding: .utf8)
        let git = GitProvider(runner: fixture.runner)
        let service = RepositoryService(providers: [git])
        let binding = try #require(await git.detect(at: fixture.gitReader))
        let candidate = try #require((try await service.prepareIgnore(in: binding)).candidates.first { $0.path == "draft.log" })
        let previewRequest = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: candidate.defaultRule, scope: .repository)
        let preview = try await service.previewIgnore(previewRequest, in: binding)
        try "# outside edit\n".write(to: fixture.gitReader.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let request = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: candidate.defaultRule, scope: .repository, previewToken: preview.stateToken)
        await #expect(throws: VersionControlError.self) { try await service.applyIgnore(request, in: binding, progress: { _ in }) }
    }

    @Test("Git 字面特殊文件名不会被解释为通配规则")
    func escapesSpecialGitIgnoreName() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let name = "cache[one]*?.tmp"
        try "cache\n".write(to: fixture.gitReader.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let git = GitProvider(runner: fixture.runner)
        let service = RepositoryService(providers: [git])
        let binding = try #require(await git.detect(at: fixture.gitReader))
        let candidate = try #require((try await service.prepareIgnore(in: binding)).candidates.first { $0.path == name })
        let previewRequest = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: candidate.defaultRule, scope: .repository)
        let preview = try await service.previewIgnore(previewRequest, in: binding)
        let request = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: candidate.defaultRule, scope: .repository, previewToken: preview.stateToken)
        _ = try await service.applyIgnore(request, in: binding, progress: { _ in })
        let check = try await fixture.run(executable: "git", arguments: ["check-ignore", "-q", "--", name], directory: fixture.gitReader)
        #expect(check.exitCode == 0)
    }

    @Test("SVN 当前父目录的忽略规则保留为未提交属性修改")
    func writesSVNParentIgnoreProperty() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try "cache\n".write(to: fixture.svnReader.appendingPathComponent("build-cache"), atomically: true, encoding: .utf8)
        let svn = SVNProvider(runner: fixture.runner)
        let service = RepositoryService(providers: [svn])
        let binding = try #require(await svn.detect(at: fixture.svnReader))
        let candidate = try #require((try await service.prepareIgnore(in: binding)).candidates.first { $0.path == "build-cache" })
        let previewRequest = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: "build-cache", scope: .currentDirectory)
        let preview = try await service.previewIgnore(previewRequest, in: binding)
        let request = RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: "build-cache", scope: .currentDirectory, previewToken: preview.stateToken)
        _ = try await service.applyIgnore(request, in: binding, progress: { _ in })
        let property = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["propget", "--strict", "svn:ignore", "--", "."], directory: fixture.svnReader), tool: "svn").output
        #expect(property == "build-cache\n")
    }
}
