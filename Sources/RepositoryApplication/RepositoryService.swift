import Foundation
import VersionControlCore

public struct Workspace: Identifiable, Sendable {
    public var id: String { directory.path }
    public let directory: URL
    /// 与主目录共同展示的其他工作副本。主目录不重复存放在此集合中。
    public let linkedDirectories: [URL]
    public let bindings: [RepositoryBinding]
    public let issues: [String]
    public var name: String { directory.lastPathComponent }
    public init(directory: URL, linkedDirectories: [URL] = [], bindings: [RepositoryBinding], issues: [String]) {
        self.directory = directory; self.linkedDirectories = linkedDirectories
        self.bindings = bindings; self.issues = issues
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
    /// 历史首页后的不透明游标。界面只能原样传回服务层，不能推断 Git／SVN 语义。
    public let nextHistoryCursor: String?
    public init(binding: RepositoryBinding, changes: [FileChange] = [], revisions: [Revision] = [], branches: [BranchReference] = [], issues: [String] = [], syncStatus: RepositorySyncStatus? = nil, nextHistoryCursor: String? = nil) {
        self.binding = binding; self.changes = changes; self.revisions = revisions; self.branches = branches; self.issues = issues
        self.syncStatus = syncStatus
        self.nextHistoryCursor = nextHistoryCursor
    }
}

/// Orchestrates provider contracts only. No Git/SVN implementation dependency is allowed in this module.
public actor RepositoryService {
    let providers: [any VersionControlProvider]
    let writeGate: RepositoryWriteGate
    var isPerformingOperation = false
    public init(providers: [any VersionControlProvider], writeGate: RepositoryWriteGate = RepositoryWriteGate()) {
        self.providers = providers
        self.writeGate = writeGate
    }

    public func acquisitionOptions() -> [RepositoryAcquisitionOption] {
        providers.compactMap { ($0 as? any RepositoryAcquisitionProvider)?.acquisitionOption }
    }

    public func setupOptions() -> [RepositorySetupOption] {
        providers.compactMap { ($0 as? any RepositorySetupProvider)?.setupOption }
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
        try await writeGate.withExclusiveAccess { [self] in
            try await self.acquireUnlocked(providerID: providerID, location: location,
                                           destinationParent: destinationParent, directoryName: directoryName,
                                           progress: progress)
        }
    }

    private func acquireUnlocked(providerID: ProviderID, location: RemoteRepositoryLocation,
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
            try await provider.acquire(location, to: payload) { update in
                await progress(Self.sanitizedProgress(update, password: location.credentials?.password))
            }
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

    /// 在任何写入前重新检测全部来源。初始化只能发生在未受管且没有检测故障的目录。
    public func initialize(_ request: RepositorySetupRequest,
                           progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositorySetupResult {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.initializeUnlocked(request, progress: progress)
        }
    }

    private func initializeUnlocked(_ request: RepositorySetupRequest,
                                    progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositorySetupResult {
        guard !isPerformingOperation else {
            throw VersionControlError.unsupported("已有仓库操作正在执行，请等待完成或取消后的状态核对结束。")
        }
        guard let provider = providers.first(where: { $0.id == request.providerID }) as? any RepositorySetupProvider else {
            throw VersionControlError.unsupported("所选版本控制来源不支持初始化。")
        }
        if provider.setupOption.requiresRemote, request.remote == nil {
            throw VersionControlError.invalidRepository("所选版本控制方式需要填写远端仓库地址。")
        }
        let directory = try checkedDirectory(request.directory)
        guard !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw VersionControlError.invalidRepository("初始化目录路径包含控制字符。")
        }
        let normalizedRequest = RepositorySetupRequest(providerID: request.providerID, directory: directory,
                                                       remote: request.remote, message: request.message,
                                                       initialBranch: request.initialBranch)
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        await progress(RepositoryOperationProgress("正在检查文件夹是否已受版本控制…"))
        let detected = try await open(directory: directory)
        guard detected.bindings.isEmpty else {
            throw VersionControlError.invalidRepository("此文件夹已受版本控制，不能再次初始化。")
        }
        guard detected.issues.isEmpty else {
            throw VersionControlError.invalidRepository("无法确认文件夹是否未受版本控制：\n\(detected.issues.joined(separator: "\n"))")
        }
        guard try !containsVersionControlMetadata(in: directory) else {
            throw VersionControlError.invalidRepository("文件夹内包含 .git 或 .svn 元数据，不能在嵌套工作副本中初始化。")
        }
        try Task.checkCancellation()
        do {
            let result = try await provider.initialize(normalizedRequest) { update in
                await progress(Self.sanitizedProgress(update, password: normalizedRequest.remote?.credentials?.password))
            }
            return sanitizedSetupResult(result, password: normalizedRequest.remote?.credentials?.password)
        } catch is CancellationError {
            return RepositorySetupResult(outcome: .unknown, directory: directory,
                                         summary: "初始化结果需要核对。",
                                         details: "初始化已开始，但未取得适配器结果。请重新打开文件夹核对状态，勿直接重复初始化。")
        } catch {
            return RepositorySetupResult(outcome: .unknown, directory: directory,
                                         summary: "初始化结果需要核对。",
                                         details: "初始化已开始，但未取得适配器结果。请重新打开文件夹核对状态，勿直接重复初始化。\n\n"
                                            + sanitizedText(error.localizedDescription,
                                                           password: normalizedRequest.remote?.credentials?.password))
        }
    }

    private func containsVersionControlMetadata(in directory: URL) throws -> Bool {
        let names: Set<String> = [".git", ".svn"]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                               includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                               options: [], errorHandler: { _, error in
                                                                   enumerationError = error
                                                                   return false
                                                               }) else {
            throw VersionControlError.invalidRepository("无法枚举初始化目录以检查嵌套版本控制元数据。")
        }
        for case let item as URL in enumerator {
            try Task.checkCancellation()
            if names.contains(item.lastPathComponent.lowercased()) { return true }
        }
        if let enumerationError {
            throw VersionControlError.invalidRepository("无法完整检查嵌套版本控制元数据：\(RepositoryDisplaySanitizer.redact(enumerationError.localizedDescription))")
        }
        return false
    }

    private func sanitizedSetupResult(_ result: RepositorySetupResult, password: String?) -> RepositorySetupResult {
        RepositorySetupResult(outcome: result.outcome, directory: result.directory,
                              summary: sanitizedText(result.summary, password: password),
                              details: sanitizedText(result.details, password: password),
                              backupDirectory: result.backupDirectory)
    }

    private func sanitizedText(_ text: String, password: String? = nil) -> String {
        var value = RepositoryDisplaySanitizer.redact(text)
        if let password, !password.isEmpty { value = value.replacingOccurrences(of: password, with: "***") }
        return value
    }

    private func acquisitionError(_ error: any Error, location: RemoteRepositoryLocation) -> String {
        var message = RepositoryDisplaySanitizer.redact(error.localizedDescription)
        if let password = location.credentials?.password, !password.isEmpty {
            message = message.replacingOccurrences(of: password, with: "***")
        }
        return message
    }

    private nonisolated static func sanitizedProgress(_ update: RepositoryOperationProgress,
                                                       password: String? = nil) -> RepositoryOperationProgress {
        func sanitize(_ text: String) -> String {
            let redacted = RepositoryDisplaySanitizer.redact(text)
            guard let password, !password.isEmpty else { return redacted }
            return redacted.replacingOccurrences(of: password, with: "***")
        }
        return RepositoryOperationProgress(sanitize(update.message), fractionCompleted: update.fractionCompleted,
            detail: update.detail.map(sanitize), records: update.records.map {
                RepositoryProgressRecord(kind: $0.kind, message: sanitize($0.message), path: $0.path.map(sanitize))
            }, transferStatistics: update.transferStatistics)
    }

    public func open(directory: URL, linkedDirectories: [URL] = []) async throws -> Workspace {
        let directory = try checkedDirectory(directory)
        let linked = normalizeLinkedDirectories(linkedDirectories, excluding: directory)
        let directories = [directory] + linked
        var bindings: [RepositoryBinding] = [], issues: [String] = []
        var seenBindings = Set<String>()
        for candidate in directories {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                issues.append("关联目录不可访问：\(candidate.path)")
                continue
            }
            for provider in providers {
                try Task.checkCancellation()
                do {
                    if let binding = try await provider.detect(at: candidate), seenBindings.insert(binding.id).inserted {
                        bindings.append(binding)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let prefix = candidate == directory ? provider.displayName : "\(candidate.lastPathComponent) · \(provider.displayName)"
                    issues.append("\(prefix)：\(error.localizedDescription)")
                }
            }
        }
        try Task.checkCancellation()
        return Workspace(directory: directory, linkedDirectories: linked, bindings: bindings, issues: issues)
    }

    private func checkedDirectory(_ directory: URL) throws -> URL {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VersionControlError.invalidRepository("所选路径不是可访问的文件夹。")
        }
        return directory
    }

