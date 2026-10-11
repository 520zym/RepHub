import Foundation
import VersionControlCore

public struct Workspace: Identifiable, Sendable {
    public var id: String { directory.path }
    public let directory: URL
    public let bindings: [RepositoryBinding]
    public let issues: [String]
    public var name: String { directory.lastPathComponent }
    public init(directory: URL, bindings: [RepositoryBinding], issues: [String]) {
        self.directory = directory; self.bindings = bindings; self.issues = issues
    }
    public var isUnmanaged: Bool { bindings.isEmpty && issues.isEmpty }
}

public struct BindingSnapshot: Sendable {
    public let binding: RepositoryBinding
    public let changes: [FileChange]
    public let revisions: [Revision]
    public let branches: [BranchReference]
    public let issues: [String]
    public let syncStatus: RepositorySyncStatus?
    public init(binding: RepositoryBinding, changes: [FileChange] = [], revisions: [Revision] = [], branches: [BranchReference] = [], issues: [String] = [], syncStatus: RepositorySyncStatus? = nil) {
        self.binding = binding; self.changes = changes; self.revisions = revisions; self.branches = branches; self.issues = issues
        self.syncStatus = syncStatus
    }
}

/// Orchestrates provider contracts only. No Git/SVN implementation dependency is allowed in this module.
public actor RepositoryService {
    private let providers: [any VersionControlProvider]
    private var isPerformingOperation = false
    public init(providers: [any VersionControlProvider]) { self.providers = providers }

    public func acquisitionOptions() -> [RepositoryAcquisitionOption] {
        providers.compactMap { ($0 as? any RepositoryAcquisitionProvider)?.acquisitionOption }
    }

    public func browseRemote(providerID: ProviderID, location: RemoteRepositoryLocation) async throws -> RemoteDirectoryListing {
        let provider = try acquisitionProvider(for: providerID)
        guard provider.acquisitionOption.supportsBrowsing else {
            throw VersionControlError.unsupported("当前版本控制方式不支持浏览远端文件夹。")
        }
        try Task.checkCancellation()
        do { return try await provider.browseRemote(location) }
        catch is CancellationError { throw CancellationError() }
        catch { throw VersionControlError.executionFailed(acquisitionError(error, location: location)) }
    }

    /// 先在独立目录完成获取，再移动到用户选择的新目录；已有路径一律不覆盖。
    public func acquire(providerID: ProviderID, location: RemoteRepositoryLocation,
                        destinationParent: URL, directoryName: String,
                        progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryAcquisitionResult {
        guard !isPerformingOperation else {
            throw VersionControlError.unsupported("已有仓库操作正在执行，请等待完成或取消。")
        }
        let provider = try acquisitionProvider(for: providerID)
        let destination = try acquisitionDestination(parent: destinationParent, name: directoryName)
        try Task.checkCancellation()
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".rephub-acquire-\(UUID().uuidString)", isDirectory: true)
        let payload = staging.appendingPathComponent("working-copy", isDirectory: true)
        let files = FileManager.default
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            await progress(RepositoryOperationProgress("正在连接远端仓库…"))
            try await provider.acquire(location, to: payload, progress: progress)
            try Task.checkCancellation()
            let attributes = try files.attributesOfItem(atPath: payload.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw VersionControlError.invalidRepository("获取结果不是有效的工作副本目录。")
            }
            await progress(RepositoryOperationProgress("正在保存工作副本…"))
            // 获取期间可能有其他程序创建同名目录，发布前重新校验；moveItem 也拒绝覆盖。
            _ = try acquisitionDestination(parent: destination.deletingLastPathComponent(), name: directoryName)
            try Task.checkCancellation()
            try files.moveItem(at: payload, to: destination)
            try? files.removeItem(at: staging)
            return RepositoryAcquisitionResult(outcome: .succeeded, destination: destination,
                summary: "工作副本已保存，可以开始查看代码。")
        } catch {
            // 只删除自己创建的空暂存目录，部分下载保留供用户检查。
            let containsFiles = ((try? files.contentsOfDirectory(atPath: staging.path))?.isEmpty == false)
            if !containsFiles { try? files.removeItem(at: staging) }
            let cancelled = error is CancellationError
            let partial = containsFiles ? staging : nil
            let recovery = partial.map { "\n\n已下载的部分内容保留在：\($0.path)\n可在 Finder 中检查后自行移走或删除，再重新获取。" } ?? ""
            return RepositoryAcquisitionResult(outcome: cancelled ? .cancelled : .failed,
                destination: destination, partialDirectory: partial,
                summary: cancelled ? "获取已取消。" : "未能完成获取。",
                details: (cancelled ? "目标文件夹尚未创建。" : acquisitionError(error, location: location)) + recovery)
        }
    }

    private func acquisitionProvider(for id: ProviderID) throws -> any RepositoryAcquisitionProvider {
        guard let provider = providers.first(where: { $0.id == id }) as? any RepositoryAcquisitionProvider else {
            throw VersionControlError.unsupported("未注册支持远端获取的版本控制适配器。")
        }
        return provider
    }

    private func acquisitionDestination(parent: URL, name: String) throws -> URL {
        guard parent.isFileURL, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VersionControlError.invalidRepository("请选择本地保存位置，并填写单个新文件夹名称。")
        }
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VersionControlError.invalidRepository("保存位置不存在或不是文件夹。")
        }
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        // attributesOfItem 也能识别悬空符号链接，不能把它误当成空位置。
        guard !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil else {
            throw VersionControlError.invalidRepository("同名文件夹或文件已经存在，请选择一个新的名称。")
        }
        return destination
    }

    private func acquisitionError(_ error: any Error, location: RemoteRepositoryLocation) -> String {
        var message = RepositoryDisplaySanitizer.redact(error.localizedDescription)
        if let password = location.credentials?.password, !password.isEmpty {
            message = message.replacingOccurrences(of: password, with: "***")
        }
        return message
    }

    public func open(directory: URL) async throws -> Workspace {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VersionControlError.invalidRepository("所选路径不是可访问的文件夹。")
        }
        var bindings: [RepositoryBinding] = [], issues: [String] = []
        for provider in providers {
            try Task.checkCancellation()
            do { if let binding = try await provider.detect(at: directory) { bindings.append(binding) } }
            catch is CancellationError { throw CancellationError() }
            catch { issues.append("\(provider.displayName)：\(error.localizedDescription)") }
        }
        try Task.checkCancellation()
        return Workspace(directory: directory, bindings: bindings, issues: issues)
    }

    public func load(_ binding: RepositoryBinding, reference: String? = nil) async -> BindingSnapshot {
        guard let provider = providers.first(where: { $0.id == binding.providerID }) else {
            return BindingSnapshot(binding: binding, issues: ["未注册对应的版本控制适配器。"])
        }
        // Separate failures: e.g. unavailable SVN history must not hide readable local changes.
        var changes: [FileChange] = [], revisions: [Revision] = [], branches: [BranchReference] = [], issues: [String] = []
        do { changes = try await provider.status(in: binding) }
        catch { issues.append("文件状态：\(error.localizedDescription)") }
        if Task.isCancelled { return BindingSnapshot(binding: binding, changes: changes, issues: issues) }
        var historyLoaded = false
        do {
            revisions = try await provider.history(in: binding, limit: 150, reference: reference)
            historyLoaded = true
        }
        catch { issues.append("提交历史：\(error.localizedDescription)") }
        if Task.isCancelled { return BindingSnapshot(binding: binding, changes: changes, revisions: revisions, issues: issues) }
        if binding.capabilities.contains(.branches) {
            do { branches = try await provider.branches(in: binding) }
            catch { issues.append("分支：\(error.localizedDescription)") }
        }
        var syncStatus: RepositorySyncStatus?
        if !Task.isCancelled, historyLoaded, binding.capabilities.contains(.synchronization),
           let historyProvider = provider as? any RepositoryHistoryProvider {
            do { syncStatus = try await historyProvider.synchronization(in: binding, revisions: revisions, path: nil) }
            catch { issues.append("同步状态：\(RepositoryDisplaySanitizer.redact(error.localizedDescription))") }
        }
        return BindingSnapshot(binding: binding, changes: changes, revisions: revisions, branches: branches, issues: issues, syncStatus: syncStatus)
    }

    /// 单文件历史直接查询适配器，不筛选已加载的仓库最近提交。
    public func fileHistory(in binding: RepositoryBinding, path: String, reference: String? = nil) async throws -> FileHistorySnapshot {
        try validateRelativeFilePath(path)
        guard binding.capabilities.contains(.fileHistory),
              let provider = try provider(for: binding) as? any RepositoryHistoryProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持文件历史。")
        }
        try Task.checkCancellation()
        let entries = try await provider.fileHistory(in: binding, path: path, limit: 150, reference: reference)
        try Task.checkCancellation()
        var syncStatus: RepositorySyncStatus?
        var issues: [String] = []
        if binding.capabilities.contains(.synchronization) {
            do { syncStatus = try await provider.synchronization(in: binding, revisions: entries.map(\.revision), path: path) }
            catch is CancellationError { throw CancellationError() }
            catch { issues.append("同步状态：\(RepositoryDisplaySanitizer.redact(error.localizedDescription))") }
        }
        try Task.checkCancellation()
        return FileHistorySnapshot(path: path, entries: entries, syncStatus: syncStatus, issues: issues)
    }

    public func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch {
        try validateRelativeFilePath(entry.path)
        guard let provider = try provider(for: binding) as? any RepositoryHistoryProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持文件历史差异。")
        }
        return try await provider.fileHistoryDiff(in: binding, entry: entry)
    }

    private func validateRelativeFilePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw VersionControlError.invalidRepository("文件路径必须位于当前工作副本内。")
        }
    }

    public func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        try await provider(for: binding).diff(in: binding, path: path, revision: revision)
    }
    public func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] {
        try await provider(for: binding).changedFiles(in: binding, revision: revision)
    }

    /// 同一服务实例串行写入；只执行一个已识别的目标，完成后刷新全部绑定。
    public func perform(_ operation: RepositoryOperationKind, bindingID: String, in workspace: Workspace,
                        progress: @escaping RepositoryOperationProgressHandler) async throws -> WorkspaceOperationResult {
        guard !isPerformingOperation else {
            throw VersionControlError.unsupported("已有仓库操作正在执行，请等待完成或取消后的状态核对结束。")
        }
        guard let requested = workspace.bindings.first(where: { $0.id == bindingID }),
              requested.capabilities.contains(operation.capability),
              let provider = try provider(for: requested) as? any RepositoryOperationProvider else {
            throw VersionControlError.unsupported("所选版本控制来源不支持此操作。")
        }
        isPerformingOperation = true
        defer { isPerformingOperation = false }

        let result: RepositoryOperationResult
        do {
            try Task.checkCancellation()
            await progress(RepositoryOperationProgress("正在检查工作区与操作目标…"))
            guard let current = try await provider.detect(at: requested.root),
                  current.id == requested.id,
                  current.currentBranch == requested.currentBranch,
                  current.remoteURL == requested.remoteURL else {
                throw VersionControlError.invalidRepository("仓库位置、分支或远端已经改变，请刷新后重新选择更新目标。")
            }
            try Task.checkCancellation()
            let performed = try await provider.perform(operation, in: current, progress: progress)
            result = RepositoryOperationResult(
                kind: operation, bindingID: bindingID, outcome: performed.outcome,
                summary: RepositoryDisplaySanitizer.redact(performed.summary),
                details: RepositoryDisplaySanitizer.redact(performed.details), changedFiles: performed.changedFiles
            )
        } catch is CancellationError {
            result = RepositoryOperationResult(kind: operation, bindingID: bindingID, outcome: .cancelled,
                summary: "操作已取消。", details: "取消不会自动回滚已经获取的远端信息或已经更新的文件，请核对重新读取的工作区状态。")
        } catch {
            result = RepositoryOperationResult(kind: operation, bindingID: bindingID, outcome: .failed,
                summary: "操作未完成。", details: RepositoryDisplaySanitizer.redact(error.localizedDescription))
        }

        await progress(RepositoryOperationProgress("正在重新检查所有版本控制来源…"))
        // 原操作可能已取消；核对必须独立完成，不能沿用已取消的任务上下文。
        let refreshed = await Task.detached { [self] in
            await refreshAfterOperation(workspace)
        }.value
        let refreshIssues = refreshed.0.issues + refreshed.1.flatMap { snapshot in
            snapshot.issues.map { "\(snapshot.binding.providerName)：\($0)" }
        }
        let finalResult = RepositoryOperationResult(kind: result.kind, bindingID: result.bindingID,
            outcome: result.outcome, summary: result.summary,
            details: result.details + (refreshIssues.isEmpty ? "" : "\n\n操作后刷新提示：\n" + RepositoryDisplaySanitizer.redact(refreshIssues.joined(separator: "\n"))),
            changedFiles: result.changedFiles)
        return WorkspaceOperationResult(result: finalResult, workspace: refreshed.0, snapshots: refreshed.1)
    }

    private func refreshAfterOperation(_ previous: Workspace) async -> (Workspace, [BindingSnapshot]) {
        let refreshed: Workspace
        do { refreshed = try await open(directory: previous.directory) }
        catch {
            refreshed = Workspace(directory: previous.directory, bindings: previous.bindings,
                issues: ["操作后无法重新识别工作区：\(RepositoryDisplaySanitizer.redact(error.localizedDescription))"])
        }
        var snapshots: [BindingSnapshot] = []
        for binding in refreshed.bindings { snapshots.append(await load(binding)) }
        return (refreshed, snapshots)
    }

    private func provider(for binding: RepositoryBinding) throws -> any VersionControlProvider {
        guard let provider = providers.first(where: { $0.id == binding.providerID }) else {
            throw VersionControlError.unsupported("未注册对应的版本控制适配器。")
        }
        return provider
    }
}
