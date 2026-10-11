import Foundation
import Observation
import RepositoryApplication

public enum WorkspaceFileBrowserMode: Hashable, Sendable {
    case files
    case changes
}

public struct WorkspaceFileBrowserRow: Identifiable, Sendable {
    public let entry: WorkspaceFileEntry
    public let depth: Int
    public var id: String { entry.path }
    public init(entry: WorkspaceFileEntry, depth: Int) {
        self.entry = entry; self.depth = depth
    }
}

/// 工作区文件树的按需读取状态。它只读取用户已展开的目录，不递归扫描整个仓库。
@MainActor
@Observable
public final class WorkspaceFileBrowser {
    /// 浏览偏好属于当前工作区模型，切换主/底部视图时不应重置。
    public var mode: WorkspaceFileBrowserMode = .files
    public var filter = ""
    public private(set) var root: URL?
    public private(set) var entriesByDirectory: [String: [WorkspaceFileEntry]] = [:]
    /// 已加载、当前可见的行；由目录加载和展开状态变化时重建，渲染时不重复递归组装。
    public private(set) var visibleRows: [WorkspaceFileBrowserRow] = []
    /// 已读取目录中的全部直接子项，用于明确限定在已读取范围内的搜索。
    public private(set) var loadedEntries: [WorkspaceFileEntry] = []
    public private(set) var expandedDirectories: Set<String> = []
    public private(set) var loadingDirectories: Set<String> = []
    public private(set) var issuesByDirectory: [String: String] = [:]

    private let service: WorkspaceFileService
    private var generation = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(service: WorkspaceFileService = WorkspaceFileService()) {
        self.service = service
    }

    isolated deinit {
        tasks.values.forEach { $0.cancel() }
    }

    /// 切换工作区时立即清空旧树，并异步读取根目录。
    public func setRoot(_ root: URL?) {
        let resolvedRoot = root?.standardizedFileURL.resolvingSymlinksInPath()
        // 同一工作区的状态刷新不应折叠用户已经打开的目录。
        guard resolvedRoot != self.root else { return }
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        self.root = resolvedRoot
        entriesByDirectory = [:]
        visibleRows = []
        loadedEntries = []
        expandedDirectories = []
        loadingDirectories = []
        issuesByDirectory = [:]
        guard self.root != nil else { return }
        loadChildren(at: "", force: true)
    }

    /// 刷新仅重新读取已经加载过的目录，避免一次刷新演变为全仓递归扫描。
    public func refresh() {
        guard root != nil else { return }
        let directories = Set(entriesByDirectory.keys).union([""])
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        loadingDirectories = []
        issuesByDirectory = [:]
        for directory in directories { loadChildren(at: directory, force: true) }
    }

    public func children(in directory: String) -> [WorkspaceFileEntry] {
        entriesByDirectory[directory] ?? []
    }

    public func isExpanded(_ path: String) -> Bool { expandedDirectories.contains(path) }
    public func isLoading(_ path: String) -> Bool { loadingDirectories.contains(path) }
    public func issue(in directory: String) -> String? { issuesByDirectory[directory] }

    public func toggleDirectory(_ entry: WorkspaceFileEntry) {
        guard entry.isDirectory else { return }
        if expandedDirectories.contains(entry.path) {
            expandedDirectories.remove(entry.path)
            rebuildRows()
            return
        }
        expandedDirectories.insert(entry.path)
        rebuildRows()
        loadChildren(at: entry.path)
    }

    /// 对已展开但读取失败的目录重新发起单层读取，不触发其他目录扫描。
    public func retryDirectory(_ path: String) {
        guard expandedDirectories.contains(path) || path.isEmpty else { return }
        loadChildren(at: path, force: true)
    }

    /// 仅展开已经读取过的层级。未读取目录保持折叠，以便明确避免全仓扫描。
    public func expandLoadedDirectories() {
        expandedDirectories.formUnion(entriesByDirectory.keys.filter { !$0.isEmpty })
        rebuildRows()
    }

    public func collapseAll() {
        expandedDirectories = []
        rebuildRows()
    }

    public func preview(path: String) async throws -> WorkspaceFilePreview {
        guard let root else { throw WorkspaceFileBrowserError.noWorkspace }
        return try await service.preview(in: root, path: path)
    }

    private func loadChildren(at directory: String, force: Bool = false) {
        guard let root else { return }
        guard force || entriesByDirectory[directory] == nil else { return }
        guard tasks[directory] == nil else { return }
        let requestGeneration = generation
        loadingDirectories.insert(directory)
        issuesByDirectory[directory] = nil
        tasks[directory] = Task { [weak self, service] in
            do {
                let entries = try await service.children(in: root, path: directory)
                guard !Task.isCancelled else { return }
                self?.accept(entries: entries, directory: directory, generation: requestGeneration)
            } catch is CancellationError {
                self?.finishLoading(directory: directory, generation: requestGeneration)
            } catch {
                self?.accept(error: error, directory: directory, generation: requestGeneration)
            }
        }
    }

    private func accept(entries: [WorkspaceFileEntry], directory: String, generation: Int) {
        guard self.generation == generation else { return }
        entriesByDirectory[directory] = entries
        loadedEntries = entriesByDirectory.values.flatMap { $0 }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        rebuildRows()
        finishLoading(directory: directory, generation: generation)
    }

    private func accept(error: Error, directory: String, generation: Int) {
        guard self.generation == generation else { return }
        issuesByDirectory[directory] = error.localizedDescription
        finishLoading(directory: directory, generation: generation)
    }

    private func finishLoading(directory: String, generation: Int) {
        guard self.generation == generation else { return }
        loadingDirectories.remove(directory)
        tasks[directory] = nil
    }

    private func rebuildRows() {
        var rows: [WorkspaceFileBrowserRow] = []
        func append(directory: String, depth: Int) {
            for entry in entriesByDirectory[directory] ?? [] {
                rows.append(WorkspaceFileBrowserRow(entry: entry, depth: depth))
                if entry.isDirectory, expandedDirectories.contains(entry.path) {
                    append(directory: entry.path, depth: depth + 1)
                }
            }
        }
        append(directory: "", depth: 1)
        visibleRows = rows
    }
}

public enum WorkspaceFileBrowserError: LocalizedError {
    case noWorkspace
    public var errorDescription: String? { "当前没有可浏览的工作区。" }
}
