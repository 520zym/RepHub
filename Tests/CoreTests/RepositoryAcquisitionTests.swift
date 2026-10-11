import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("远端获取编排")
struct RepositoryAcquisitionTests {
    private let location = RemoteRepositoryLocation(url: "https://example.invalid/repository")

    @Test("成功后发布工作副本并移除暂存目录")
    func publishesNewDirectory() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RepositoryService(providers: [AcquisitionFixtureProvider()])
        let result = try await service.acquire(providerID: .git, location: location,
            destinationParent: root, directoryName: "检出目录", progress: { _ in })
        #expect(result.outcome == .succeeded)
        #expect(try String(contentsOf: result.destination.appendingPathComponent("README"), encoding: .utf8) == "fixture")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["检出目录"])
    }

    @Test("已有文件夹、悬空链接和越界名称在调用适配器前被拒绝")
    func protectsExistingTargets() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("existing"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "/nonexistent-rephub-fixture")
        let provider = AcquisitionFixtureProvider()
        let service = RepositoryService(providers: [provider])
        for name in ["existing", "dangling", "../escape", ".", "..", "/absolute", "\n"] {
            do {
                _ = try await service.acquire(providerID: .git, location: location,
                    destinationParent: root, directoryName: name, progress: { _ in })
                Issue.record("不应接受目标：\(name)")
            } catch VersionControlError.invalidRepository {}
        }
        #expect(await provider.calls == 0)
    }

    @Test("获取期间创建的同名目标保留原内容")
    func protectsConcurrentDestination() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("checkout")
        let provider = AcquisitionFixtureProvider(collision: destination)
        let service = RepositoryService(providers: [provider])
        let result = try await service.acquire(providerID: .git, location: location,
            destinationParent: root, directoryName: "checkout", progress: { _ in })
        #expect(result.outcome == .failed)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "user data")
        #expect(result.partialDirectory != nil)
    }

    @Test("取消保留部分内容且不会生成最终目标，并拒绝并行获取和更新")
    func cancellationAndSerialization() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = AcquisitionFixtureProvider(waits: true)
        let service = RepositoryService(providers: [provider])
        let task = Task { try await service.acquire(providerID: .git, location: location,
            destinationParent: root, directoryName: "checkout", progress: { _ in }) }
        await provider.waitUntilStarted()
        do {
            _ = try await service.acquire(providerID: .git, location: location,
                destinationParent: root, directoryName: "another", progress: { _ in })
            Issue.record("不应允许并行获取")
        } catch VersionControlError.unsupported {}
        let workspace = try await service.open(directory: root)
        let binding = try #require(workspace.bindings.first)
        do {
            _ = try await service.perform(.update, bindingID: binding.id, in: workspace, progress: { _ in })
            Issue.record("获取时不应允许更新")
        } catch VersionControlError.unsupported {}
        task.cancel()
        let result = try await task.value
        #expect(result.outcome == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: result.destination.path))
        let partial = try #require(result.partialDirectory)
        #expect(FileManager.default.fileExists(atPath: partial.appendingPathComponent("working-copy/README").path))
        #expect(await provider.calls == 1)
    }

    @Test("浏览错误不会泄漏输入密码")
    func redactsCredentials() async throws {
        let service = RepositoryService(providers: [AcquisitionFixtureProvider()])
        do {
            _ = try await service.browseRemote(providerID: .git,
                location: .init(url: location.url, credentials: .init(username: "fixture", password: "fixture-secret")))
            Issue.record("预期夹具返回错误")
        } catch {
            #expect(!error.localizedDescription.contains("fixture-secret"))
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-AcquisitionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

private actor AcquisitionFixtureProvider: RepositoryAcquisitionProvider, RepositoryOperationProvider {
    nonisolated let id = ProviderID.git
    nonisolated let displayName = "获取测试"
    nonisolated let acquisitionOption = RepositoryAcquisitionOption(providerID: .git, title: "测试", actionTitle: "获取", supportsBrowsing: true)
    let waits: Bool
    let collision: URL?
    var calls = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(waits: Bool = false, collision: URL? = nil) { self.waits = waits; self.collision = collision }
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func browseRemote(_ location: RemoteRepositoryLocation) async throws -> RemoteDirectoryListing {
        throw VersionControlError.executionFailed("fixture-secret")
    }
    func acquire(_ location: RemoteRepositoryLocation, to destination: URL,
                 progress: @escaping RepositoryOperationProgressHandler) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("fixture".utf8).write(to: destination.appendingPathComponent("README"))
        calls += 1
        waiters.forEach { $0.resume() }; waiters = []
        if waits { try await Task.sleep(for: .seconds(30)) }
        if let collision { try Data("user data".utf8).write(to: collision) }
    }
    func detect(at directory: URL) async throws -> RepositoryBinding? {
        RepositoryBinding(providerID: id, providerName: displayName, root: directory, capabilities: [.update])
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
    func perform(_ operation: RepositoryOperationKind, in binding: RepositoryBinding,
                 progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryOperationResult {
        .init(kind: operation, bindingID: binding.id, outcome: .succeeded, summary: "完成")
    }
}
