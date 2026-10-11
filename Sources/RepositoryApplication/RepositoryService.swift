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
