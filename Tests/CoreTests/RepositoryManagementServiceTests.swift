import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("仓库管理业务编排")
struct RepositoryManagementServiceTests {
    @Test("打开关联目录会保留主目录并按绑定去重")
    func opensLinkedDirectories() async throws {
        let primary = try temporaryDirectory()
        let linked = try temporaryDirectory()
        let provider = ManagementFixture()
        let service = RepositoryService(providers: [provider])

        let workspace = try await service.open(directory: primary, linkedDirectories: [linked, primary, linked])

        #expect(workspace.directory == primary.standardizedFileURL.resolvingSymlinksInPath())
        #expect(workspace.linkedDirectories == [linked.standardizedFileURL.resolvingSymlinksInPath()])
        #expect(workspace.bindings.count == 2)
    }

    @Test("初始化先确认全部来源均未识别且没有检测错误")
    func initializeRejectsAmbiguousDirectoryBeforeWrite() async throws {
        let directory = try temporaryDirectory()
        let setup = ManagementFixture()
        let failing = DetectionFailureFixture()
        let service = RepositoryService(providers: [setup, failing])
        let request = RepositorySetupRequest(providerID: setup.id, directory: directory)

        await #expect(throws: VersionControlError.self) {
            try await service.initialize(request) { _ in }
        }
        #expect(await setup.initializeCallCount() == 0)
    }

    @Test("管理写操作复核令牌并在结束后刷新关联目录")
    func managementRefreshesLinkedWorkspace() async throws {
        let primary = try temporaryDirectory()
        let linked = try temporaryDirectory()
        let provider = ManagementFixture()
        let service = RepositoryService(providers: [provider])
        let workspace = try await service.open(directory: primary, linkedDirectories: [linked])
        let binding = try #require(workspace.bindings.first)
        let context = try await service.managementContext(in: binding)

        let response = try await service.manage(.init(action: .stage(paths: ["Sources/App.swift"]), stateToken: context.stateToken),
                                                bindingID: binding.id, in: workspace, progress: { _ in })

        #expect(response.result.outcome == .succeeded)
        #expect(response.workspace.linkedDirectories == [linked.standardizedFileURL.resolvingSymlinksInPath()])
        #expect(response.snapshots.count == 2)
        #expect(await provider.managementCallCount() == 1)
    }

    @Test("适配器写阶段异常结果标为未知，状态令牌过期则仍为失败")
    func managementDistinguishesUnknownWriteFromPreflightFailure() async throws {
        let directory = try temporaryDirectory()
        let provider = ManagementFixture(throwsAfterManagement: true)
        let service = RepositoryService(providers: [provider])
        let workspace = try await service.open(directory: directory)
        let binding = try #require(workspace.bindings.first)

        let unknown = try await service.manage(.init(action: .push(remote: "origin", branch: "main", setUpstream: false), stateToken: "state-1"),
                                               bindingID: binding.id, in: workspace, progress: { _ in })
        #expect(unknown.result.outcome == .unknown)

        let failed = try await service.manage(.init(action: .push(remote: "origin", branch: "main", setUpstream: false), stateToken: "stale"),
                                              bindingID: binding.id, in: workspace, progress: { _ in })
        #expect(failed.result.outcome == .failed)
        #expect(await provider.managementCallCount() == 1)
    }

    @Test("管理写操作与其他共享写操作互斥")
    func managementOperationsAreMutuallyExclusive() async throws {
        let directory = try temporaryDirectory()
        let provider = ManagementFixture(managementDelay: .milliseconds(180))
        let service = RepositoryService(providers: [provider])
        let workspace = try await service.open(directory: directory)
        let binding = try #require(workspace.bindings.first)
        let request = RepositoryManagementRequest(action: .stage(paths: ["Sources/App.swift"]), stateToken: "state-1")
        let first = Task { try await service.manage(request, bindingID: binding.id, in: workspace, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(30))

        await #expect(throws: VersionControlError.self) {
            try await service.manage(request, bindingID: binding.id, in: workspace, progress: { _ in })
        }
        _ = try await first.value
    }

    @Test("初始化写阶段异常结果标为未知")
    func initializeWriteFailureIsUnknown() async throws {
        let directory = try temporaryDirectory()
        let provider = ManagementFixture(throwsAfterSetup: true, detectsRepository: false)
        let service = RepositoryService(providers: [provider])

        let result = try await service.initialize(.init(providerID: provider.id, directory: directory)) { _ in }

        #expect(result.outcome == .unknown)
        #expect(await provider.initializeCallCount() == 1)
    }

    @Test("比较差异拒绝不属于比较结果或越出工作副本的文件")
    func comparisonDiffValidatesFileScope() async throws {
        let directory = try temporaryDirectory()
        let provider = ManagementFixture()
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: directory))
        let comparison = try await service.compare(in: binding, from: "old", to: "new")

        await #expect(throws: VersionControlError.self) {
            try await service.comparisonDiff(in: binding, comparison: comparison, path: "../secret")
        }
        await #expect(throws: VersionControlError.self) {
            try await service.comparisonDiff(in: binding, comparison: comparison, path: "Other.swift")
        }
    }

    @Test("比较允许适配器把 HEAD 和分支规范为固定修订号")
    func comparisonAllowsNormalizedRevisionIdentifiers() async throws {
        let directory = try temporaryDirectory()
        let provider = ManagementFixture()
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: directory))

        let comparison = try await service.compare(in: binding, from: "HEAD", to: "feature/demo")

        #expect(comparison.fromRevision == "fixed-from")
        #expect(comparison.toRevision == "fixed-to")
    }

    @Test("仓库根标记仅可用于只读修订比较")
    func comparisonAllowsRootMarkerButWritesStillRejectIt() async throws {
        let directory = try temporaryDirectory()
        let provider = ManagementFixture(comparisonFiles: [FileChange(path: ".", kind: .modified)])
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: directory))

        let comparison = try await service.compare(in: binding, from: "old", to: "new")
        #expect(comparison.files.map(\.path) == ["."])
        let patch = try await service.comparisonDiff(in: binding, comparison: comparison, path: ".")
        #expect(patch.text == ".")
        await #expect(throws: VersionControlError.self) {
            try await service.manage(
                .init(action: .stage(paths: ["."]), stateToken: "state-1"),
                bindingID: binding.id,
                in: Workspace(directory: directory, bindings: [binding], issues: []),
                progress: { _ in }
            )
        }
    }

    @MainActor @Test("关联目录内存存储会规范化、去重并排除主目录")
    func linkStoreUsesNormalizedPaths() throws {
        let primary = try temporaryDirectory()
        let linked = try temporaryDirectory()
        let store = WorkspaceLinkStore()

        store.setDirectories([primary, linked, linked], for: primary)

        #expect(store.directories(for: primary) == [linked.standardizedFileURL.resolvingSymlinksInPath()])
    }

    @MainActor @Test("关联目录持久化会忽略损坏、相对和重复路径")
    func linkStoreFiltersPersistedInvalidPaths() throws {
        let suite = "rephub-link-store-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let key = "links"
        let raw = [
            "/tmp/rephub-main": ["relative/path", "/tmp/rephub-main", "/tmp/rephub-linked", "/tmp/rephub-linked", "bad\u{0}path"],
            "relative-main": ["/tmp/ignored"],
        ]
        defaults.set(try JSONEncoder().encode(raw), forKey: key)

        let store = WorkspaceLinkStore(defaults: defaults, key: key)

        #expect(store.directories(for: URL(fileURLWithPath: "/tmp/rephub-main", isDirectory: true)) == [
            URL(fileURLWithPath: "/tmp/rephub-linked", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath(),
        ])
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class ManagementFixture: RepositorySetupProvider, RepositoryManagementProvider, RepositoryComparisonProvider, @unchecked Sendable {
    let id = ProviderID(rawValue: "management-fixture")
    let displayName = "管理测试"
    let setupOption = RepositorySetupOption(providerID: ProviderID(rawValue: "management-fixture"), title: "管理测试", requiresRemote: false)
    private let calls = ManagementCallLog()
    private let throwsAfterSetup: Bool
    private let throwsAfterManagement: Bool
    private let managementDelay: Duration?
    private let detectsRepository: Bool
    private let comparisonFiles: [FileChange]

    init(throwsAfterSetup: Bool = false, throwsAfterManagement: Bool = false,
         managementDelay: Duration? = nil, detectsRepository: Bool = true,
         comparisonFiles: [FileChange] = [FileChange(path: "Sources/App.swift", kind: .modified)]) {
        self.throwsAfterSetup = throwsAfterSetup
        self.throwsAfterManagement = throwsAfterManagement
        self.managementDelay = managementDelay
        self.detectsRepository = detectsRepository
        self.comparisonFiles = comparisonFiles
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        guard detectsRepository else { return nil }
        return .init(providerID: id, providerName: displayName, root: directory,
                     capabilities: [.history, .staging, .branchManagement, .conflictResolution, .push])
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }

    func initialize(_ request: RepositorySetupRequest, progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositorySetupResult {
        await calls.recordInitialize()
        if throwsAfterSetup { throw VersionControlError.executionFailed("setup fixture failure") }
        return .init(outcome: .succeeded, directory: request.directory, summary: "已初始化")
    }
    func managementContext(in binding: RepositoryBinding) async throws -> RepositoryManagementContext {
        .init(binding: binding, stateToken: "state-1", changes: [FileChange(path: "Sources/App.swift", kind: .modified)])
    }
    func performManagement(_ request: RepositoryManagementRequest, in binding: RepositoryBinding,
                           progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryManagementResult {
        await calls.recordManagement()
        if let managementDelay { try await Task.sleep(for: managementDelay) }
        if throwsAfterManagement { throw VersionControlError.executionFailed("management fixture failure") }
        return .init(outcome: .succeeded, summary: "完成")
    }
    func compare(in binding: RepositoryBinding, from: String, to: String) async throws -> RepositoryComparison {
        .init(fromRevision: "fixed-from", toRevision: "fixed-to", files: comparisonFiles)
    }
    func comparisonDiff(in binding: RepositoryBinding, comparison: RepositoryComparison, path: String) async throws -> RepositoryPatch {
        .init(text: path)
    }
    func initializeCallCount() async -> Int { await calls.initializeCount() }
    func managementCallCount() async -> Int { await calls.managementCount() }
}

private struct DetectionFailureFixture: VersionControlProvider {
    let id = ProviderID(rawValue: "detect-failure")
    let displayName = "故障检测"
    func detect(at directory: URL) async throws -> RepositoryBinding? { throw VersionControlError.toolUnavailable("fixture") }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
}

private actor ManagementCallLog {
    private var initializes = 0
    private var managements = 0
    func recordInitialize() { initializes += 1 }
    func recordManagement() { managements += 1 }
    func initializeCount() -> Int { initializes }
    func managementCount() -> Int { managements }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
