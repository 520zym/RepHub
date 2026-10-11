import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("提交编排")
struct RepositoryCommitTests {
    @Test("双目标总是 Git 后 SVN，且每个目标使用独立文件和说明")
    func commitsInStableOrderWithIndependentRequests() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = CommitFixtureProvider(id: .git, root: root, revision: "g1")
        let svn = CommitFixtureProvider(id: .svn, root: root, revision: "s1")
        let service = RepositoryService(providers: [svn, git])
        let workspace = try await service.open(directory: root)
        let preparations = try await service.prepareCommits(in: workspace)
        let gitPreparation = try #require(preparations.first { $0.binding.providerID == .git })
        let svnPreparation = try #require(preparations.first { $0.binding.providerID == .svn })
        let progress = CommitProgressCollector()
        let result = try await service.commit([
            request(gitPreparation, file: 0, message: "Git message"),
            request(svnPreparation, file: 1, message: "SVN message")
        ], in: workspace, progress: { await progress.append($0) })
        #expect(result.results.map(\.bindingID) == [gitPreparation.binding.id, svnPreparation.binding.id])
        #expect(result.results.map { $0.outcome.rawValue } == ["succeeded", "succeeded"])
        #expect(await git.committedMessages == ["Git message"])
        #expect(await svn.committedMessages == ["SVN message"])
        #expect(await git.committedPaths == [["git-one.txt"]])
        #expect(await svn.committedPaths == [["svn-two.txt"]])
        #expect(result.snapshots.count == 2)
        #expect(await git.statusCalls == 1)
        #expect(await svn.statusCalls == 1)
        #expect(!result.results.map { $0.summary + $0.details }.joined().contains("private-token"))
        #expect(!(await progress.visibleText()).contains("private-token"))
    }

    @Test("仅请求的目标会提交")
    func commitsOnlySelectedTarget() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let git = CommitFixtureProvider(id: .git, root: root, revision: "g1")
        let svn = CommitFixtureProvider(id: .svn, root: root, revision: "s1")
        let service = RepositoryService(providers: [git, svn])
        let workspace = try await service.open(directory: root)
        let preparations = try await service.prepareCommits(in: workspace)
        let prep = try #require(preparations.first { $0.binding.providerID == .svn })
        let result = try await service.commit([request(prep, file: 0, message: "svn only")], in: workspace, progress: { _ in })
        #expect(result.results.map(\.bindingID) == [prep.binding.id])
        #expect(await git.commitCalls == 0)
        #expect(await svn.commitCalls == 1)
    }

    @Test("普通失败仍继续；未知和取消停止后续目标")
    func failurePolicyIsExplicit() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let git = CommitFixtureProvider(id: .git, root: root, revision: "g1", nextOutcome: .failed)
        let svn = CommitFixtureProvider(id: .svn, root: root, revision: "s1")
        let service = RepositoryService(providers: [git, svn])
        let workspace = try await service.open(directory: root)
        let requests = try await requestsForAll(service, workspace)
        let failed = try await service.commit(requests, in: workspace, progress: { _ in })
        #expect(failed.results.map { $0.outcome.rawValue } == ["failed", "succeeded"])

        await git.setOutcome(.unknown)
        let unknown = try await service.commit(try await requestsForAll(service, workspace), in: workspace, progress: { _ in })
        #expect(unknown.results.map { $0.outcome.rawValue } == ["unknown", "notStarted"])
        #expect(await svn.commitCalls == 1)

        await git.setOutcome(.cancelled)
        let cancelled = try await service.commit(try await requestsForAll(service, workspace), in: workspace, progress: { _ in })
        #expect(cancelled.results.map { $0.outcome.rawValue } == ["cancelled", "notStarted"])
    }

    @Test("任一预检失败时不写入任一目标，并标记后续未开始")
    func preflightFailurePreventsAllWrites() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let git = CommitFixtureProvider(id: .git, root: root, revision: "g1", blockingReason: "https://user:private-token@example.invalid blocked")
        let svn = CommitFixtureProvider(id: .svn, root: root, revision: "s1")
        let service = RepositoryService(providers: [git, svn])
        let workspace = try await service.open(directory: root)
        let response = try await service.commit(try await requestsForAll(service, workspace), in: workspace, progress: { _ in })
        #expect(response.results.map { $0.outcome.rawValue } == ["failed", "notStarted"])
        #expect(await git.commitCalls == 0)
        #expect(await svn.commitCalls == 0)
        #expect(!response.results[0].details.contains("private-token"))
    }

    @Test("过期基准、文件变化、版本元数据与越界路径均在写入前拒绝")
    func rejectsUnsafeOrStaleRequestsBeforeWrite() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let git = CommitFixtureProvider(id: .git, root: root, revision: "g1")
        let service = RepositoryService(providers: [git])
        let workspace = try await service.open(directory: root)
        let preparations = try await service.prepareCommits(in: workspace)
        let preparation = try #require(preparations.first)
        let selected = preparation.files[0]
        let stale = RepositoryCommitRequest(bindingID: preparation.binding.id, baseRevision: "old", files: [selected], message: "stale")
        let staleResult = try await service.commit([stale], in: workspace, progress: { _ in })
        #expect(staleResult.results.first?.outcome.rawValue == "failed")
        #expect(await git.commitCalls == 0)
        for path in [".git/config", "../escape", "bad\u{0000}path"] {
            let unsafe = RepositoryCommitFile(change: .init(path: path, kind: .modified), fingerprint: "fp")
            let request = RepositoryCommitRequest(bindingID: preparation.binding.id, baseRevision: preparation.baseRevision, files: [unsafe], message: "unsafe")
            await #expect(throws: VersionControlError.self) {
                _ = try await service.commit([request], in: workspace, progress: { _ in })
            }
        }
    }

    @Test("提交与更新、获取共享同一写入互斥锁")
    func serializesCommitWithUpdateAndAcquisition() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let git = CommitFixtureProvider(id: .git, root: root, revision: "g1", blocksWrites: true)
        let service = RepositoryService(providers: [git])
        let workspace = try await service.open(directory: root)
        let preparations = try await service.prepareCommits(in: workspace)
        let preparation = try #require(preparations.first)
        let request = request(preparation, file: 0, message: "serialized")
        let beforeUpdate = await git.writeCount
        let update = Task { try await service.perform(.update, bindingID: preparation.binding.id, in: workspace, progress: { _ in }) }
        await git.waitForWrite(after: beforeUpdate)
        await #expect(throws: VersionControlError.self) {
            _ = try await service.commit([request], in: workspace, progress: { _ in })
        }
        update.cancel()
        _ = try await update.value

        let beforeAcquisition = await git.writeCount
        let acquisition = Task { try await service.acquire(providerID: .git,
            location: .init(url: "https://example.invalid/repo"), destinationParent: root,
            directoryName: "checkout", progress: { _ in }) }
        await git.waitForWrite(after: beforeAcquisition)
        await #expect(throws: VersionControlError.self) {
            _ = try await service.commit([request], in: workspace, progress: { _ in })
        }
        acquisition.cancel()
        _ = try await acquisition.value
        #expect(await git.commitCalls == 0)
    }

    private func requestsForAll(_ service: RepositoryService, _ workspace: Workspace) async throws -> [RepositoryCommitRequest] {
        let preparations = try await service.prepareCommits(in: workspace)
        return preparations.map { request($0, file: 0, message: "message \($0.binding.providerID.rawValue)") }
    }

    private func request(_ preparation: RepositoryCommitPreparation, file: Int, message: String) -> RepositoryCommitRequest {
        RepositoryCommitRequest(bindingID: preparation.binding.id, baseRevision: preparation.baseRevision,
                                files: [preparation.files[file]], message: message)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-CommitServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

private actor CommitFixtureProvider: RepositoryCommitProvider, RepositoryOperationProvider, RepositoryAcquisitionProvider {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let root: URL
    nonisolated let acquisitionOption: RepositoryAcquisitionOption
    private let revision: String
    private var blockingReason: String?
    private var outcome: RepositoryCommitOutcome
    private let blocksWrites: Bool
    private var startedWrites = 0
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    var commitCalls = 0
    var committedMessages: [String] = []
    var committedPaths: [[String]] = []
    var statusCalls = 0

    init(id: ProviderID, root: URL, revision: String, blockingReason: String? = nil,
         nextOutcome: RepositoryCommitOutcome = .succeeded, blocksWrites: Bool = false) {
        self.id = id; self.root = root; self.revision = revision; self.blockingReason = blockingReason
        self.outcome = nextOutcome; self.blocksWrites = blocksWrites; self.displayName = id == .git ? "Git" : "SVN"
        self.acquisitionOption = RepositoryAcquisitionOption(providerID: id, title: "fixture", actionTitle: "fixture", supportsBrowsing: false)
    }

    func setOutcome(_ value: RepositoryCommitOutcome) { outcome = value }
    var writeCount: Int { startedWrites }
    func waitForWrite(after count: Int) async {
        if startedWrites > count { return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }
    func detect(at directory: URL) async throws -> RepositoryBinding? {
        RepositoryBinding(providerID: id, providerName: displayName, root: root, currentBranch: "main",
                          remoteURL: "https://user:private-token@example.invalid/\(id.rawValue)", capabilities: [.commit, .status, .history, .update])
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { statusCalls += 1; return [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
    func prepareCommit(in binding: RepositoryBinding) async throws -> RepositoryCommitPreparation {
        let names = id == .git ? ["git-one.txt", "git-two.txt"] : ["svn-one.txt", "svn-two.txt"]
        return RepositoryCommitPreparation(binding: binding, baseRevision: revision, files: names.map {
            RepositoryCommitFile(change: .init(path: $0, kind: .modified), fingerprint: "\(revision)-\($0)")
        }, blockingReason: blockingReason)
    }
    func commitDiff(in binding: RepositoryBinding, file: RepositoryCommitFile) async throws -> RepositoryPatch { .init(text: file.change.path) }
    func commit(_ request: RepositoryCommitRequest, in binding: RepositoryBinding,
                progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryCommitResult {
        commitCalls += 1; committedMessages.append(request.message); committedPaths.append(request.files.map { $0.change.path })
        await progress(.init("secret https://user:private-token@example.invalid"))
        return RepositoryCommitResult(bindingID: binding.id, outcome: outcome, revisionID: revision,
                                      summary: "secret https://user:private-token@example.invalid",
                                      details: "https://user:private-token@example.invalid/repo?token=private-token")
    }
    func perform(_ operation: RepositoryOperationKind, in binding: RepositoryBinding,
                 progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryOperationResult {
        signalWrite()
        if blocksWrites { try await Task.sleep(for: .seconds(30)) }
        return .init(kind: operation, bindingID: binding.id, outcome: .succeeded, summary: "done")
    }
    func acquire(_ location: RemoteRepositoryLocation, to destination: URL,
                 progress: @escaping RepositoryOperationProgressHandler) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        signalWrite()
        if blocksWrites { try await Task.sleep(for: .seconds(30)) }
    }
    private func signalWrite() {
        startedWrites += 1
        let waiters = writeWaiters; writeWaiters = []
        waiters.forEach { $0.resume() }
    }
}

private actor CommitProgressCollector {
    private var entries: [RepositoryCommitProgress] = []
    func append(_ entry: RepositoryCommitProgress) { entries.append(entry) }
    func visibleText() -> String {
        entries.map { $0.progress.message + ($0.progress.detail ?? "") + $0.progress.records.map(\.message).joined() }.joined()
    }
}