    private func normalizeLinkedDirectories(_ candidates: [URL], excluding primary: URL) -> [URL] {
        var seen = Set([primary.path])
        return candidates.compactMap { candidate in
            guard candidate.isFileURL else { return nil }
            let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(normalized.path).inserted ? normalized : nil
        }
    }

    public func load(_ binding: RepositoryBinding, reference: String? = nil) async -> BindingSnapshot {
        guard let provider = providers.first(where: { $0.id == binding.providerID }) else {
            return BindingSnapshot(binding: binding, issues: ["未注册对应的版本控制适配器。"])
        }
        // Separate failures: e.g. unavailable SVN history must not hide readable local changes.
        var changes: [FileChange] = [], revisions: [Revision] = [], branches: [BranchReference] = [], issues: [String] = []
        var nextHistoryCursor: String?
        var syncStatus: RepositorySyncStatus?
        do { changes = try await provider.status(in: binding) }
        catch { issues.append("文件状态：\(error.localizedDescription)") }
        if Task.isCancelled { return BindingSnapshot(binding: binding, changes: changes, issues: issues) }
        do {
            let page = try await historyPage(in: binding, reference: reference)
            revisions = page.revisions
            nextHistoryCursor = page.nextCursor
            syncStatus = page.syncStatus
            issues.append(contentsOf: page.issues)
        }
        catch { issues.append("提交历史：\(error.localizedDescription)") }
        if Task.isCancelled { return BindingSnapshot(binding: binding, changes: changes, revisions: revisions, issues: issues) }
        if binding.capabilities.contains(.branches) {
            do { branches = try await provider.branches(in: binding) }
            catch { issues.append("分支：\(error.localizedDescription)") }
        }
        return BindingSnapshot(binding: binding, changes: changes, revisions: revisions, branches: branches,
                               issues: issues, syncStatus: syncStatus, nextHistoryCursor: nextHistoryCursor)
    }

