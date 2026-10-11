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
    public init(binding: RepositoryBinding, changes: [FileChange] = [], revisions: [Revision] = [], branches: [BranchReference] = [], issues: [String] = []) {
        self.binding = binding; self.changes = changes; self.revisions = revisions; self.branches = branches; self.issues = issues
    }
}

/// Orchestrates provider contracts only. No Git/SVN implementation dependency is allowed in this module.
public actor RepositoryService {
    private let providers: [any VersionControlProvider]
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
        do { revisions = try await provider.history(in: binding, limit: 150, reference: reference) }
        catch { issues.append("提交历史：\(error.localizedDescription)") }
        if Task.isCancelled { return BindingSnapshot(binding: binding, changes: changes, revisions: revisions, issues: issues) }
        if binding.capabilities.contains(.branches) {
            do { branches = try await provider.branches(in: binding) }
            catch { issues.append("分支：\(error.localizedDescription)") }
        }
        return BindingSnapshot(binding: binding, changes: changes, revisions: revisions, branches: branches, issues: issues)
    }

    public func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        try await provider(for: binding).diff(in: binding, path: path, revision: revision)
    }
    public func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] {
        try await provider(for: binding).changedFiles(in: binding, revision: revision)
    }
    private func provider(for binding: RepositoryBinding) throws -> any VersionControlProvider {
        guard let provider = providers.first(where: { $0.id == binding.providerID }) else {
            throw VersionControlError.unsupported("未注册对应的版本控制适配器。")
        }
        return provider
    }
}
