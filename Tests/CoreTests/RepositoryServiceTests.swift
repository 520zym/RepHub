import Foundation
import Testing
import VersionControlCore
import RepositoryApplication
import ToolExecution

@Suite("版本控制契约与业务隔离")
struct RepositoryServiceTests {
    @Test("一个目录可以识别两个适配器，新增工具无需修改业务")
    func multipleProviders() async throws {
        let directory = FileManager.default.temporaryDirectory
        let service = RepositoryService(providers: [FixtureProvider(id: .git), FixtureProvider(id: ProviderID(rawValue: "custom"))])
        let workspace = try await service.open(directory: directory)
        #expect(workspace.bindings.count == 2)
        #expect(!workspace.isUnmanaged)
        #expect(workspace.issues.isEmpty)
    }

    @Test("检测失败不能误报为未管理目录")
    func detectionFailure() async throws {
        let service = RepositoryService(providers: [FixtureProvider(id: .svn, failDetection: true)])
        let workspace = try await service.open(directory: FileManager.default.temporaryDirectory)
        #expect(workspace.bindings.isEmpty)
        #expect(!workspace.isUnmanaged)
        #expect(workspace.issues.count == 1)
        let empty = try await RepositoryService(providers: []).open(directory: FileManager.default.temporaryDirectory)
        #expect(empty.isUnmanaged)
    }

    @Test("远端历史读取失败仍保留本地变更")
    func partialSnapshot() async throws {
        let provider = FixtureProvider(id: .svn, failHistory: true)
        let directory = FileManager.default.temporaryDirectory
        let binding = try #require(await provider.detect(at: directory))
        let snapshot = await RepositoryService(providers: [provider]).load(binding)
        #expect(snapshot.changes.first?.path == "local.txt")
        #expect(snapshot.revisions.isEmpty)
        #expect(snapshot.issues.count == 1)
    }
}

private struct FixtureProvider: VersionControlProvider {
    let id: ProviderID
    var displayName: String { "测试工具" }
    var failDetection = false
    var failHistory = false
    func detect(at directory: URL) async throws -> RepositoryBinding? {
        if failDetection { throw VersionControlError.toolUnavailable("测试工具") }
        return RepositoryBinding(providerID: id, providerName: displayName, root: directory, capabilities: [.status, .history, .diff])
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        [FileChange(path: "local.txt", kind: .modified)]
    }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        if failHistory { throw VersionControlError.timedOut("历史") }
        return []
    }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { RepositoryPatch(text: "") }
}

@Suite("工具执行")
struct CommandRunnerTests {
    @Test("错误展示隐藏 URL 中的凭据")
    func redactsCredentials() {
        let result = CommandResult(data: Data(), errorData: Data("https://user:secret@example.invalid/repo?token=abc".utf8), exitCode: 1)
        do { try requireSuccess(result, tool: "git"); Issue.record("应失败") }
        catch {
            #expect(!error.localizedDescription.contains("secret"))
            #expect(!error.localizedDescription.contains("abc"))
            #expect(error.localizedDescription.contains("example.invalid"))
        }
    }

    @Test("参数原样传递，不经过shell解释")
    func literalArguments() async throws {
        let result = try await CommandRunner().run(executable: "/bin/echo", arguments: ["$(whoami)", "a;b", "中文 空格"])
        #expect(result.output == "$(whoami) a;b 中文 空格\n")
        #expect(result.exitCode == 0)
    }

    @Test("长任务超时可终止")
    func timeout() async throws {
        do {
            _ = try await CommandRunner().run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.1)
            Issue.record("应抛出超时错误")
        } catch VersionControlError.timedOut { }
    }

    @Test("取消可结束运行中的命令")
    func cancellation() async throws {
        let task = Task { try await CommandRunner().run(executable: "/bin/sleep", arguments: ["5"]) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { _ = try await task.value; Issue.record("应取消") }
        catch is CancellationError { }
    }
}