    /// 读取一页仓库历史。游标完全由具体适配器维护，调用方不能解析或自行构造。
    ///
    /// 未实现分页扩展的旧适配器仍可读取首页；它们没有续页能力时明确报错，避免伪造“已读完”。
    public func historyPage(in binding: RepositoryBinding, reference: String? = nil,
                            cursor: String? = nil, loadedRevisions: [Revision] = []) async throws -> HistoryPageSnapshot {
        let provider = try provider(for: binding)
        try Task.checkCancellation()
        let request = HistoryPageRequest(limit: 150, reference: reference, cursor: cursor)
        let page: RepositoryHistoryPage
        if let paging = provider as? any RepositoryHistoryPagingProvider {
            page = try await paging.historyPage(in: binding, request: request)
        } else if cursor == nil {
            page = RepositoryHistoryPage(revisions: try await provider.history(in: binding, limit: request.limit, reference: reference))
        } else {
            throw VersionControlError.unsupported("当前版本控制适配器暂不支持继续读取更早的提交。")
        }
        try Task.checkCancellation()
        let synchronization = try await synchronization(for: provider, binding: binding,
                                                        revisions: mergingRevisions(loadedRevisions, page.revisions), path: nil)
        try Task.checkCancellation()
        return HistoryPageSnapshot(revisions: page.revisions, nextCursor: page.nextCursor,
                                   syncStatus: synchronization.status, issues: synchronization.issues)
    }

