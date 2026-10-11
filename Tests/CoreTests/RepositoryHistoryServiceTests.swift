import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("文件历史业务编排")
struct RepositoryHistoryServiceTests {
    @Test("文件历史直接查询适配器，独立同步失败仍保留文件历史")
    func loadsFileHistoryIndependently() async throws {
        let provider = HistoryServiceFixture()
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: FileManager.default.temporaryDirectory))
        let repository = await service.load(binding)
        #expect(repository.revisions.first?.id == "repository")
        #expect(repository.syncStatus == nil)
        #expect(repository.issues.count == 1)
        let file = try await service.fileHistory(in: binding, path: "历史 文件.swift", reference: "anchor")
        #expect(file.path == "历史 文件.swift")
        #expect(file.entries.first?.revision.id == "old-file")
        #expect(file.entries.first?.pegRevision == "anchor")
        #expect(file.syncStatus == nil)
        #expect(file.issues.count == 1)
        #expect(!file.issues[0].contains("secret"))
        let entry = try #require(file.entries.first)
        let patch = try await service.fileHistoryDiff(in: binding, entry: entry)
        #expect(patch.text == "历史 文件.swift@anchor")
    }

    @Test("文件历史与历史差异拒绝越出工作区的路径")
    func rejectsEscapingPaths() async throws {
        let provider = HistoryServiceFixture()
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: FileManager.default.temporaryDirectory))
        for path in ["../secret", "folder/../../secret", "/tmp/secret", "", "a/./b", "a\0b"] {
            do {
                _ = try await service.fileHistory(in: binding, path: path)
                Issue.record("应拒绝越界或无效文件路径")
            } catch VersionControlError.invalidRepository { }
            do {
                _ = try await service.fileHistoryDiff(in: binding, entry: .init(revision: .init(id: "r1", author: "", date: .distantPast, message: ""), path: path))
                Issue.record("历史差异也应拒绝无效路径")
            } catch VersionControlError.invalidRepository { }
        }
    }
}

private struct HistoryServiceFixture: RepositoryHistoryProvider {
    let id = ProviderID(rawValue: "history-fixture")
    let displayName = "历史测试"
    func detect(at directory: URL) async throws -> RepositoryBinding? {
        .init(providerID: id, providerName: displayName, root: directory, capabilities: [.history, .fileHistory, .synchronization])
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        [.init(id: "repository", author: "", date: .distantPast, message: "仓库历史")]
    }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
    func fileHistory(in binding: RepositoryBinding, path: String, limit: Int, reference: String?) async throws -> [FileHistoryEntry] {
        [.init(revision: .init(id: "old-file", author: "", date: .distantPast, message: "范围之外的文件提交"), path: path, pegRevision: reference)]
    }
    func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch {
        .init(text: entry.path + "@" + (entry.pegRevision ?? ""))
    }
    func synchronization(in binding: RepositoryBinding, revisions: [Revision], path: String?) async throws -> RepositorySyncStatus {
        throw VersionControlError.executionFailed("读取 https://user:secret@example.invalid/repo 失败")
    }
}
