import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("历史文档预览服务", .serialized)
struct RepositoryDocumentPreviewTests {
    @Test("将指定历史节点的实际内容写入保留扩展名的私有快照")
    func writesHistoricalContentIntoSnapshot() async throws {
        let provider = DocumentFixtureProvider(result: .data(Data("%PDF-历史节点".utf8)))
        let service = RepositoryService(providers: [provider])
        let preview = try await service.documentPreview(in: binding(for: provider), path: "资料/说明.pdf",
                                                        revision: "r42", pegRevision: "r7")

        let url = try #require(preview.systemPreviewURL)
        #expect(url.pathExtension == "pdf")
        #expect(try Data(contentsOf: url) == Data("%PDF-历史节点".utf8))
        #expect(preview.documentKind == .pdf)
        #expect(preview.revisionID == "r42")
        #expect(preview.message?.contains("实际内容") == true)
        #expect(await provider.request == .init(path: "资料/说明.pdf", revision: "r42", pegRevision: "r7"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("快照随预览对象释放而清理自己的私有目录")
    func releasesSnapshotDirectory() async throws {
        let provider = DocumentFixtureProvider(result: .data(Data("document".utf8)))
        let service = RepositoryService(providers: [provider])
        var preview: WorkspaceFilePreview? = try await service.documentPreview(
            in: binding(for: provider), path: "说明.docx", revision: "r1"
        )
        let fileURL = try #require(preview?.systemPreviewURL)
        let directory = fileURL.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        preview = nil
        await Task.yield()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("不存在、超限和非法路径不会生成快照")
    func handlesMissingLimitedAndUnsafeFiles() async throws {
        let missingProvider = DocumentFixtureProvider(result: .missing)
        let missingService = RepositoryService(providers: [missingProvider])
        let missing = try await missingService.documentPreview(in: binding(for: missingProvider), path: "丢失.xlsx", revision: "r9")
        #expect(missing.systemPreviewURL == nil)
        #expect(missing.revisionID == "r9")
        #expect(missing.message?.contains("可能已删除") == true)

        let largeProvider = DocumentFixtureProvider(result: .data(Data(repeating: 7, count: 16 * 1_024 * 1_024 + 1)))
        let largeService = RepositoryService(providers: [largeProvider])
        let large = try await largeService.documentPreview(in: binding(for: largeProvider), path: "附件.pptx", revision: "r10")
        #expect(large.systemPreviewURL == nil)
        #expect(large.message?.contains("16 MiB") == true)

        let providerLimited = DocumentFixtureProvider(result: .outputTooLarge)
        let providerLimitedService = RepositoryService(providers: [providerLimited])
        let limited = try await providerLimitedService.documentPreview(
            in: binding(for: providerLimited), path: "远端.pdf", revision: "r11"
        )
        #expect(limited.systemPreviewURL == nil)
        #expect(limited.message?.contains("16 MiB") == true)

        for path in ["../secret.pdf", "/tmp/secret.pdf", "folder\\secret.pdf", "folder//secret.pdf"] {
            await #expect(throws: VersionControlError.self) {
                try await missingService.documentPreview(in: binding(for: missingProvider), path: path, revision: "r1")
            }
        }
    }

    @Test("取消读取时不产生快照")
    func cancellationLeavesNoSnapshot() async throws {
        let provider = DocumentFixtureProvider(result: .delayed(Data("content".utf8)))
        let service = RepositoryService(providers: [provider])
        let before = snapshotDirectoryNames()
        let task = Task {
            try await service.documentPreview(in: binding(for: provider), path: "说明.pdf", revision: "r1")
        }
        await provider.waitUntilRequested()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(snapshotDirectoryNames() == before)
    }

    private func binding(for provider: DocumentFixtureProvider) -> RepositoryBinding {
        .init(providerID: provider.id, providerName: provider.displayName,
              root: FileManager.default.temporaryDirectory, capabilities: [.history, .fileHistory])
    }
}

private actor DocumentFixtureProvider: RepositoryFileContentProvider {
    struct Request: Equatable, Sendable {
        let path: String
        let revision: String
        let pegRevision: String?
    }

    enum Result: Sendable {
        case data(Data)
        case missing
        case delayed(Data)
        case outputTooLarge
    }

    nonisolated let id = ProviderID(rawValue: "document-fixture")
    nonisolated let displayName = "文档测试"
    private let result: Result
    private(set) var request: Request?

    init(result: Result) { self.result = result }

    func detect(at directory: URL) async throws -> RepositoryBinding? { nil }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }

    func fileContent(in binding: RepositoryBinding, path: String, revision: String,
                     pegRevision: String?) async throws -> Data? {
        request = .init(path: path, revision: revision, pegRevision: pegRevision)
        switch result {
        case .data(let data): return data
        case .missing: return nil
        case .outputTooLarge: throw VersionControlError.outputTooLarge
        case .delayed(let data):
            try await Task.sleep(for: .seconds(30))
            try Task.checkCancellation()
            return data
        }
    }

    func waitUntilRequested() async {
        while request == nil { await Task.yield() }
    }

}

private func snapshotDirectoryNames() -> Set<String> {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
    return Set(contents.filter { $0.hasPrefix("RepHub-HistoryDocument-") })
}