    /// 单文件历史直接查询适配器，不筛选已加载的仓库最近提交。
    public func fileHistory(in binding: RepositoryBinding, path: String, reference: String? = nil,
                            cursor: String? = nil, loadedRevisions: [Revision] = []) async throws -> FileHistorySnapshot {
        try validateRelativeFilePath(path)
        guard binding.capabilities.contains(.fileHistory),
              let provider = try provider(for: binding) as? any RepositoryHistoryProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持文件历史。")
        }
        try Task.checkCancellation()
        let request = HistoryPageRequest(limit: 150, reference: reference, cursor: cursor)
        let page: FileHistoryPage
        if let paging = provider as? any RepositoryHistoryPagingProvider {
            page = try await paging.fileHistoryPage(in: binding, path: path, request: request)
        } else if cursor == nil {
            page = FileHistoryPage(entries: try await provider.fileHistory(in: binding, path: path,
                                                                            limit: request.limit, reference: reference))
        } else {
            throw VersionControlError.unsupported("当前版本控制适配器暂不支持继续读取更早的文件提交。")
        }
        try Task.checkCancellation()
        let synchronization = try await synchronization(for: provider, binding: binding,
                                                        revisions: mergingRevisions(loadedRevisions, page.entries.map(\.revision)), path: path)
        try Task.checkCancellation()
        return FileHistorySnapshot(path: path, entries: page.entries, nextCursor: page.nextCursor,
                                   syncStatus: synchronization.status, issues: synchronization.issues)
    }

    private func synchronization(for provider: any VersionControlProvider, binding: RepositoryBinding,
                                 revisions: [Revision], path: String?) async throws -> (status: RepositorySyncStatus?, issues: [String]) {
        guard binding.capabilities.contains(.synchronization),
              let historyProvider = provider as? any RepositoryHistoryProvider else {
            return (nil, [])
        }
        do {
            return (try await historyProvider.synchronization(in: binding, revisions: revisions, path: path), [])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (nil, ["同步状态：\(RepositoryDisplaySanitizer.redact(error.localizedDescription))"])
        }
    }

    /// 同一历史范围可能因页边界重叠重复提交；同步状态必须基于已经展示的去重集合。
    private func mergingRevisions(_ loaded: [Revision], _ page: [Revision]) -> [Revision] {
        var seen = Set<String>()
        return (loaded + page).filter { seen.insert($0.id).inserted }
    }

    public func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch {
        try validateRelativeFilePath(entry.path)
        guard let provider = try provider(for: binding) as? any RepositoryHistoryProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持文件历史差异。")
        }
        return try await provider.fileHistoryDiff(in: binding, entry: entry)
    }

    func validateRelativeFilePath(_ path: String) throws {
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

    public func prepareCommits(in workspace: Workspace) async throws -> [RepositoryCommitPreparation] {
        guard !isPerformingOperation else { throw VersionControlError.unsupported("已有仓库操作正在执行。") }
        var preparations: [RepositoryCommitPreparation] = []
        for binding in commitOrderedBindings(workspace.bindings) where binding.capabilities.contains(.commit) {
            try Task.checkCancellation()
            do {
                guard let adapter = try provider(for: binding) as? any RepositoryCommitProvider else { continue }
                let current = try await checkedCommitBinding(binding, using: adapter)
                let preparation = try await adapter.prepareCommit(in: current)
                try validatePreparation(preparation, for: current)
                preparations.append(preparation)
            } catch is CancellationError { throw CancellationError() }
            catch {
                preparations.append(RepositoryCommitPreparation(binding: binding, baseRevision: nil, files: [],
                    blockingReason: RepositoryDisplaySanitizer.redact(error.localizedDescription)))
            }
        }
        return preparations
    }

    public func commitDiff(in binding: RepositoryBinding, file: RepositoryCommitFile) async throws -> RepositoryPatch {
        try validateCommitPath(file.change.path)
        if let original = file.change.originalPath { try validateCommitPath(original) }
        guard let adapter = try provider(for: binding) as? any RepositoryCommitProvider else {
            throw VersionControlError.unsupported("当前来源不支持提交预览。")
        }
        return try await adapter.commitDiff(in: binding, file: file)
    }

    /// 先复核全部目标，再依次执行 Git、本次其余来源；单个结果不能代表整个批次。
    public func commit(_ requests: [RepositoryCommitRequest], in workspace: Workspace,
                       progress: @escaping RepositoryCommitProgressHandler) async throws -> WorkspaceCommitResult {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.commitUnlocked(requests, in: workspace, progress: progress)
        }
    }

    private func commitUnlocked(_ requests: [RepositoryCommitRequest], in workspace: Workspace,
                                progress: @escaping RepositoryCommitProgressHandler) async throws -> WorkspaceCommitResult {
        guard !isPerformingOperation else { throw VersionControlError.unsupported("已有仓库操作正在执行，请等待完成。") }
        guard !requests.isEmpty, Set(requests.map(\.bindingID)).count == requests.count else {
            throw VersionControlError.invalidRepository("请选择至少一个提交目标，且每个来源只提交一次。")
        }
        for request in requests {
            guard !request.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !request.message.contains("\0"), request.message.utf8.count <= 256 * 1024,
                  !request.files.isEmpty, Set(request.files.map(\.id)).count == request.files.count else {
                throw VersionControlError.invalidRepository("提交说明和文件范围不能为空，文件不能重复。")
            }
            for file in request.files {
                try validateCommitPath(file.change.path)
                if let original = file.change.originalPath { try validateCommitPath(original) }
                guard file.restriction == nil, !file.fingerprint.isEmpty else {
                    throw VersionControlError.unsupported(file.restriction ?? "文件快照无效，请重新准备提交。")
                }
            }
            guard workspace.bindings.contains(where: { $0.id == request.bindingID && $0.capabilities.contains(.commit) }) else {
                throw VersionControlError.invalidRepository("提交目标已不属于当前工作区。")
            }
        }
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        let byID = Dictionary(uniqueKeysWithValues: requests.map { ($0.bindingID, $0) })
        let ordered = commitOrderedBindings(workspace.bindings).filter { byID[$0.id] != nil }
        var targets: [(RepositoryBinding, any RepositoryCommitProvider, RepositoryCommitRequest)] = []
        var results: [RepositoryCommitResult] = []
        var preflightFailure: (String, String)?
        // 全部预检均为只读；未通过前不对任一目标执行提交或暂存。
        for binding in ordered {
            do {
                try Task.checkCancellation()
                guard let adapter = try provider(for: binding) as? any RepositoryCommitProvider,
                      let request = byID[binding.id] else {
                    throw VersionControlError.unsupported("当前来源未接入提交功能。")
                }
                await progress(RepositoryCommitProgress(bindingID: binding.id,
                    progress: RepositoryOperationProgress("正在核对提交范围…")))
                let current = try await checkedCommitBinding(binding, using: adapter)
                let fresh = try await adapter.prepareCommit(in: current)
                try validatePreparation(fresh, for: current)
                if let reason = fresh.blockingReason { throw VersionControlError.unsupported(reason) }
                guard fresh.baseRevision == request.baseRevision else {
                    throw VersionControlError.invalidRepository("提交基准已改变，请重新准备提交。")
                }
                for selected in request.files {
                    guard let actual = fresh.files.first(where: { $0.id == selected.id }),
                          actual == selected, actual.restriction == nil else {
                        throw VersionControlError.invalidRepository("文件已变化或不再可提交，请重新核对：\(selected.id)")
                    }
                }
                targets.append((current, adapter, request))
            } catch {
                preflightFailure = (binding.id, RepositoryDisplaySanitizer.redact(error.localizedDescription))
                break
            }
        }
        if let (failedID, detail) = preflightFailure {
            results = ordered.map { binding in
                RepositoryCommitResult(bindingID: binding.id,
                    outcome: binding.id == failedID ? (Task.isCancelled ? .cancelled : .failed) : .notStarted,
                    summary: binding.id == failedID ? "提交前检查未通过。" : "未执行提交。", details: detail)
            }
        } else {
            var stopReason: String?
            for (binding, adapter, request) in targets {
                if let stopReason {
                    results.append(RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted,
                        summary: "未执行提交。", details: stopReason))
                    continue
                }
                if Task.isCancelled {
                    stopReason = "操作已取消，后续目标未开始。"
                    results.append(RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted,
                        summary: "未执行提交。", details: stopReason!))
                    continue
                }
                let result: RepositoryCommitResult
                do {
                    result = try await adapter.commit(request, in: binding) { update in
                        await progress(RepositoryCommitProgress(bindingID: binding.id, progress: Self.sanitizedProgress(update)))
                    }
                } catch {
                    // 适配器进入写阶段后必须自行核实结果。无法获取其结果时不能声称“没有提交”。
                    result = RepositoryCommitResult(bindingID: binding.id, outcome: .unknown,
                        summary: "暂时无法确认提交结果。", details: error.localizedDescription)
                }
                results.append(RepositoryCommitResult(bindingID: binding.id, outcome: result.outcome,
                    revisionID: result.revisionID, summary: RepositoryDisplaySanitizer.redact(result.summary),
                    details: RepositoryDisplaySanitizer.redact(result.details), committedFiles: result.committedFiles))
                if result.outcome == .unknown || result.outcome == .cancelled {
                    stopReason = result.outcome == .unknown
                        ? "前一个目标的提交结果需要核实，后续目标未开始；请勿重复提交。"
                        : "操作已取消，后续目标未开始。"
                }
            }
        }
        let refreshed = await Task.detached { [self] in await refreshAfterOperation(workspace) }.value
        return WorkspaceCommitResult(results: results, workspace: refreshed.0, snapshots: refreshed.1)
    }

    func checkedCommitBinding(_ requested: RepositoryBinding,
                                      using adapter: any RepositoryCommitProvider) async throws -> RepositoryBinding {
        guard let current = try await adapter.detect(at: requested.root), current.id == requested.id,
              current.currentBranch == requested.currentBranch, current.remoteURL == requested.remoteURL else {
            throw VersionControlError.invalidRepository("仓库位置、分支或远端已改变，请刷新后重新准备提交。")
        }
        return current
    }

    private func validatePreparation(_ preparation: RepositoryCommitPreparation, for binding: RepositoryBinding) throws {
        guard preparation.binding.id == binding.id,
              preparation.binding.providerID == binding.providerID,
              preparation.binding.root.standardizedFileURL == binding.root.standardizedFileURL else {
            throw VersionControlError.invalidRepository("提交准备的来源与当前仓库不一致，请重新打开仓库。")
        }
    }

    private func validateCommitPath(_ path: String) throws {
        try validateRelativeFilePath(path)
        guard !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/").contains(where: { [".git", ".svn"].contains($0.lowercased()) }) else {
            throw VersionControlError.invalidRepository("提交范围不能包含控制字符或版本管理元数据。")
        }
    }

    private func commitOrderedBindings(_ bindings: [RepositoryBinding]) -> [RepositoryBinding] {
        bindings.enumerated().sorted {
            let lhs = $0.element.providerID == .git ? 0 : ($0.element.providerID == .svn ? 1 : 2)
            let rhs = $1.element.providerID == .git ? 0 : ($1.element.providerID == .svn ? 1 : 2)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    /// 读取适配器当前的可管理状态；该状态令牌只能用于随后的同一来源写操作。
    public func managementContext(in binding: RepositoryBinding) async throws -> RepositoryManagementContext {
        guard let provider = try provider(for: binding) as? any RepositoryManagementProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持仓库管理。")
        }
        try Task.checkCancellation()
        guard let current = try await provider.detect(at: binding.root), current.id == binding.id else {
            throw VersionControlError.invalidRepository("仓库位置已改变，请重新打开工作区。")
        }
        let context = try await provider.managementContext(in: current)
        guard context.binding.id == current.id else {
            throw VersionControlError.invalidData("版本控制适配器返回的管理状态不属于当前仓库。")
        }
        return context
    }

    /// 管理写操作在执行前复核能力、绑定与状态令牌，完成或取消后均独立刷新全部关联工作副本。
    public func manage(_ request: RepositoryManagementRequest, bindingID: String, in workspace: Workspace,
                       progress: @escaping RepositoryOperationProgressHandler) async throws -> WorkspaceManagementResult {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.manageUnlocked(request, bindingID: bindingID, in: workspace, progress: progress)
        }
    }

    private func manageUnlocked(_ request: RepositoryManagementRequest, bindingID: String, in workspace: Workspace,
                                progress: @escaping RepositoryOperationProgressHandler) async throws -> WorkspaceManagementResult {
        guard !isPerformingOperation else {
            throw VersionControlError.unsupported("已有仓库操作正在执行，请等待完成或取消后的状态核对结束。")
        }
        guard let requested = workspace.bindings.first(where: { $0.id == bindingID }),
              requested.capabilities.contains(request.action.capability),
              let provider = try provider(for: requested) as? any RepositoryManagementProvider else {
            throw VersionControlError.unsupported("所选版本控制来源不支持此管理操作。")
        }
        try validateManagementAction(request.action)
        isPerformingOperation = true
        defer { isPerformingOperation = false }

        let result: RepositoryManagementResult
        var didStart = false
        do {
            try Task.checkCancellation()
            await progress(RepositoryOperationProgress("正在核对仓库状态…"))
            guard let current = try await provider.detect(at: requested.root), current.id == requested.id,
                  current.currentBranch == requested.currentBranch, current.remoteURL == requested.remoteURL else {
                throw VersionControlError.invalidRepository("仓库分支或远端已改变，请刷新后重新执行管理操作。")
            }
            let context = try await provider.managementContext(in: current)
            guard context.binding.id == current.id, context.stateToken == request.stateToken else {
                throw VersionControlError.invalidRepository("仓库状态已改变，请重新打开管理面板后再执行。")
            }
            try Task.checkCancellation()
            didStart = true
            let performed = try await provider.performManagement(request, in: current) { update in
                await progress(Self.sanitizedProgress(update))
            }
            result = sanitizedManagementResult(performed)
        } catch is CancellationError {
            result = RepositoryManagementResult(outcome: didStart ? .unknown : .cancelled,
                                                summary: didStart ? "操作结果需要核对。" : "操作已取消。",
                                                details: didStart
                                                    ? "操作已开始，但未取得适配器结果。请根据刷新后的状态核对，勿直接重复执行。"
                                                    : "取消不会自动回滚已经执行的仓库步骤，请核对刷新后的状态。")
        } catch {
            result = RepositoryManagementResult(outcome: didStart ? .unknown : .failed,
                                                summary: didStart ? "操作结果需要核对。" : "操作未完成。",
                                                details: (didStart ? "操作已开始，但未取得适配器结果。请根据刷新后的状态核对，勿直接重复执行。\n\n" : "")
                                                    + RepositoryDisplaySanitizer.redact(error.localizedDescription))
        }

        await progress(RepositoryOperationProgress("正在重新检查所有版本控制来源…"))
        let refreshed = await Task.detached { [self] in await refreshAfterOperation(workspace) }.value
        return WorkspaceManagementResult(result: result, workspace: refreshed.0, snapshots: refreshed.1)
    }

    public func stagedDiff(in binding: RepositoryBinding, path: String) async throws -> RepositoryPatch {
        try validateManagedPath(path)
        guard binding.capabilities.contains(.staging),
              let provider = try provider(for: binding) as? any RepositoryManagementProvider else {
            throw VersionControlError.unsupported("当前版本控制来源没有独立暂存区。")
        }
        return try await provider.stagedDiff(in: binding, path: path)
    }

    public func compare(in binding: RepositoryBinding, from: String, to: String) async throws -> RepositoryComparison {
        try validateComparisonRevision(from)
        try validateComparisonRevision(to)
        guard let provider = try provider(for: binding) as? any RepositoryComparisonProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持修订比较。")
        }
        let comparison = try await provider.compare(in: binding, from: from, to: to)
        try validateComparisonRevision(comparison.fromRevision)
        try validateComparisonRevision(comparison.toRevision)
        for change in comparison.files {
            try validateComparisonPath(change.path)
            if let original = change.originalPath { try validateComparisonPath(original) }
        }
        return comparison
    }

    public func comparisonDiff(in binding: RepositoryBinding, comparison: RepositoryComparison,
                               path: String) async throws -> RepositoryPatch {
        try validateComparisonPath(path)
        guard comparison.files.contains(where: { $0.path == path || $0.originalPath == path }) else {
            throw VersionControlError.invalidRepository("所选文件不属于当前比较范围。")
        }
        guard let provider = try provider(for: binding) as? any RepositoryComparisonProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持修订比较。")
        }
        return try await provider.comparisonDiff(in: binding, comparison: comparison, path: path)
    }

    private func validateManagementAction(_ action: RepositoryManagementAction) throws {
        switch action {
        case .stage(let paths), .unstage(let paths), .markResolved(let paths):
            guard !paths.isEmpty, Set(paths).count == paths.count else {
                throw VersionControlError.invalidRepository("请选择至少一个且不重复的文件。")
            }
            for path in paths { try validateManagedPath(path) }
        case .setRemote(let name, let url):
            try validateRemoteName(name)
            try validateRemoteURL(url)
        case .setIdentity(let name, let email):
            try validateIdentityField(name, label: "提交者姓名")
            try validateIdentityField(email, label: "提交者邮箱")
        case .push(let remote, let branch, _):
            try validateRemoteName(remote)
            try validateManagementName(branch, label: "分支名称")
        case .createBranch(let name, let startPoint):
            try validateManagementName(name, label: "分支名称")
            try validateManagementName(startPoint, label: "起点")
        case .switchBranch(let name), .merge(let name):
            try validateManagementName(name, label: "分支名称")
        case .finishMerge(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !message.contains("\0"), message.utf8.count <= 256 * 1024 else {
                throw VersionControlError.invalidRepository("合并说明不能为空且不能超过允许长度。")
            }
        }
    }

    private func validateRemoteName(_ value: String) throws {
        try validateManagementName(value, label: "远端名称")
        guard !value.hasPrefix("-") else {
            throw VersionControlError.invalidRepository("远端名称不能以连字符开头。")
        }
    }

    private func validateRemoteURL(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.utf8.count <= 16 * 1024 else {
            throw VersionControlError.invalidRepository("远端地址无效。")
        }
        // HTTPS 地址先通过通用端点策略排除凭据、查询与不规范主机；SSH 与其他适配器地址
        // 保留给具体版本控制工具作最终校验，不能在业务层误拒绝常见 Git SSH 写法。
        if value.lowercased().hasPrefix("https://") {
            do {
                _ = try RepositoryEndpointPolicy(httpsAddress: value, tlsMode: .modern)
            } catch {
                throw VersionControlError.invalidRepository(error.localizedDescription)
            }
        }
    }

    private func validateIdentityField(_ value: String, label: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.utf8.count <= 4 * 1024 else {
            throw VersionControlError.invalidRepository("\(label)无效。")
        }
    }

    func validateManagedPath(_ path: String) throws { try validateCommitPath(path) }

    /// `.` 是版本控制适配器在“只读修订比较”中表示工作副本根节点的通用标记。
    /// 它不属于普通受控文件路径，所以绝不能复用于暂存、提交、冲突解决等写操作。
    private func validateComparisonPath(_ path: String) throws {
        if path == "." { return }
        try validateManagedPath(path)
    }

    private func validateComparisonRevision(_ value: String) throws {
        try validateManagementName(value, label: "修订范围")
    }

    private func validateManagementName(_ value: String, label: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.utf8.count <= 4 * 1024 else {
            throw VersionControlError.invalidRepository("\(label)无效。")
        }
    }

    private func sanitizedManagementResult(_ result: RepositoryManagementResult) -> RepositoryManagementResult {
        RepositoryManagementResult(outcome: result.outcome,
                                   summary: RepositoryDisplaySanitizer.redact(result.summary),
                                   details: RepositoryDisplaySanitizer.redact(result.details))
    }

    /// 同一服务实例串行写入；只执行一个已识别的目标，完成后刷新全部绑定。
    public func perform(_ operation: RepositoryOperationKind, bindingID: String, in workspace: Workspace,
                        progress: @escaping RepositoryOperationProgressHandler) async throws -> WorkspaceOperationResult {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.performUnlocked(operation, bindingID: bindingID, in: workspace, progress: progress)
        }
    }

    private func performUnlocked(_ operation: RepositoryOperationKind, bindingID: String, in workspace: Workspace,
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
            let performed = try await provider.perform(operation, in: current) { update in
                await progress(Self.sanitizedProgress(update))
            }
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
        do { refreshed = try await open(directory: previous.directory, linkedDirectories: previous.linkedDirectories) }
        catch {
            refreshed = Workspace(directory: previous.directory, linkedDirectories: previous.linkedDirectories, bindings: previous.bindings,
                issues: ["操作后无法重新识别工作区：\(RepositoryDisplaySanitizer.redact(error.localizedDescription))"])
        }
        var snapshots: [BindingSnapshot] = []
        for binding in refreshed.bindings { snapshots.append(await load(binding)) }
        return (refreshed, snapshots)
    }

    func provider(for binding: RepositoryBinding) throws -> any VersionControlProvider {
        guard let provider = providers.first(where: { $0.id == binding.providerID }) else {
            throw VersionControlError.unsupported("未注册对应的版本控制适配器。")
        }
        return provider
    }
}
