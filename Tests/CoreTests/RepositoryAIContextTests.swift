import Foundation
import Testing
import AICore
import RepositoryApplication
import VersionControlCore

@Suite("AI 仓库上下文")
struct RepositoryAIContextTests {
    @Test("工作区上下文只包含选中的文件，且不暴露本地位置或远端")
    func workingCopyFiltersSelectedFiles() async throws {
        let provider = ContextFixtureProvider()
        let service = RepositoryService(providers: [provider])
        let binding = provider.binding
        let context = try await RepositoryAIContextService(service: service)
            .workingCopy(in: binding, selectedPaths: ["Sources/One.swift"])

        #expect(context.files.map(\.path) == ["Sources/One.swift"])
        #expect(context.files[0].patch.contains("one change"))
        #expect(context.sourceLabel == "上下文测试 · 工作区变更")
        #expect(context.basis.contains("基准版本 base-main 与当前工作区比较"))
        #expect(!context.files[0].patch.contains(binding.root.path))
        #expect(!context.sourceLabel.contains(binding.root.path))
        #expect(!context.basis.contains("private-token"))
    }

    @Test("提交上下文在读取前后核对基准与选中文件指纹")
    func commitRejectsChangedFileDuringRead() async throws {
        let provider = ContextFixtureProvider(changeAfterFirstCommitDiff: true)
        let service = RepositoryService(providers: [provider])
        let binding = provider.binding
        let preparation = try #require(try await service.prepareCommits(in: .init(directory: binding.root, bindings: [binding], issues: [])).first)
        let builder = RepositoryAIContextService(service: service)

        await #expect(throws: AIError.self) {
            _ = try await builder.commit(in: preparation, selectedPaths: ["Sources/One.swift"])
        }
    }

    @Test("历史提交只读取该提交中被选中的文件")
    func revisionFiltersChangedFiles() async throws {
        let provider = ContextFixtureProvider()
        let service = RepositoryService(providers: [provider])
        let binding = provider.binding
        let builder = RepositoryAIContextService(service: service)
        let context = try await builder.revision(in: binding, revision: "r42", selectedPaths: ["Docs/Guide.md"])

        #expect(context.sourceLabel == "上下文测试 · 历史提交变更")
        #expect(context.files.map(\.path) == ["Docs/Guide.md"])
        #expect(context.files[0].patch.contains("guide revision"))
        #expect(context.basis.contains("历史提交 r42 与其父版本比较"))
        await #expect(throws: AIError.self) {
            _ = try await builder.revision(in: binding, revision: "r42", selectedPaths: ["Sources/NotInRevision.swift"])
        }
    }

    @Test("过大或已截断的差异不会被静默截断后发送")
    func rejectsOversizedOrTruncatedPatch() async throws {
        let provider = ContextFixtureProvider(patches: ["Sources/One.swift": .init(text: String(repeating: "x", count: 256 * 1024))])
        let service = RepositoryService(providers: [provider])
        let binding = provider.binding
        let builder = RepositoryAIContextService(service: service)
        await #expect(throws: AIError.self) {
            _ = try await builder.workingCopy(in: binding, selectedPaths: ["Sources/One.swift"])
        }
    }

    @Test("二进制文件以明确标记提供，不伪造文本审查内容")
    func marksBinaryFilesExplicitly() async throws {
        let provider = ContextFixtureProvider(patches: ["Sources/One.swift": .init(text: "Binary files a and b differ")])
        let service = RepositoryService(providers: [provider])
        let binding = provider.binding
        let context = try await RepositoryAIContextService(service: service)
            .workingCopy(in: binding, selectedPaths: ["Sources/One.swift"])
        #expect(context.files[0].patch.contains("二进制文件"))
        #expect(context.basis.contains("没有可供审查的文本差异"))
    }

    @Test("普通源码中的 Binary files 字符串不会被误判为二进制差异")
    func preservesSourceContainingBinaryPhrase() async throws {
        let patch = "diff --git a/Sources/One.swift b/Sources/One.swift\n+let notice = \"Binary files a and b differ\""
        let provider = ContextFixtureProvider(patches: ["Sources/One.swift": .init(text: patch)])
        let service = RepositoryService(providers: [provider])
        let context = try await RepositoryAIContextService(service: service)
            .workingCopy(in: provider.binding, selectedPaths: ["Sources/One.swift"])
        #expect(context.files[0].patch == patch)
    }

    @Test("快照标识包含所选文件指纹，即使差异文本和基准版本相同也会变化")
    func snapshotIncludesSelectedFileFingerprint() async throws {
        let provider = ContextFixtureProvider()
        let service = RepositoryService(providers: [provider])
        let builder = RepositoryAIContextService(service: service)
        let first = try await builder.workingCopy(in: provider.binding, selectedPaths: ["Sources/One.swift"])
        await provider.setFingerprintSeed("changed")
        let second = try await builder.workingCopy(in: provider.binding, selectedPaths: ["Sources/One.swift"])
        #expect(first.files == second.files)
        #expect(first.snapshotID != second.snapshotID)
    }
}

private actor ContextFixtureProvider: RepositoryCommitProvider {
    nonisolated let id = ProviderID(rawValue: "ai-context-fixture")
    nonisolated let displayName = "上下文测试"
    nonisolated let binding: RepositoryBinding
    private let changeAfterFirstCommitDiff: Bool
    private var fingerprintSeed: String
    private var generation = 0
    private var didReadCommitDiff = false
    private let patches: [String: RepositoryPatch]

    init(changeAfterFirstCommitDiff: Bool = false, patches: [String: RepositoryPatch] = [:]) {
        self.changeAfterFirstCommitDiff = changeAfterFirstCommitDiff
        self.fingerprintSeed = "original"
        self.patches = patches
        self.binding = RepositoryBinding(providerID: id, providerName: displayName,
            root: FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-AIContext-\(UUID().uuidString)"),
            currentBranch: "main", remoteURL: "https://user:private-token@example.invalid/repository",
            capabilities: [.status, .diff, .history, .commit])
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? { binding }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] {
        guard revision == "r42" else { return [] }
        return [.init(path: "Docs/Guide.md", kind: .modified), .init(path: "Sources/Old.swift", kind: .deleted)]
    }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        guard revision == "r42", let path else { return .init(text: "") }
        return path == "Docs/Guide.md" ? .init(text: "diff --guide revision") : .init(text: "diff --old revision")
    }
    func prepareCommit(in binding: RepositoryBinding) async throws -> RepositoryCommitPreparation {
        let files = ["Sources/One.swift", "Sources/Two.swift"].map {
            RepositoryCommitFile(change: .init(path: $0, kind: .modified), fingerprint: "\(fingerprintSeed)-g\(generation)-\($0)")
        }
        return .init(binding: self.binding, baseRevision: "base-main", files: files)
    }
    func setFingerprintSeed(_ value: String) { fingerprintSeed = value }
    func commitDiff(in binding: RepositoryBinding, file: RepositoryCommitFile) async throws -> RepositoryPatch {
        if changeAfterFirstCommitDiff && !didReadCommitDiff {
            didReadCommitDiff = true
            generation += 1
        }
        return patches[file.change.path] ?? .init(text: "diff -- \(file.change.path)\n+one change")
    }
    func commit(_ request: RepositoryCommitRequest, in binding: RepositoryBinding,
                progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryCommitResult {
        .init(bindingID: binding.id, outcome: .succeeded, summary: "unused")
    }
}
