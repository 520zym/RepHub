import CryptoKit
import Darwin
import Foundation
import ToolExecution
import VersionControlCore

private struct GitHistoryCursor: Codable {
    enum Kind: String, Codable { case repository, file }

    let version: Int
    let kind: Kind
    let bindingID: String
    let reference: String?
    let path: String?
    let tips: [String]
    let offset: Int
    let trackedPath: String?

    init(kind: Kind, bindingID: String, reference: String?, path: String? = nil, tips: [String], offset: Int, trackedPath: String?) {
        self.version = 1
        self.kind = kind
        self.bindingID = bindingID
        self.reference = reference
        self.path = path
        self.tips = tips
        self.offset = offset
        self.trackedPath = trackedPath
    }

    func advanced(by count: Int, trackedPath: String? = nil) -> GitHistoryCursor {
        GitHistoryCursor(
            kind: kind, bindingID: bindingID, reference: reference, path: path, tips: tips,
            offset: offset + count, trackedPath: trackedPath ?? self.trackedPath
        )
    }


}

/// Git 适配器。读取与受限的获取／快进更新均通过参数数组执行，不经过 shell。
public final class GitProvider: RepositoryOperationProvider, RepositoryHistoryPagingProvider, RepositoryAcquisitionProvider, RepositoryCommitProvider, RepositorySetupProvider, RepositoryManagementProvider, RepositoryComparisonProvider, @unchecked Sendable {
    public let id: ProviderID = .git
    public let displayName = "Git"

    private let runner: CommandRunner
    private let fileManager: FileManager

    public init(runner: CommandRunner = CommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public let acquisitionOption = RepositoryAcquisitionOption(
        providerID: .git,
        title: "Git",
        actionTitle: "克隆",
        supportsBrowsing: false,
        supportsCredentials: false
    )

    public let setupOption = RepositorySetupOption(providerID: .git, title: "Git", requiresRemote: false)

    /// 克隆到由上层预留的全新目录。认证仍交由用户现有的 Git 凭据助手或 SSH Agent，
    /// 因而不把密码放入 URL、参数或应用配置。
    public func acquire(
        _ location: RemoteRepositoryLocation,
        to destination: URL,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws {
        guard location.credentials == nil else {
            throw VersionControlError.unsupported("Git 克隆使用系统凭据助手或 SSH Agent，不在 RepHub 中保存账号密码。")
        }
        let remote = try validatedCloneLocation(location.url)
        try validateCloneDestination(destination)

        await progress(RepositoryOperationProgress("正在连接 Git 远端…"))
        let transferProgress = GitTransferProgressReporter(progress)
        let result = try await git(
            // 先只下载对象，禁止在尚未检查属性前写出工作区文件。
            ["clone", "--progress", "--no-checkout", "--no-recurse-submodules", "--", remote, destination.path],
            in: destination.deletingLastPathComponent(),
            timeout: 600,
            restrictRemoteProtocols: true,
            onOutput: { lines in await transferProgress.accept(lines) }
        )
        _ = try requireSuccess(result, tool: "git")

        await progress(RepositoryOperationProgress("正在检查检出配置…"))
        guard try findGitMetadata(above: destination) != nil else {
            throw VersionControlError.executionFailed("Git 克隆完成后未找到有效的工作副本。")
        }
        // 全局/本地 filter 和上游 .gitattributes 均可能启动外部程序。沿用更新前的
        // 保守策略：只要发现相关配置或属性，就保留未检出的临时副本并拒绝继续执行。
        if try await hasHead(destination), try await containsCheckoutFilter(inTree: "HEAD", directory: destination) {
            throw VersionControlError.unsupported("该 Git 仓库配置了工作区过滤器，RepHub 不会执行其外部过滤程序。")
        }
        if try await hasHead(destination) {
            await progress(RepositoryOperationProgress("正在写入 Git 工作区文件…"))
            let checkout = try await git(
                // `checkout --progress HEAD` 不切换当前分支，但可让 Git 报告真实的 Updating files 阶段。
                // `core.hooksPath=/dev/null`、过滤器和子模块检查仍由 `git` 辅助方法与前置校验保证。
                ["checkout", "--force", "--progress", "--recurse-submodules=no", "HEAD"],
                in: destination,
                timeout: 600,
                onOutput: { lines in await transferProgress.accept(lines) }
            )
            _ = try requireSuccess(checkout, tool: "git")
        }

        await progress(RepositoryOperationProgress("正在确认工作副本…"))
        _ = try await detect(at: destination)
        await progress(RepositoryOperationProgress("Git 工作副本已就绪。"))
    }

    public func detect(at directory: URL) async throws -> RepositoryBinding? {
        guard let metadataDirectory = try findGitMetadata(above: directory) else { return nil }

        let result = try await git(["rev-parse", "--show-toplevel"], in: metadataDirectory)
        let rootResult = try requireSuccess(result, tool: "git")
        let rootPath = rootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { throw VersionControlError.invalidData("Git 未返回工作区根目录。") }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL

        let branchResult = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        if branchResult.exitCode != 0 && branchResult.exitCode != 1 { _ = try requireSuccess(branchResult, tool: "git") }
        let branch = branchResult.exitCode == 0
            ? branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        // 优先展示当前分支明确跟踪的远端；无上游时才回退 origin，避免界面与更新目标不一致。
        let configuredRemote = branch.isEmpty ? nil : try await configuredRemoteName(for: branch, in: root)
        let remote: String?
        if let configuredRemote {
            remote = try await remoteURL(named: configuredRemote, in: root)
        } else {
            remote = try await remoteURL(named: "origin", in: root)
        }

        return RepositoryBinding(
            providerID: .git,
            providerName: displayName,
            root: root,
            currentBranch: branch,
            remoteURL: remote?.isEmpty == false ? remote : nil,
            capabilities: [.status, .diff, .history, .branches, .commitGraph, .fetch, .update, .fileHistory, .synchronization, .commit, .push, .staging, .branchManagement, .conflictResolution, .revisionComparison]
        )
    }

    public func initialize(_ request: RepositorySetupRequest, progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositorySetupResult {
        guard request.providerID == .git else { throw VersionControlError.unsupported("该初始化请求不属于 Git。") }
        let directory = request.directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VersionControlError.invalidRepository("初始化目录不存在：\(directory.path)")
        }
        guard try findGitMetadata(above: directory) == nil else { throw VersionControlError.invalidRepository("目标目录已受 Git 管理，不会覆盖。") }
        guard !fileManager.fileExists(atPath: directory.appendingPathComponent(".svn").path) else { throw VersionControlError.invalidRepository("目标目录已受 SVN 管理，请先通过共管工作流打开。") }
        let branch = request.initialBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        try await requireValidReferenceName(branch, in: directory)
        let remoteLocation: String?
        if let remote = request.remote {
            guard remote.credentials == nil else { throw VersionControlError.unsupported("Git 初始化使用系统凭据助手或 SSH Agent。") }
            remoteLocation = try validatedCloneLocation(remote.url)
        } else { remoteLocation = nil }
        await progress(RepositoryOperationProgress("正在初始化 Git 仓库…"))
        _ = try requireSuccess(try await git(["init", "--initial-branch=\(branch)", "--", directory.path], in: directory), tool: "git")
        if let remoteLocation {
            _ = try requireSuccess(try await git(["remote", "add", "origin", "--", remoteLocation], in: directory), tool: "git")
        }
        return RepositorySetupResult(outcome: .succeeded, directory: directory, summary: "已初始化 Git 仓库。")
    }

    /// 只执行对当前绑定明确配置的上游的获取或快进更新。
    ///
    /// 更新前拒绝任何已跟踪的本地修改、进行中的合并/变基、游离 HEAD 与分叉状态；
    /// 因而不会为完成更新而 stash、reset、clean 或 rebase。
    public func perform(
        _ operation: RepositoryOperationKind,
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryOperationResult {
        try ensureGit(binding)
        switch operation {
        case .fetch:
            return try await fetch(in: binding, progress: progress)
        case .update:
            return try await update(in: binding, progress: progress)
        }
    }

    public func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        try ensureGit(binding)
        let result = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: binding.root)
        let output = try requireSuccess(result, tool: "git")
        return try parseStatus(output.data)
    }

    public func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        try ensureGit(binding)
        guard limit > 0 else { return [] }
        var arguments = ["log", "--topo-order", "--date=iso-strict", "--max-count=\(limit)", "--format=%H%x00%an%x00%aI%x00%P%x00%D%x00%B%x00%x1e"]
        if let reference, !reference.isEmpty {
            arguments += ["--end-of-options", reference]
        } else {
            // 游离 HEAD 不一定被 --all 所指向，仍需作为当前可见历史读取。
            arguments += ["--all", "HEAD"]
        }
        let result = try await git(arguments, in: binding.root)
        if result.exitCode != 0 {
            let hasReference = !(reference?.isEmpty ?? true)
            if !hasReference, try await isEmptyRepository(binding.root) { return [] }
            _ = try requireSuccess(result, tool: "git")
        }
        return try parseHistory(result.data)
    }

    /// 分页历史固定首次请求可见的提交端点。之后即使其他客户端更新了分支或远端引用，
    /// 也仍沿用这些不可变的对象 ID，避免 "加载更多" 发生重复或跳过。
    public func historyPage(in binding: RepositoryBinding, request: HistoryPageRequest) async throws -> RepositoryHistoryPage {
        try ensureGit(binding)
        let limit = try validatedHistoryPageLimit(request.limit)
        let cursor: GitHistoryCursor
        if let encoded = request.cursor {
            cursor = try decodeHistoryCursor(encoded)
            try validate(cursor: cursor, kind: .repository, binding: binding, reference: request.reference, path: nil)
        } else {
            cursor = GitHistoryCursor(
                kind: .repository,
                bindingID: binding.id,
                reference: normalizedHistoryReference(request.reference),
                tips: try await fixedHistoryTips(in: binding.root, reference: request.reference),
                offset: 0,
                trackedPath: nil
            )
        }
        guard !cursor.tips.isEmpty else { return RepositoryHistoryPage(revisions: []) }

        let result = try await git(
            [
                "log", "--topo-order", "--date=iso-strict", "--skip=\(cursor.offset)", "--max-count=\(limit + 1)",
                "--format=%H%x00%an%x00%aI%x00%P%x00%D%x00%B%x00%x1e", "--end-of-options"
            ] + cursor.tips,
            in: binding.root
        )
        let output = try requireSuccess(result, tool: "git")
        let revisions = try parseHistory(output.data)
        let page = Array(revisions.prefix(limit))
        let next = revisions.count > limit
            ? try encodeHistoryCursor(cursor.advanced(by: page.count))
            : nil
        return RepositoryHistoryPage(revisions: page, nextCursor: next)
    }

    /// 以 Git 的重命名追溯读取单个文件的提交历史。命令和路径均以参数数组传递，
    /// `--literal-pathspecs` 防止以冒号开头的文件名被解释为路径规格语法。
    public func fileHistory(
        in binding: RepositoryBinding,
        path: String,
        limit: Int,
        reference: String?
    ) async throws -> [FileHistoryEntry] {
        try ensureGit(binding)
        guard !path.isEmpty else { throw VersionControlError.invalidData("未提供文件路径。") }
        guard limit > 0 else { return [] }
        guard limit <= 500 else {
            throw VersionControlError.unsupported("单文件历史一次最多读取 500 条；请缩小范围后重试。")
        }

        let start = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = (start?.isEmpty == false) ? start! : "HEAD"
        let result = try await git(
            [
                "--literal-pathspecs", "log", "--follow", "-M", "--name-status", "-z", "--topo-order", "--date=iso-strict",
                "--max-count=\(limit)",
                "--format=%x1e%H%x00%an%x00%aI%x00%P%x00%D%x00%B%x00",
                "--end-of-options", revision, "--", path
            ],
            in: binding.root
        )
        if result.exitCode != 0 {
            if try await isEmptyRepository(binding.root) { return [] }
            _ = try requireSuccess(result, tool: "git")
        }
        return try parseFileHistory(result.data, newestPath: path)
    }

    /// 固定初始提交与路径，从同一追溯链读取所需前缀后切页。
    /// --follow 不能与 --skip 混用：被跳过的改名会丢失追溯状态；从单一父线重启也可能遗漏合并历史。
    public func fileHistoryPage(
        in binding: RepositoryBinding,
        path: String,
        request: HistoryPageRequest
    ) async throws -> FileHistoryPage {
        try ensureGit(binding)
        guard !path.isEmpty else { throw VersionControlError.invalidData("未提供文件路径。") }
        let limit = try validatedHistoryPageLimit(request.limit)
        let cursor: GitHistoryCursor
        if let encoded = request.cursor {
            cursor = try decodeHistoryCursor(encoded)
            try validate(cursor: cursor, kind: .file, binding: binding, reference: request.reference, path: path)
        } else {
            let reference = normalizedHistoryReference(request.reference) ?? "HEAD"
            guard let tip = try await resolvedCommit(reference, in: binding.root) else {
                if try await isEmptyRepository(binding.root) { return FileHistoryPage(entries: []) }
                throw VersionControlError.invalidRepository("Git 引用不存在或不指向提交：\(reference)")
            }
            cursor = GitHistoryCursor(
                kind: .file,
                bindingID: binding.id,
                reference: normalizedHistoryReference(request.reference),
                path: path,
                tips: [tip],
                offset: 0,
                trackedPath: path
            )
        }
        guard let tip = cursor.tips.first else {
            throw VersionControlError.invalidData("Git 文件历史游标不完整。")
        }
        let (readCount, overflow) = cursor.offset.addingReportingOverflow(limit + 1)
        guard !overflow else { throw VersionControlError.invalidData("Git 文件历史游标范围无效。") }
        let result = try await git(
            [
                "--literal-pathspecs", "log", "--follow", "-M", "--name-status", "-z", "--topo-order", "--date=iso-strict",
                "--max-count=\(readCount)",
                "--format=%x1e%H%x00%an%x00%aI%x00%P%x00%D%x00%B%x00",
                "--end-of-options", tip, "--", path
            ],
            in: binding.root
        )
        let output = try requireSuccess(result, tool: "git")
        let entries = try parseFileHistory(output.data, newestPath: path)
        let page = Array(entries.dropFirst(cursor.offset).prefix(limit))
        let next = entries.count > cursor.offset + limit
            ? try encodeHistoryCursor(cursor.advanced(by: page.count))
            : nil
        return FileHistoryPage(entries: page, nextCursor: next)
    }

    /// 使用历史记录中该修订对应的路径，确保重命名前的提交不会错误地按当前文件名取差异。
    public func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch {
        try ensureGit(binding)
        guard !entry.path.isEmpty else { throw VersionControlError.invalidData("历史文件路径为空。") }
        let revision = entry.pegRevision?.isEmpty == false ? entry.pegRevision! : entry.revision.id
        let result = try await git(
            [
                "--literal-pathspecs", "-c", "core.quotepath=false", "show", "--format=", "--first-parent", "--patch", "--no-ext-diff", "--no-textconv",
                "--end-of-options", revision, "--", entry.path
            ],
            in: binding.root
        )
        return RepositoryPatch(text: try requireSuccess(result, tool: "git").output)
    }

    /// 同步状态只比较当前 HEAD 与实际配置的上游引用；不会把其他本地分支的提交计算为待推送。
    /// 远端引用只读取本机已有内容，调用方应先获取远端以刷新这一判断。
    public func synchronization(
        in binding: RepositoryBinding,
        revisions: [Revision],
        path: String?
    ) async throws -> RepositorySyncStatus {
        try ensureGit(binding)
        _ = path // Git 的 ahead/behind 定义为分支拓扑，不能按单文件缩小计数。

        let branchResult = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: binding.root)
        guard branchResult.exitCode == 0 else {
            if branchResult.exitCode == 1 {
                return unknownSynchronization("当前处于游离 HEAD，无法确定上游同步状态。")
            }
            _ = try requireSuccess(branchResult, tool: "git")
            return unknownSynchronization("无法确定当前 Git 分支。")
        }
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteResult = try await git(["config", "--get", "branch.\(branch).remote"], in: binding.root)
        if remoteResult.exitCode == 0,
           remoteResult.output.trimmingCharacters(in: .whitespacesAndNewlines) == "." {
            return unknownSynchronization("当前分支的上游是本地分支，不存在可判断的远端待推送状态。")
        }

        let upstreamResult = try await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: binding.root)
        guard upstreamResult.exitCode == 0 else {
            return unknownSynchronization("当前分支未配置可用上游，无法判断待更新或待推送提交。")
        }
        let upstream = upstreamResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upstream.isEmpty else {
            return unknownSynchronization("当前分支未配置可用上游，无法判断待更新或待推送提交。")
        }

        // 同一轮读取固定两端提交，之后的计数与行状态都基于这对 SHA，避免并发 fetch 或切换分支造成前后不一致。
        let endpointsResult = try await git(["rev-parse", "--revs-only", "--end-of-options", "HEAD", "@{upstream}"], in: binding.root)
        guard endpointsResult.exitCode == 0 else {
            return unknownSynchronization("本机缺少上游引用或引用已失效；请先获取远端后重试。")
        }
        let endpoints = endpointsResult.output.split(whereSeparator: \.isNewline).map(String.init)
        guard endpoints.count == 2 else {
            return unknownSynchronization("Git 未返回完整的当前提交与上游提交。")
        }
        let head = endpoints[0]
        let upstreamRevision = endpoints[1]

        let counts = try await git(["rev-list", "--left-right", "--count", "\(head)...\(upstreamRevision)"], in: binding.root)
        guard counts.exitCode == 0 else {
            return unknownSynchronization("本机缺少上游引用或引用已失效；请先获取远端后重试。")
        }
        let parts = counts.output.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let outgoing = Int(parts[0]), let incoming = Int(parts[1]) else {
            return unknownSynchronization("Git 未返回可解析的上游提交计数。")
        }

        let states = try await synchronizationStates(
            for: revisions.map(\.id),
            head: head,
            upstream: upstreamRevision,
            in: binding.root
        )
        let summary: String
        if incoming == 0 && outgoing == 0 {
            summary = "当前分支与已获取的上游一致"
        } else {
            summary = "待更新 \(incoming) 个，待推送 \(outgoing) 个"
        }
        let rowLimitNote = states.values.contains(.uncertain)
            ? " 个别列表提交超出 5,000 条行状态判断范围，已标记为需核对。"
            : ""
        return RepositorySyncStatus(
            incomingCount: incoming,
            outgoingCount: outgoing,
            states: states,
            summary: summary,
            detail: "当前分支 \(branch) · 基于已获取的 \(upstream)；在“更新”中执行“获取远端”可刷新判断。" + rowLimitNote
        )
    }

    public func branches(in binding: RepositoryBinding) async throws -> [BranchReference] {
        try ensureGit(binding)
        let result = try await git(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(HEAD)%00%1e", "refs/heads", "refs/remotes", "refs/tags"], in: binding.root)
        let output = try requireSuccess(result, tool: "git")
        return try output.data.split(separator: 0x1e, omittingEmptySubsequences: true).filter { hasNonWhitespaceByte($0) }.compactMap { record in
            var fields = record.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            if fields.last?.isEmpty == true { fields.removeLast() }
            guard fields.count == 3 else { throw VersionControlError.invalidData("Git 分支输出字段不完整。") }
            let fullName = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let revisionID = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let isCurrent = fields[2].trimmingCharacters(in: .whitespacesAndNewlines) == "*"
            if fullName.hasPrefix("refs/heads/") {
                return BranchReference(name: String(fullName.dropFirst("refs/heads/".count)), revisionID: revisionID, kind: .local, isCurrent: isCurrent)
            }
            if fullName.hasPrefix("refs/remotes/") {
                return BranchReference(name: String(fullName.dropFirst("refs/remotes/".count)), revisionID: revisionID, kind: .remote, isCurrent: isCurrent)
            }
            if fullName.hasPrefix("refs/tags/") {
                return BranchReference(name: String(fullName.dropFirst("refs/tags/".count)), revisionID: revisionID, kind: .tag, isCurrent: false)
            }
            return nil
        }
    }

    public func managementContext(in binding: RepositoryBinding) async throws -> RepositoryManagementContext {
        try ensureGit(binding)
        let changes = try await status(in: binding)
        let conflicts = changes.filter { $0.kind == .conflicted }.map { RepositoryConflict(path: $0.path, detail: "Git 标记为未解决冲突") }
        let remoteNames = try requireSuccess(try await git(["remote"], in: binding.root), tool: "git").output.split(whereSeparator: \.isNewline).map(String.init)
        var remotes: [RepositoryRemote] = []
        for name in remoteNames {
            if let url = try await remoteURL(named: name, in: binding.root) {
                remotes.append(RepositoryRemote(name: name, url: url, pushURL: try await pushURL(named: name, in: binding.root)))
            }
        }
        let head = try await optionalHead(in: binding.root)
        let mergeHead = try await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: binding.root)
        let authorName = try await localGitConfig("user.name", in: binding.root)
        let authorEmail = try await localGitConfig("user.email", in: binding.root)
        return RepositoryManagementContext(binding: binding, stateToken: try await managementToken(in: binding.root), headRevision: head, remotes: remotes, branches: try await branches(in: binding), changes: changes, conflicts: conflicts, canFinishMerge: mergeHead.exitCode == 0 && conflicts.isEmpty, authorName: authorName, authorEmail: authorEmail)
    }

    public func performManagement(_ request: RepositoryManagementRequest, in binding: RepositoryBinding,
                                  progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryManagementResult {
        var writeStarted = false
        do {
            try Task.checkCancellation()
            try ensureGit(binding)
            guard request.stateToken == (try await managementToken(in: binding.root)) else {
                return RepositoryManagementResult(outcome: .failed, summary: "工作区状态已变化，请刷新后重试。")
            }
            switch request.action {
            case let .setRemote(name, url):
                try await requireValidReferenceName(name, in: binding.root)
                let safeURL = try validatedCloneLocation(url)
                let names = try requireSuccess(try await git(["remote"], in: binding.root), tool: "git").output.split(whereSeparator: \.isNewline)
                let exists = names.contains(Substring(name))
                try Task.checkCancellation()
                writeStarted = true
                _ = try requireSuccess(try await git(exists ? ["remote", "set-url", "--", name, safeURL] : ["remote", "add", "--", name, safeURL], in: binding.root), tool: "git")
                return RepositoryManagementResult(outcome: .succeeded, summary: exists ? "已更新远端 \(name)。" : "已添加远端 \(name)。")
            case let .setIdentity(name, email):
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !email.isEmpty, email.contains("@"),
                      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw VersionControlError.invalidData("提交姓名或邮箱无效。")
                }
                try Task.checkCancellation()
                writeStarted = true
                _ = try requireSuccess(try await git(["config", "--local", "user.name", name], in: binding.root), tool: "git")
                _ = try requireSuccess(try await git(["config", "--local", "user.email", email], in: binding.root), tool: "git")
                return RepositoryManagementResult(outcome: .succeeded, summary: "已保存此仓库的提交身份。")
            case let .stage(selection):
                let paths = try managedPaths(selection, root: binding.root)
                try await requireCurrentChangePaths(paths, binding: binding)
                try await ensureSafeIndexOperation(paths, root: binding.root)
                let conflicts = Set(try await status(in: binding).filter { $0.kind == .conflicted }.map(\.path))
                guard conflicts.isDisjoint(with: paths) else {
                    return RepositoryManagementResult(outcome: .conflicts, summary: "所选文件仍有未解决冲突。")
                }
                try Task.checkCancellation()
                writeStarted = true
                _ = try requireSuccess(try await git(["--literal-pathspecs", "add", "-A", "--"] + paths, in: binding.root), tool: "git")
                return RepositoryManagementResult(outcome: .succeeded, summary: "已暂存 \(paths.count) 个文件。")
            case let .unstage(selection):
                let changes = try await status(in: binding)
                let originalPaths = changes.filter { selection.contains($0.path) }.compactMap(\.originalPath)
                let paths = try managedPaths(selection + originalPaths, root: binding.root)
                try await requireCurrentChangePaths(paths, binding: binding)
                let command = (try await optionalHead(in: binding.root)) == nil
                    ? ["--literal-pathspecs", "rm", "--cached", "--ignore-unmatch", "--"] + paths
                    : ["--literal-pathspecs", "restore", "--staged", "--"] + paths
                try Task.checkCancellation()
                writeStarted = true
                _ = try requireSuccess(try await git(command, in: binding.root), tool: "git")
                return RepositoryManagementResult(outcome: .succeeded, summary: "已取消暂存 \(paths.count) 个文件。")
            case let .createBranch(name, start):
                try await requireValidReferenceName(name, in: binding.root)
                guard let startID = try await resolvedCommit(start, in: binding.root) else {
                    throw VersionControlError.invalidData("分支起点不存在或不是提交。")
                }
                let exists = try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: binding.root)
                guard exists.exitCode == 1 else { throw VersionControlError.invalidData("分支已存在或无法核对，请刷新后重试。") }
                try Task.checkCancellation()
                writeStarted = true
                _ = try requireSuccess(try await git(["branch", "--", name, startID], in: binding.root), tool: "git")
                return RepositoryManagementResult(outcome: .succeeded, summary: "已创建分支 \(name)。")
            case let .switchBranch(name):
                try await requireValidReferenceName(name, in: binding.root)
                try await ensureSafeBranchOperation(in: binding.root)
                let local = try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: binding.root)
                guard local.exitCode == 0 else { throw VersionControlError.invalidData("请选择本地分支；远端分支可先作为起点创建本地分支。") }
                try await ensureSafeTargetTree(name, in: binding.root)
                try Task.checkCancellation()
                writeStarted = true
                _ = try requireSuccess(try await git(["switch", "--", name], in: binding.root), tool: "git")
                return RepositoryManagementResult(outcome: .succeeded, summary: "已切换到分支 \(name)。")
            case let .merge(reference):
                try await ensureSafeBranchOperation(in: binding.root)
                try await ensureSafeTargetTree(reference, in: binding.root)
                guard let target = try await resolvedCommit(reference, in: binding.root) else { throw VersionControlError.invalidData("合并目标不存在。") }
                await progress(RepositoryOperationProgress("正在合并 \(reference)…"))
                try Task.checkCancellation()
                writeStarted = true
                let merged = try await git(["merge", "--no-commit", "--no-ff", "--no-edit", "--no-verify", "--", target], in: binding.root, timeout: 90)
                if merged.exitCode == 0 {
                    let pending = try await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: binding.root)
                    return RepositoryManagementResult(outcome: .succeeded, summary: pending.exitCode == 0 ? "已准备合并，请确认合并提交说明。" : "当前分支已包含目标版本，无需合并。")
                }
                let conflicts = try await status(in: binding).filter { $0.kind == .conflicted }
                return RepositoryManagementResult(outcome: conflicts.isEmpty ? .failed : .conflicts,
                    summary: conflicts.isEmpty ? "Git 合并未完成。" : "合并产生冲突，请先解决。", details: sanitizedGitFailure(merged))
            case let .finishMerge(message):
                let merge = try await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: binding.root)
                guard merge.exitCode == 0 else { throw VersionControlError.invalidData("当前没有待完成的合并。") }
                guard !(try await status(in: binding)).contains(where: { $0.kind == .conflicted }) else {
                    return RepositoryManagementResult(outcome: .conflicts, summary: "仍有未解决冲突。")
                }
                let subject = message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !subject.isEmpty, !subject.contains("\0") else { throw VersionControlError.invalidData("请填写有效的合并提交说明。") }
                try Task.checkCancellation()
                writeStarted = true
                _ = try requireSuccess(try await git(["commit", "--no-verify", "--no-gpg-sign", "-m", subject], in: binding.root, timeout: 90), tool: "git")
                return RepositoryManagementResult(outcome: .succeeded, summary: "已创建合并提交。")
            case let .markResolved(selection):
                let paths = try managedPaths(selection, root: binding.root)
                let conflicts = Set(try await status(in: binding).filter { $0.kind == .conflicted }.map(\.path))
                guard Set(paths).isSubset(of: conflicts) else { throw VersionControlError.invalidData("只能标记当前冲突文件。") }
                for path in paths { try verifyResolvedTextFile(path, root: binding.root) }
                try await ensureSafeIndexOperation(paths, root: binding.root)
                try Task.checkCancellation()
                writeStarted = true
                _ = try requireSuccess(try await git(["--literal-pathspecs", "add", "--"] + paths, in: binding.root), tool: "git")
                return RepositoryManagementResult(outcome: .succeeded, summary: "已记录 \(paths.count) 个冲突文件的解决结果。")
            case let .push(remote, branch, setUpstream):
                _ = try await currentBranch(in: binding.root)
                try await requireValidReferenceName(branch, in: binding.root)
                try await requireValidReferenceName(remote, in: binding.root)
                guard let targetURL = try await pushURL(named: remote, in: binding.root) else { throw VersionControlError.invalidData("未配置所选远端。") }
                let sourceHead = try await currentHead(in: binding.root)
                await progress(RepositoryOperationProgress("正在推送 \(branch)…"))
                var args = ["push", "--porcelain", "--no-verify", "--no-follow-tags", "--recurse-submodules=no"]
                if setUpstream { args.append("--set-upstream") }
                args += ["--", remote, "HEAD:refs/heads/\(branch)"]
                try Task.checkCancellation()
                writeStarted = true
                let pushed = try await git(args, in: binding.root, timeout: 120, restrictRemoteProtocols: true)
                if pushed.exitCode != 0 {
                    let text = sanitizedGitFailure(pushed)
                    let rejected = text.localizedCaseInsensitiveContains("rejected") || text.localizedCaseInsensitiveContains("non-fast-forward")
                    return RepositoryManagementResult(outcome: rejected ? .failed : .unknown,
                        summary: rejected ? "远端拒绝了推送。" : "推送结果不明确，远端状态未知。", details: text)
                }
                let verified = try await git(["ls-remote", "--heads", "--", targetURL, "refs/heads/\(branch)"], in: binding.root, timeout: 45, restrictRemoteProtocols: true)
                guard verified.exitCode == 0, verified.output.split(whereSeparator: \.isWhitespace).first.map(String.init) == sourceHead else {
                    return RepositoryManagementResult(outcome: .unknown, summary: "推送已返回成功，但远端分支尚未确认到本次提交。", details: sanitizedGitFailure(verified))
                }
                return RepositoryManagementResult(outcome: .succeeded, summary: "已推送当前分支并确认远端提交。")
            }
        } catch is CancellationError {
            return RepositoryManagementResult(outcome: writeStarted ? .unknown : .cancelled,
                summary: writeStarted ? "操作已取消，结果需要核对。" : "已取消，尚未修改仓库。")
        } catch {
            return RepositoryManagementResult(outcome: writeStarted ? .unknown : .failed,
                summary: writeStarted ? "操作结果需要核对。" : "操作前检查未通过。", details: error.localizedDescription)
        }
    }

    public func stagedDiff(in binding: RepositoryBinding, path: String) async throws -> RepositoryPatch {
        try ensureGit(binding); _ = try CommitFileSnapshot.validatedURL(root: binding.root, path: path)
        let result = try await git(["--literal-pathspecs", "diff", "--cached", "--no-ext-diff", "--no-textconv", "--", path], in: binding.root)
        return RepositoryPatch(text: try requireSuccess(result, tool: "git").output)
    }

    public func compare(in binding: RepositoryBinding, from: String, to: String) async throws -> RepositoryComparison {
        try ensureGit(binding); guard let fromID = try await resolvedCommit(from, in: binding.root), let toID = try await resolvedCommit(to, in: binding.root) else { throw VersionControlError.invalidData("比较版本不存在或不是提交。") }
        let result = try await git(["diff", "--name-status", "-z", "-M", "-C", fromID, toID, "--"], in: binding.root)
        return RepositoryComparison(fromRevision: fromID, toRevision: toID, files: try parseNameStatus(try requireSuccess(result, tool: "git").data))
    }

    public func comparisonDiff(in binding: RepositoryBinding, comparison: RepositoryComparison, path: String) async throws -> RepositoryPatch {
        try ensureGit(binding); _ = try CommitFileSnapshot.validatedURL(root: binding.root, path: path)
        guard isGitObjectID(comparison.fromRevision), isGitObjectID(comparison.toRevision),
              try await resolvedCommit(comparison.fromRevision, in: binding.root) == comparison.fromRevision,
              try await resolvedCommit(comparison.toRevision, in: binding.root) == comparison.toRevision else { throw VersionControlError.invalidData("比较版本已失效。") }
        guard comparison.files.contains(where: { $0.path == path || $0.originalPath == path }) else { throw VersionControlError.invalidData("该文件不属于当前比较范围。") }
        let change = comparison.files.first { $0.path == path || $0.originalPath == path }
        let paths = Array(Set([change?.path, change?.originalPath].compactMap { $0 })).sorted()
        let result = try await git(["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "-M", comparison.fromRevision, comparison.toRevision, "--"] + paths, in: binding.root)
        return RepositoryPatch(text: try requireSuccess(result, tool: "git").output)
    }

    public func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] {
        try ensureGit(binding)
        let result = try await git(["show", "--format=", "--first-parent", "--name-status", "-z", "-M", "-C", "--end-of-options", revision, "--"], in: binding.root)
        let output = try requireSuccess(result, tool: "git")
        return try parseNameStatus(output.data)
    }

    public func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        try ensureGit(binding)
        let pathArguments = path.map { ["--", $0] } ?? ["--"]
        if let revision, !revision.isEmpty {
            let result = try await git(["show", "--format=", "--first-parent", "--patch", "--no-ext-diff", "--no-textconv", "--end-of-options", revision] + pathArguments, in: binding.root)
            return RepositoryPatch(text: try requireSuccess(result, tool: "git").output)
        }

        var fragments: [String] = []
        if try await hasHead(binding.root) {
            let result = try await git(["diff", "--no-ext-diff", "--no-textconv", "HEAD"] + pathArguments, in: binding.root)
            fragments.append(try requireSuccess(result, tool: "git").output)
        } else {
            let result = try await git(["diff", "--cached", "--no-ext-diff", "--no-textconv"] + pathArguments, in: binding.root)
            fragments.append(try requireSuccess(result, tool: "git").output)
            // 空仓库中，暂存后继续编辑时仍需展示工作区相对暂存区的差异。
            let worktree = try await git(["diff", "--no-ext-diff", "--no-textconv"] + pathArguments, in: binding.root)
            fragments.append(try requireSuccess(worktree, tool: "git").output)
        }

        let changes = try await status(in: binding)
        let untracked = changes.filter { $0.kind == .untracked && (path == nil || $0.path == path) }
        for change in untracked {
            let result = try await git(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", change.path], in: binding.root)
            // git diff --no-index 用退出码 1 表示发现差异，是成功读取而不是失败。
            guard result.exitCode == 0 || result.exitCode == 1 else { _ = try requireSuccess(result, tool: "git"); continue }
            let text = result.output.isEmpty ? "二进制文件新增：\(change.path)\n" : result.output
            fragments.append(text)
        }
        return RepositoryPatch(text: fragments.filter { !$0.isEmpty }.joined(separator: fragments.count > 1 ? "\n" : ""))
    }

    /// Git 提交始终以工作区当前内容构造一个独立的临时索引。这样既不会把用户未选择的
    /// 暂存内容带入提交，也不会用 `git add` 改写用户的真实索引。
    public func prepareCommit(in binding: RepositoryBinding) async throws -> RepositoryCommitPreparation {
        try ensureGit(binding)
        let baseRevision = try await optionalHead(in: binding.root)
        // Git+SVN 共管目录会把 `.svn` 当作普通未跟踪文件；版本管理元数据从不进入提交候选，
        // 也不应因快照校验而阻断其余 Git 文件的准备。
        let changes = try await status(in: binding).filter { change in
            !isVersionControlMetadataPath(change.path)
                && !(change.originalPath.map(isVersionControlMetadataPath) ?? false)
        }
        var files: [RepositoryCommitFile] = []
        for change in changes {
            let restriction: String?
            if change.kind == .conflicted {
                restriction = "存在未解决冲突"
            } else if change.kind == .typeChanged {
                restriction = "文件类型变化需在 Git 中确认"
            } else if try await containsSelectedSubmodule(paths: [change.path], in: binding.root) {
                restriction = "Git 子模块引用需在 Git 中确认"
            } else {
                restriction = nil
            }
            files.append(RepositoryCommitFile(change: change, fingerprint: try await commitFingerprint(for: change, in: binding.root), restriction: restriction))
        }
        let blockingReason: String?
        if try await hasInProgressOperation(in: binding.root) {
            blockingReason = "Git 工作区正处于合并或变基过程中；请先在 Git 中完成或中止该操作。"
        } else if files.contains(where: { $0.change.kind == .conflicted }) {
            blockingReason = "存在未解决的 Git 冲突；请先处理冲突后再提交。"
        } else if try await commitUsesUnsafeFilter(in: binding.root) {
            blockingReason = "该 Git 工作区配置了文件过滤器；RepHub 不会执行可能启动外部程序的过滤器。"
        } else {
            blockingReason = nil
        }
        return RepositoryCommitPreparation(
            binding: binding,
            baseRevision: baseRevision,
            files: files,
            notice: "Git 会以所选文件当前的工作区版本创建本地提交；未选文件的暂存内容会被保留，提交不会推送远端。",
            blockingReason: blockingReason
        )
    }

    public func commitDiff(in binding: RepositoryBinding, file: RepositoryCommitFile) async throws -> RepositoryPatch {
        try ensureGit(binding)
        try await verifyCommitFile(file, in: binding.root)
        let paths = try commitPaths(for: [file], root: binding.root)
        if file.change.kind == .untracked {
            return try await untrackedCommitDiff(path: file.change.path, root: binding.root)
        }
        if try await hasHead(binding.root) {
            let result = try await git(
                ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "HEAD", "--"] + paths,
                in: binding.root
            )
            return RepositoryPatch(text: try requireSuccess(result, tool: "git").output)
        }
        // 无初始提交时，临时索引尚不存在；以 /dev/null 对比当前文件就是将写入首个提交的新增内容。
        return try await untrackedCommitDiff(path: paths[0], root: binding.root)
    }

    public func commit(
        _ request: RepositoryCommitRequest,
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryCommitResult {
        try ensureGit(binding)
        guard request.bindingID == binding.id else {
            throw VersionControlError.invalidRepository("提交请求与当前 Git 工作区不一致。")
        }
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "未填写提交说明，未创建 Git 提交。")
        }
        guard !request.files.isEmpty else {
            return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "未选择要提交的文件。")
        }
        var context: PreparedGitCommit?
        var handoffPreparedResources = false
        do {
            guard !(try await hasInProgressOperation(in: binding.root)) else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "Git 正处于合并或变基中，未创建提交。")
            }
            guard !request.files.contains(where: { $0.change.kind == .conflicted }) else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "所选文件包含未解决冲突，未创建提交。")
            }
            guard !request.files.contains(where: { $0.change.kind == .typeChanged }) else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "所选文件包含类型变化，RepHub 不会自动提交该类型变更。")
            }
            guard !(try await commitUsesUnsafeFilter(in: binding.root)) else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "Git 文件过滤器可能执行外部程序，RepHub 未创建提交。")
            }
            let before = try await optionalHead(in: binding.root)
            guard before == request.baseRevision else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "当前 Git 提交已变化，请刷新后重新选择文件。")
            }
            let paths = try commitPaths(for: request.files, root: binding.root)
            guard !(try await containsSelectedSubmodule(paths: paths, in: binding.root)) else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "所选内容包含 Git 子模块，RepHub 不会自动更新子模块引用。")
            }
            for file in request.files { try await verifyCommitFile(file, in: binding.root) }
            try Task.checkCancellation()
            let index = try await gitIndexLocation(in: binding.root)
            let lock = try GitIndexLock(index: index)
            let originalIndex = try indexSnapshot(at: index)
            let temporaryDirectory = index.deletingLastPathComponent()
            let temporaryIndex = temporaryDirectory.appendingPathComponent("rephub-commit-index-\(UUID().uuidString)")
            let publishedIndex = temporaryDirectory.appendingPathComponent("rephub-publish-index-\(UUID().uuidString)")
            let prepared = PreparedGitCommit(before: before, paths: paths, index: index, lock: lock, originalIndex: originalIndex, temporaryIndex: temporaryIndex, publishedIndex: publishedIndex)
            context = prepared
            defer {
                if !handoffPreparedResources { cleanupPreparedCommit(prepared) }
            }
            await progress(RepositoryOperationProgress("正在准备所选 Git 文件…"))
            if let before {
                _ = try requireSuccess(try await git(["read-tree", before], in: binding.root, gitIndexFile: temporaryIndex), tool: "git")
            } else {
                _ = try requireSuccess(try await git(["read-tree", "--empty"], in: binding.root, gitIndexFile: temporaryIndex), tool: "git")
            }
            _ = try requireSuccess(try await git(["--literal-pathspecs", "add", "-A", "--"] + paths, in: binding.root, gitIndexFile: temporaryIndex), tool: "git")
            for file in request.files { try await verifyCommitFile(file, in: binding.root) }
            try Task.checkCancellation()
            handoffPreparedResources = true
        } catch {
            return preCommitFailure(bindingID: binding.id, error: error)
        }
        guard let context else {
            return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "Git 未开始创建提交。", details: "无法准备临时 Git 暂存区。")
        }
        defer {
            cleanupPreparedCommit(context)
        }

        await progress(RepositoryOperationProgress("正在创建本地 Git 提交…"))
        do {
            let result = try await git(["commit", "--no-verify", "--no-gpg-sign", "--no-status", "--cleanup=verbatim", "-m", message], in: binding.root, timeout: 90, gitIndexFile: context.temporaryIndex)
            return await completeCommitAttemptDetached(
                binding: binding, request: request, message: message, recovery: CommitRecoveryContext(context),
                commandDetail: result.exitCode == 0 ? nil : sanitizedGitFailure(result), cancelled: false, progress: progress
            )
        } catch {
            return await completeCommitAttemptDetached(
                binding: binding, request: request, message: message, recovery: CommitRecoveryContext(context),
                commandDetail: error.localizedDescription, cancelled: error is CancellationError, progress: progress
            )
        }
    }

    private func fetch(
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryOperationResult {
        await progress(RepositoryOperationProgress("正在检查当前分支的上游配置…"))
        let upstream = try await configuredUpstream(in: binding.root)
        try Task.checkCancellation()

        await progress(RepositoryOperationProgress("正在从 \(upstream.remote) 获取远端引用…"))
        try await fetch(remote: upstream.remote, in: binding.root, progress: progress)
        try Task.checkCancellation()

        return RepositoryOperationResult(
            kind: .fetch,
            bindingID: binding.id,
            outcome: .succeeded,
            summary: "已获取 \(upstream.remote) 的远端引用。",
            details: "当前分支：\(upstream.branch)；未修改工作区文件。"
        )
    }

    private func update(
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryOperationResult {
        await progress(RepositoryOperationProgress("正在检查当前分支及上游配置…"))
        let upstream = try await configuredUpstream(in: binding.root)
        guard try await hasHead(binding.root) else {
            return rejectedUpdate(binding, "当前分支尚无提交，无法执行快进更新。")
        }
        if try await hasInProgressOperation(in: binding.root) {
            return rejectedUpdate(binding, "工作区正处于合并或变基过程中；请先在 Git 中完成或中止该操作。")
        }
        if try await hasTrackedChanges(in: binding.root) {
            return rejectedUpdate(binding, "检测到已跟踪文件的本地修改；为保护修改，未更新工作区。")
        }
        try Task.checkCancellation()

        await progress(RepositoryOperationProgress("正在从 \(upstream.remote) 获取远端引用…"))
        try await fetch(remote: upstream.remote, in: binding.root, progress: progress)
        try Task.checkCancellation()

        // fetch 不应改动工作文件，但其他客户端可能并发修改，因此在真正写入前再次确认。
        await progress(RepositoryOperationProgress("正在比较本地与上游提交…"))
        guard !(try await hasInProgressOperation(in: binding.root)) else {
            return rejectedUpdate(binding, "工作区在获取期间进入合并或变基状态；未继续更新。")
        }
        guard !(try await hasTrackedChanges(in: binding.root)) else {
            return rejectedUpdate(binding, "获取期间出现已跟踪文件的本地修改；未继续更新。")
        }

        let current = try await currentHead(in: binding.root)
        let remote = try await resolvedUpstream(in: binding.root)
        if current == remote {
            return RepositoryOperationResult(
                kind: .update,
                bindingID: binding.id,
                outcome: .succeeded,
                summary: "当前分支已是最新。",
                details: "当前分支：\(upstream.branch)。"
            )
        }

        if try await isAncestor(remote, of: current, in: binding.root) {
            return RepositoryOperationResult(
                kind: .update,
                bindingID: binding.id,
                outcome: .succeeded,
                summary: "本地分支领先上游，无需更新。",
                details: "当前分支：\(upstream.branch)；不会覆盖或推送本地提交。"
            )
        }
        guard try await isAncestor(current, of: remote, in: binding.root) else {
            return rejectedUpdate(binding, "本地分支与上游已经分叉；为保护提交历史，未执行合并或变基。")
        }

        if try await containsSubmodule(inTree: remote, directory: binding.root) {
            return rejectedUpdate(binding, "该上游版本包含子模块；当前版本不会递归写入子工作区，未执行更新。")
        }
        if try await containsCheckoutFilter(inTree: remote, directory: binding.root) {
            return rejectedUpdate(binding, "该上游版本使用 Git 文件过滤器；当前版本为避免执行外部过滤器，未执行更新。")
        }

        let untrackedConflicts = try await localPathsConflictingWithIncomingTree(
            upstream: remote,
            in: binding.root
        )
        guard untrackedConflicts.isEmpty else {
            return rejectedUpdate(
                binding,
                "未跟踪文件可能被上游文件占用：\(untrackedConflicts.prefix(3).joined(separator: "、"))；未更新工作区。"
            )
        }

        let before = current
        // fetch 期间可能有其他 Git 客户端切分支或更新引用。真正写入前必须核对原目标仍有效。
        let beforeWriteUpstream = try await configuredUpstream(in: binding.root)
        guard beforeWriteUpstream.branch == upstream.branch, beforeWriteUpstream.remote == upstream.remote,
              beforeWriteUpstream.remoteURL == upstream.remoteURL,
              try await currentHead(in: binding.root) == before,
              try await resolvedUpstream(in: binding.root) == remote else {
            return rejectedUpdate(binding, "获取期间当前分支、提交或上游引用已经改变；请刷新后重新选择更新目标。")
        }

        await progress(RepositoryOperationProgress("正在以快进方式更新工作区…"))
        let merge = try await git(
            ["merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", "--no-edit", "--no-verify", "--no-stat", remote],
            in: binding.root,
            timeout: 90
        )
        if merge.exitCode != 0 {
            // 这里不尝试任何恢复命令。merge --ff-only 失败后读取状态，让上层展示事实。
            let state = try await status(in: binding)
            let hasConflicts = state.contains { $0.kind == .conflicted }
            return RepositoryOperationResult(
                kind: .update,
                bindingID: binding.id,
                outcome: hasConflicts ? .conflicts : .failed,
                summary: hasConflicts ? "快进更新产生冲突，请在 Git 中处理。" : "Git 未完成快进更新。",
                details: sanitizedGitFailure(merge),
                changedFiles: state
            )
        }
        try Task.checkCancellation()
        let after = try await currentHead(in: binding.root)
        let changed = try await changedFiles(from: before, to: after, in: binding.root)
        return RepositoryOperationResult(
            kind: .update,
            bindingID: binding.id,
            outcome: .succeeded,
            summary: "已快进更新 \(changed.count) 个文件。",
            details: "当前分支：\(upstream.branch)。",
            changedFiles: changed
        )
    }

    private func rejectedUpdate(_ binding: RepositoryBinding, _ detail: String) -> RepositoryOperationResult {
        RepositoryOperationResult(
            kind: .update,
            bindingID: binding.id,
            outcome: .failed,
            summary: "为保护本地工作区，未执行更新。",
            details: detail
        )
    }

    private struct ConfiguredUpstream {
        let branch: String
        let remote: String
        let remoteURL: String
    }

    /// 只允许当前分支在 branch.<name>.remote 中显式配置的真实远端。
    /// 不以 origin 作为静默兜底，避免错误地从另一个远端获取内容。
    private func configuredUpstream(in directory: URL) async throws -> ConfiguredUpstream {
        let branchResult = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        guard branchResult.exitCode == 0 else {
            if branchResult.exitCode == 1 {
                throw VersionControlError.unsupported("当前 Git 工作区处于游离 HEAD，不能确定用于更新的分支。")
            }
            _ = try requireSuccess(branchResult, tool: "git")
            throw VersionControlError.invalidData("Git 未返回当前分支。")
        }
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw VersionControlError.invalidData("Git 未返回当前分支。") }

        guard let remote = try await configuredRemoteName(for: branch, in: directory) else {
            throw VersionControlError.unsupported("当前分支未配置可获取的远端上游。")
        }
        let mergeResult = try await git(["config", "--get", "branch.\(branch).merge"], in: directory)
        guard mergeResult.exitCode == 0,
              mergeResult.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("refs/heads/") else {
            throw VersionControlError.unsupported("当前分支的上游引用配置不完整。")
        }
        guard let remoteURL = try await remoteURL(named: remote, in: directory) else {
            throw VersionControlError.unsupported("当前分支配置的远端 \(remote) 不可用。")
        }
        guard try await hasSafeRemoteTrackingRefspec(remote: remote, in: directory) else {
            throw VersionControlError.unsupported("当前远端的 fetch refspec 可能写入本地分支；仅支持写入该远端的远端跟踪引用。")
        }
        return ConfiguredUpstream(branch: branch, remote: remote, remoteURL: remoteURL)
    }

    private func configuredRemoteName(for branch: String, in directory: URL) async throws -> String? {
        let result = try await git(["config", "--get", "branch.\(branch).remote"], in: directory)
        if result.exitCode == 1 { return nil }
        let remote = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        return remote.isEmpty || remote == "." ? nil : remote
    }

    private func remoteURL(named remote: String, in directory: URL) async throws -> String? {
        let result = try await git(["remote", "get-url", "--", remote], in: directory)
        if result.exitCode == 2 || result.exitCode == 3 {
            return nil
        }
        if result.exitCode != 0 {
            _ = try requireSuccess(result, tool: "git")
            return nil
        }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        _ = try validatedCloneLocation(value) // get-url 已解析 insteadOf，仍必须审查最终协议。
        return value
    }

    private func pushURL(named remote: String, in directory: URL) async throws -> String? {
        let result = try await git(["remote", "get-url", "--push", "--all", "--", remote], in: directory)
        if result.exitCode == 2 || result.exitCode == 3 { return nil }
        let value = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.split(whereSeparator: \.isNewline).count == 1 else {
            throw VersionControlError.unsupported("该远端配置了多个推送地址，请先在 Git 中明确单一推送目标。")
        }
        _ = try validatedCloneLocation(value)
        return value
    }

    /// fetch 只允许写入 refs/remotes/<remote>/；拒绝可写 refs/heads 等本地引用的自定义 refspec。
    private func hasSafeRemoteTrackingRefspec(remote: String, in directory: URL) async throws -> Bool {
        let result = try await git(["config", "--get-all", "remote.\(remote).fetch"], in: directory)
        if result.exitCode == 1 { return false }
        let values = try requireSuccess(result, tool: "git").output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard values.contains(where: { !$0.hasPrefix("^") }) else { return false }
        let expectedPrefix = "refs/remotes/\(remote)/"
        return values.allSatisfy { refspec in
            if refspec.hasPrefix("^") { return true }
            guard let separator = refspec.firstIndex(of: ":") else { return false }
            let destination = refspec[refspec.index(after: separator)...]
            return destination.hasPrefix(expectedPrefix)
        }
    }

    private func fetch(
        remote: String,
        in directory: URL,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws {
        let transferProgress = GitTransferProgressReporter(progress)
        let result = try await git(
            ["fetch", "--progress", "--no-write-fetch-head", "--no-tags", "--no-recurse-submodules", "--", remote],
            in: directory,
            timeout: 90,
            restrictRemoteProtocols: true,
            onOutput: { lines in await transferProgress.accept(lines) }
        )
        _ = try requireSuccess(result, tool: "git")
    }

    private func currentHead(in directory: URL) async throws -> String {
        let result = try await git(["rev-parse", "--verify", "HEAD"], in: directory)
        let output = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw VersionControlError.invalidData("Git 未返回当前提交。") }
        return output
    }

    private func resolvedUpstream(in directory: URL) async throws -> String {
        let result = try await git(["rev-parse", "--verify", "@{upstream}"], in: directory)
        let output = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw VersionControlError.invalidData("Git 未返回上游提交。") }
        return output
    }

    private func isAncestor(_ ancestor: String, of descendant: String, in directory: URL) async throws -> Bool {
        let result = try await git(["merge-base", "--is-ancestor", ancestor, descendant], in: directory)
        if result.exitCode == 0 { return true }
        if result.exitCode == 1 { return false }
        _ = try requireSuccess(result, tool: "git")
        return false
    }

    private func hasTrackedChanges(in directory: URL) async throws -> Bool {
        let result = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=no"], in: directory)
        return !(try requireSuccess(result, tool: "git").data.isEmpty)
    }

    private func hasInProgressOperation(in directory: URL) async throws -> Bool {
        let mergeHead = try await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: directory)
        if mergeHead.exitCode == 0 { return true }
        if mergeHead.exitCode != 1 { _ = try requireSuccess(mergeHead, tool: "git") }
        let rebaseApply = try await git(["rev-parse", "--git-path", "rebase-apply"], in: directory)
        let rebaseMerge = try await git(["rev-parse", "--git-path", "rebase-merge"], in: directory)
        let paths = [rebaseApply, rebaseMerge].compactMap { result -> String? in
            guard result.exitCode == 0 else { return nil }
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        return paths.contains { path in
            let location = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: location.standardizedFileURL.path)
        }
    }

    /// Git 默认可覆盖 ignored 文件；这里在写入前把未跟踪和忽略路径一并与目标树核对。
    /// .svn 元数据作为普通未跟踪路径参与比较，但不会与合法 Git 路径冲突。
    private func localPathsConflictingWithIncomingTree(upstream: String, in directory: URL) async throws -> [String] {
        let statusResult = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"], in: directory)
        let fields = try requireSuccess(statusResult, tool: "git").data
            .split(separator: 0, omittingEmptySubsequences: true)
        let local = fields.compactMap { field -> String? in
            guard field.count >= 4 else { return nil }
            let state = String(decoding: field.prefix(2), as: UTF8.self)
            guard state == "??" || state == "!!" else { return nil }
            return String(decoding: field.dropFirst(3), as: UTF8.self)
        }
        guard !local.isEmpty else { return [] }
        let tree = try await git(["ls-tree", "-r", "-z", "--name-only", upstream], in: directory)
        let remote = try requireSuccess(tree, tool: "git").data
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        return local.filter { path in
            remote.contains { candidate in
                candidate == path || candidate.hasPrefix(path + "/") || path.hasPrefix(candidate + "/")
            }
        }
    }

    /// 对于更新目标中的 .gitattributes，只要声明了 filter= 即拒绝更新。
    /// 这样不会为了“兼容”而执行仓库配置的外部过滤器，也不会留下 LFS 指针等不完整内容。
    private func containsCheckoutFilter(inTree revision: String, directory: URL) async throws -> Bool {
        if try await hasConfiguredFilterDriver(in: directory) { return true }
        if try await hasFilterAttributeInLocalSources(in: directory) { return true }
        let listing = try await git(["ls-tree", "-r", "-z", revision], in: directory)
        let records = try requireSuccess(listing, tool: "git").data.split(separator: 0, omittingEmptySubsequences: true)
        for record in records {
            let pieces = record.split(separator: 9, maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  String(decoding: pieces[1], as: UTF8.self).hasSuffix(".gitattributes") else { continue }
            let metadata = String(decoding: pieces[0], as: UTF8.self).split(separator: " ")
            guard metadata.count >= 3 else { throw VersionControlError.invalidData("Git 树对象格式错误。") }
            let attributeFile = try await git(["cat-file", "blob", String(metadata[2])], in: directory)
            let text = try requireSuccess(attributeFile, tool: "git").output
            if hasFilterAttribute(in: text) {
                return true
            }
        }
        return false
    }

    /// 配置了 filter 驱动即保守拒绝；此版本不判断其是否刚好命中某个新文件，避免误执行外部程序。
    private func hasConfiguredFilterDriver(in directory: URL) async throws -> Bool {
        let result = try await git(["config", "--get-regexp", "^filter\\..*\\.(clean|smudge|process|required)$"], in: directory)
        if result.exitCode == 1 { return false }
        return !(try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// .git/info/attributes 与 core.attributesFile 可在上游 .gitattributes 之外引入过滤器。
    private func hasFilterAttributeInLocalSources(in directory: URL) async throws -> Bool {
        let gitPath = try await git(["rev-parse", "--git-path", "info/attributes"], in: directory)
        let localPath = try requireSuccess(gitPath, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasFilterAttribute(at: resolvedPath(localPath, relativeTo: directory)) { return true }

        let configured = try await git(["config", "--get", "core.attributesFile"], in: directory)
        if configured.exitCode == 1 { return false }
        let configuredPath = try requireSuccess(configured, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasFilterAttribute(at: resolvedPath(configuredPath, relativeTo: directory))
    }

    private func resolvedPath(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return directory.appendingPathComponent(expanded)
    }

    private func hasFilterAttribute(at url: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.standardizedFileURL.path) else { return false }
        return hasFilterAttribute(in: String(decoding: data, as: UTF8.self))
    }

    private func hasFilterAttribute(in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && (trimmed.contains("filter=") || trimmed.split(whereSeparator: \.isWhitespace).contains("filter"))
        }
    }

    private func containsSubmodule(inTree revision: String, directory: URL) async throws -> Bool {
        let result = try await git(["ls-tree", "-r", "-z", revision], in: directory)
        return try requireSuccess(result, tool: "git").data
            .split(separator: 0, omittingEmptySubsequences: true)
            .contains { $0.starts(with: Data("160000 ".utf8)) }
    }

    private func changedFiles(from before: String, to after: String, in directory: URL) async throws -> [FileChange] {
        guard before != after else { return [] }
        let result = try await git(["diff", "--name-status", "-z", "-M", "-C", before, after, "--"], in: directory)
        return try parseNameStatus(try requireSuccess(result, tool: "git").data)
    }

    private func sanitizedGitFailure(_ result: CommandResult) -> String {
        let text = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Git（退出码 \(result.exitCode)）未提供错误详情。" : String(text.prefix(2400))
    }

    private func unknownSynchronization(_ detail: String) -> RepositorySyncStatus {
        RepositorySyncStatus(
            states: [:],
            summary: "同步状态未知",
            detail: detail + " 同步判断仅读取本机远端引用；可先获取远端后重试。"
        )
    }

    /// 以有限的三个批量查询标记当前列表中的提交，避免为每条历史启动一个 Git 进程。
    /// 计数本身由 `rev-list --count` 完整计算；行状态只保证最近 5,000 个拓扑记录，超出窗口则明确标为需核对。
    private func synchronizationStates(
        for revisionIDs: [String],
        head: String,
        upstream: String,
        in directory: URL
    ) async throws -> [String: RevisionSyncState] {
        let wanted = Set(revisionIDs.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [:] }
        let limit = 5_000
        let probeLimit = limit + 1
        async let divergentResult = git(
            ["rev-list", "--left-right", "--max-count=\(probeLimit)", "\(head)...\(upstream)"],
            in: directory
        )
        async let headResult = git(["rev-list", "--max-count=\(probeLimit)", head], in: directory)
        async let upstreamResult = git(["rev-list", "--max-count=\(probeLimit)", upstream], in: directory)
        let (divergent, head, upstreamHistory) = try await (divergentResult, headResult, upstreamResult)
        let divergentOutput = try requireSuccess(divergent, tool: "git").output
        let headOutput = try requireSuccess(head, tool: "git").output
        let upstreamOutput = try requireSuccess(upstreamHistory, tool: "git").output

        let divergentLines = divergentOutput.split(whereSeparator: \.isNewline)
        let headLines = headOutput.split(whereSeparator: \.isNewline)
        let upstreamLines = upstreamOutput.split(whereSeparator: \.isNewline)
        let isTruncated = divergentLines.count > limit || headLines.count > limit || upstreamLines.count > limit

        var states: [String: RevisionSyncState] = [:]
        for line in divergentLines.prefix(limit) {
            guard let marker = line.first else { continue }
            let id = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard wanted.contains(id) else { continue }
            switch marker {
            case "<": states[id] = .outgoing
            case ">": states[id] = .incoming
            default: break
            }
        }
        let common = Set(headLines.prefix(limit).map(String.init))
            .intersection(Set(upstreamLines.prefix(limit).map(String.init)))
        for id in wanted where states[id] == nil {
            if common.contains(id) {
                states[id] = .synchronized
            } else if isTruncated {
                states[id] = .uncertain
            }
        }
        return states
    }

    private func validatedCloneLocation(_ value: String) throws -> String {
        let location = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty, location == value else {
            throw VersionControlError.invalidRepository("请填写完整的 Git 远端地址。")
        }
        guard !location.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VersionControlError.invalidRepository("Git 远端地址不能包含控制字符。")
        }
        guard !location.hasPrefix("-") else {
            throw VersionControlError.invalidRepository("Git 远端地址格式无效。")
        }
        // `ext::` 及其他 helper 形式可让 Git 调起外部程序；本客户端不接受这类远端。
        guard !location.contains("::") else {
            throw VersionControlError.unsupported("不支持 Git remote helper 地址。")
        }

        if location.hasPrefix("/") {
            return location
        }

        if let components = URLComponents(string: location), let scheme = components.scheme?.lowercased() {
            guard ["https", "http", "ssh", "file"].contains(scheme) else {
                throw VersionControlError.unsupported("仅支持 HTTPS、HTTP、SSH 与本地 file Git 地址。")
            }
            if scheme == "file" {
                guard components.host == nil || components.host?.isEmpty == true,
                      components.path.hasPrefix("/") else {
                    throw VersionControlError.invalidRepository("本地 Git 地址必须是 file:///绝对路径。")
                }
            } else {
                guard components.host?.isEmpty == false else {
                    throw VersionControlError.invalidRepository("Git 远端地址缺少服务器地址。")
                }
            }
            guard components.password == nil else {
                throw VersionControlError.invalidRepository("Git 远端地址不能包含密码。")
            }
            guard components.query == nil, components.fragment == nil else {
                throw VersionControlError.invalidRepository("Git 远端地址不能包含查询参数或片段。")
            }
            return location
        }

        // Git 的 SCP 写法，例如 git@example.com:group/project.git。
        let scpPattern = "^[^@/:\\s]+@[^@/:\\s]+:[^\\s]+$"
        if location.range(of: scpPattern, options: .regularExpression) != nil {
            return location
        }
        throw VersionControlError.invalidRepository("Git 远端地址格式无效。")
    }

    private func validateCloneDestination(_ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw VersionControlError.executionFailed("克隆位置的父文件夹不存在：\(parent.path)")
        }
        // attributesOfItem 可识别断开的符号链接；不能因 fileExists 返回 false 而误覆盖它。
        if (try? fileManager.attributesOfItem(atPath: destination.path)) != nil {
            throw VersionControlError.executionFailed("目标文件夹已存在，不能覆盖：\(destination.path)")
        }
    }

    private func validatedHistoryPageLimit(_ limit: Int) throws -> Int {
        guard limit > 0 else { throw VersionControlError.invalidData("历史每页条数必须大于 0。") }
        guard limit <= 500 else { throw VersionControlError.unsupported("历史每页最多读取 500 条。") }
        return limit
    }

    private func managementToken(in directory: URL) async throws -> String {
        let head = try await optionalHead(in: directory) ?? ""
        let branch = (try? await currentBranch(in: directory)) ?? ""
        let identity = (try await localGitConfig("user.name", in: directory) ?? "") + "\u{0}" + (try await localGitConfig("user.email", in: directory) ?? "")
        let remotes = try requireSuccess(try await git(["remote", "-v"], in: directory), tool: "git").data
        let status = try requireSuccess(try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: directory), tool: "git").data
        let diff: Data
        if let head = try await optionalHead(in: directory) {
            diff = try requireSuccess(try await git(["diff", "--binary", "--no-ext-diff", "--no-textconv", head, "--"], in: directory), tool: "git").data
        } else {
            diff = try requireSuccess(try await git(["diff", "--binary", "--no-ext-diff", "--no-textconv", "--"], in: directory), tool: "git").data
        }
        let cached = try requireSuccess(try await git(["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--"], in: directory), tool: "git").data
        let mergeHead = try await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: directory)
        var data = Data((head + "\u{0}" + branch + "\u{0}" + identity + "\u{0}").utf8); data.append(remotes); data.append(status); data.append(diff); data.append(cached)
        if mergeHead.exitCode == 0 { data.append(mergeHead.data) }
        // 未跟踪文件不在普通 diff 中，仍需把内容纳入 token，避免用户在确认前二次编辑却保持同一 porcelain 状态。
        for record in status.split(separator: 0, omittingEmptySubsequences: true) where record.starts(with: Data("?? ".utf8)) {
            let path = String(decoding: record.dropFirst(3), as: UTF8.self)
            let fingerprint = try CommitFileSnapshot.fingerprint(root: directory, path: path)
            data.append(Data((path + "\u{0}" + fingerprint).utf8))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func currentBranch(in directory: URL) async throws -> String {
        let result = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        guard result.exitCode == 0 else { throw VersionControlError.unsupported("当前处于游离 HEAD，不能执行此操作。") }
        let branch = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw VersionControlError.invalidData("Git 未返回当前分支。") }; return branch
    }

    private func localGitConfig(_ key: String, in directory: URL) async throws -> String? {
        let result = try await git(["config", "--local", "--get", key], in: directory)
        if result.exitCode == 1 { return nil }
        let value = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func managedPaths(_ paths: [String], root: URL) throws -> [String] {
        let unique = Array(Set(paths)).sorted(); guard !unique.isEmpty else { throw VersionControlError.invalidData("未选择文件。") }
        for path in unique { _ = try CommitFileSnapshot.validatedURL(root: root, path: path) }
        return unique
    }

    private func requireCurrentChangePaths(_ paths: [String], binding: RepositoryBinding) async throws {
        let changes = try await status(in: binding)
        let allowed = Set(changes.flatMap { [$0.path, $0.originalPath].compactMap { $0 } })
        guard Set(paths).isSubset(of: allowed) else { throw VersionControlError.invalidData("只能对当前变更列表中的明确文件操作。") }
        for path in paths {
            let url = try CommitFileSnapshot.validatedURL(root: binding.root, path: path)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { throw VersionControlError.invalidData("不能按目录递归暂存或取消暂存。") }
        }
    }

    private func ensureSafeIndexOperation(_ paths: [String], root: URL) async throws {
        guard !(try await commitUsesUnsafeFilter(in: root)) else { throw VersionControlError.unsupported("Git 文件过滤器可能执行外部程序，未修改暂存区。") }
        guard !(try await containsSelectedSubmodule(paths: paths, in: root)) else { throw VersionControlError.unsupported("所选内容包含子模块，未修改暂存区。") }
    }

    private func ensureSafeBranchOperation(in root: URL) async throws {
        guard !(try await hasTrackedChanges(in: root)) else { throw VersionControlError.unsupported("存在已跟踪的本地修改，未切换或合并分支。") }
        guard !(try await hasInProgressOperation(in: root)) else { throw VersionControlError.unsupported("Git 正在合并或变基，无法执行分支操作。") }
        guard !(try await commitUsesUnsafeFilter(in: root)) else { throw VersionControlError.unsupported("Git 文件过滤器可能执行外部程序，未执行分支操作。") }
        guard let head = try await optionalHead(in: root), !(try await containsSubmodule(inTree: head, directory: root)) else { throw VersionControlError.unsupported("当前版本包含子模块，未执行分支操作。") }
    }

    private func ensureSafeTargetTree(_ reference: String, in root: URL) async throws {
        guard let target = try await resolvedCommit(reference, in: root) else { throw VersionControlError.invalidData("目标分支或提交不存在。") }
        guard !(try await containsSubmodule(inTree: target, directory: root)), !(try await containsCheckoutFilter(inTree: target, directory: root)) else { throw VersionControlError.unsupported("目标版本包含子模块或文件过滤器，未执行操作。") }
        let conflicts = try await localPathsConflictingWithIncomingTree(upstream: target, in: root)
        guard conflicts.isEmpty else { throw VersionControlError.unsupported("未跟踪或忽略文件会被目标版本覆盖：\(conflicts.prefix(3).joined(separator: "、"))") }
    }

    private func requireValidReferenceName(_ value: String, in directory: URL) async throws {
        guard !value.isEmpty, !value.hasPrefix("-"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw VersionControlError.invalidData("分支或远端名称无效。")
        }
        let checked = try await git(["check-ref-format", "refs/heads/\(value)"], in: directory)
        guard checked.exitCode == 0 else { throw VersionControlError.invalidData("分支或远端名称无效：\(value)") }
    }

    private func verifyResolvedTextFile(_ path: String, root: URL) throws {
        let url = try CommitFileSnapshot.validatedURL(root: root, path: path)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max <= 8 * 1024 * 1024,
              let data = fileManager.contents(atPath: url.path), !data.contains(0) else { throw VersionControlError.unsupported("只能标记已编辑的文本冲突文件。") }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains("<<<<<<<") && !text.contains("=======") && !text.contains(">>>>>>>") else { throw VersionControlError.invalidData("文件仍包含冲突标记：\(path)") }
    }

    private func normalizedHistoryReference(_ reference: String?) -> String? {
        let value = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// 读取当前可达端点后立即将其解析为提交对象，而不是在后续页继续使用会移动的分支名。
    private func fixedHistoryTips(in directory: URL, reference: String?) async throws -> [String] {
        if let reference = normalizedHistoryReference(reference) {
            guard let tip = try await resolvedCommit(reference, in: directory) else {
                if try await isEmptyRepository(directory) { return [] }
                throw VersionControlError.invalidRepository("Git 引用不存在或不指向提交：\(reference)")
            }
            return [tip]
        }

        // 一次读取所有 ref 的对象类型和 Git 已经完成的一层 peeled 值。常规分支、轻量 tag
        // 与普通附注 tag 都不需要逐个启动 rev-parse；嵌套 tag 才回退到单独剥离。
        let refs = try await git(
            [
                "for-each-ref", "--format=%(refname)%00%(objecttype)%00%(objectname)%00%(*objecttype)%00%(*objectname)",
                "refs/heads", "refs/remotes", "refs/tags"
            ],
            in: directory
        )
        let records = try requireSuccess(refs, tool: "git").data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
        var tips: [String] = []
        var nestedTags: [String] = []
        for record in records {
            let fields = record.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 5 else { throw VersionControlError.invalidData("Git 引用输出字段不完整。") }
            let name = fields[0]
            let objectType = fields[1]
            let objectID = fields[2]
            let peeledType = fields[3]
            let peeledID = fields[4]
            if objectType == "commit", isGitObjectID(objectID) {
                appendHistoryTip(objectID, to: &tips)
            } else if peeledType == "commit", isGitObjectID(peeledID) {
                appendHistoryTip(peeledID, to: &tips)
            } else if objectType == "tag" {
                // `*` 对嵌套 tag 仍可能是 tag；只对这种少见情况再解析到 commit。
                nestedTags.append(name)
            }
        }
        for name in nestedTags {
            if let tip = try await resolvedCommit(name, in: directory) { appendHistoryTip(tip, to: &tips) }
        }
        // 游离 HEAD 不一定被任何引用指向，且单独解析一次即可。
        if let head = try await resolvedCommit("HEAD", in: directory) { appendHistoryTip(head, to: &tips) }
        return tips
    }

    private func appendHistoryTip(_ tip: String, to tips: inout [String]) {
        if !tips.contains(tip) { tips.append(tip) }
    }

    /// `^{commit}` 会剥离附注 tag，同时排除指向 blob/tree 的异常引用。
    private func resolvedCommit(_ reference: String, in directory: URL) async throws -> String? {
        let result = try await git(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(reference)^{commit}"], in: directory)
        if result.exitCode == 1 || result.exitCode == 128 { return nil }
        let output = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        return output
    }

    private func encodeHistoryCursor(_ cursor: GitHistoryCursor) throws -> String {
        let data = try JSONEncoder().encode(cursor)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeHistoryCursor(_ value: String) throws -> GitHistoryCursor {
        guard value.count <= 262_144 else { throw VersionControlError.invalidData("Git 历史游标过长。") }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64),
              let cursor = try? JSONDecoder().decode(GitHistoryCursor.self, from: data) else {
            throw VersionControlError.invalidData("Git 历史游标无效或已损坏，请刷新后重试。")
        }
        guard cursor.version == 1, cursor.offset >= 0, !cursor.bindingID.isEmpty,
              !cursor.tips.contains(where: { !isGitObjectID($0) }) else {
            throw VersionControlError.invalidData("Git 历史游标格式无效，请刷新后重试。")
        }
        return cursor
    }

    private func isGitObjectID(_ value: String) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private func validate(
        cursor: GitHistoryCursor,
        kind: GitHistoryCursor.Kind,
        binding: RepositoryBinding,
        reference: String?,
        path: String?
    ) throws {
        guard cursor.kind == kind,
              cursor.bindingID == binding.id,
              cursor.reference == normalizedHistoryReference(reference),
              cursor.path == path else {
            throw VersionControlError.invalidData("Git 历史游标不属于当前仓库或查询范围，请刷新后重试。")
        }
        if kind == .file, cursor.trackedPath?.isEmpty != false {
            throw VersionControlError.invalidData("Git 文件历史游标缺少追溯路径，请刷新后重试。")
        }
    }

    private func git(
        _ command: [String],
        in directory: URL,
        timeout: TimeInterval = 20,
        restrictRemoteProtocols: Bool = false,
        gitIndexFile: URL? = nil,
        onOutput: CommandOutputHandler? = nil
    ) async throws -> CommandResult {
        let safeguards = ["--no-optional-locks", "-c", "core.pager=cat", "-c", "pager.branch=false", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false", "-c", "fetch.recurseSubmodules=false"]
        let protocolRestrictions = ["-c", "protocol.allow=never", "-c", "protocol.file.allow=always", "-c", "protocol.http.allow=always", "-c", "protocol.https.allow=always", "-c", "protocol.ssh.allow=always"]
        return try await runner.run(
            executable: "git",
            // hooks 可由仓库配置执行任意脚本；本客户端的更新不执行它们。
            // 禁止递归 submodule，避免一次操作继续写入子工作区。
            arguments: safeguards + (restrictRemoteProtocols ? protocolRestrictions : [])
                + command,
            directory: directory,
            timeout: timeout,
            gitIndexFile: gitIndexFile,
            onOutput: onOutput
        )
    }

    private func optionalHead(in directory: URL) async throws -> String? {
        let result = try await git(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory)
        if result.exitCode == 1 { return nil }
        let value = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func commitUsesUnsafeFilter(in directory: URL) async throws -> Bool {
        if try await hasConfiguredFilterDriver(in: directory) { return true }
        return try await hasFilterAttributeInLocalSources(in: directory)
    }

    private func isVersionControlMetadataPath(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { [".git", ".svn"].contains($0.lowercased()) }
    }

    /// 路径既会交给 Git，也会用于工作区快照，因此先由共享的快照模块拒绝元数据、越界和父级符号链接。
    private func commitPaths(for files: [RepositoryCommitFile], root: URL) throws -> [String] {
        var paths: [String] = []
        for file in files {
            for path in [file.change.originalPath, file.change.path].compactMap({ $0 }) where !paths.contains(path) {
                _ = try CommitFileSnapshot.validatedURL(root: root, path: path)
                paths.append(path)
            }
        }
        guard !paths.isEmpty else { throw VersionControlError.invalidRepository("未提供有效的提交路径。") }
        return paths
    }

    private func commitFingerprint(for change: FileChange, in directory: URL) async throws -> String {
        _ = try CommitFileSnapshot.validatedURL(root: directory, path: change.path)
        if let original = change.originalPath { _ = try CommitFileSnapshot.validatedURL(root: directory, path: original) }
        let status = try await statusRecord(for: change, in: directory)
        let current = try CommitFileSnapshot.fingerprint(root: directory, path: change.path)
        let original = try change.originalPath.map { try CommitFileSnapshot.fingerprint(root: directory, path: $0) } ?? ""
        return current + ":" + original + ":" + status.base64EncodedString()
    }

    private func verifyCommitFile(_ file: RepositoryCommitFile, in directory: URL) async throws {
        let current = try await commitFingerprint(for: file.change, in: directory)
        guard current == file.fingerprint else {
            throw VersionControlError.invalidRepository("文件 \(file.change.path) 或其暂存状态已经变化，请刷新后重新选择提交内容。")
        }
    }

    private func statusRecord(for change: FileChange, in directory: URL) async throws -> Data {
        let paths = [change.originalPath, change.path].compactMap { $0 }
        let result = try await git(
            ["--literal-pathspecs", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--"] + paths,
            in: directory
        )
        return try requireSuccess(result, tool: "git").data
    }

    private func gitIndexLocation(in directory: URL) async throws -> URL {
        let result = try await git(["rev-parse", "--git-path", "index"], in: directory)
        let path = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw VersionControlError.invalidData("Git 未返回索引路径。") }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
    }

    private func indexSnapshot(at index: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: index.path) else { return nil }
        return try Data(contentsOf: index)
    }

    private func publishSelectedPathsFromNewHead(
        originalIndex: Data?,
        originalIndexURL: URL,
        publishIndexURL: URL,
        paths: [String],
        in directory: URL
    ) async throws {
        if let originalIndex {
            try originalIndex.write(to: publishIndexURL, options: .atomic)
        } else {
            // `git reset` needs a readable index file when the pre-commit repository had none.
            _ = try requireSuccess(try await git(["read-tree", "--empty"], in: directory, gitIndexFile: publishIndexURL), tool: "git")
        }
        _ = try requireSuccess(try await git(
            ["--literal-pathspecs", "reset", "--mixed", "--quiet", "HEAD", "--"] + paths,
            in: directory,
            gitIndexFile: publishIndexURL
        ), tool: "git")
        _ = originalIndexURL // documents that publishIndex is derived from the captured real index, never from a later read.
    }

    private func replaceIndexAtomically(from source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw VersionControlError.executionFailed("无法发布已更新的 Git 暂存区：\(String(cString: strerror(errno)))")
        }
    }

    /// 命令在取消或异常后只有同时匹配父提交、树和消息时，才认定 HEAD 的变化来自本次提交。
    private func confirmsStartedCommit(
        after: String?,
        before: String?,
        message: String,
        temporaryIndex: URL,
        in directory: URL
    ) async throws -> Bool {
        guard let after, after != before else { return false }
        let parents = try requireSuccess(try await git(["rev-list", "--parents", "-n", "1", after], in: directory), tool: "git").output
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard parents.first == after,
              (before == nil ? parents.count == 1 : parents.count == 2 && parents[1] == before) else { return false }
        let actualTree = try requireSuccess(try await git(["rev-parse", "\(after)^{tree}"], in: directory), tool: "git").output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let intendedTree = try requireSuccess(try await git(["write-tree"], in: directory, gitIndexFile: temporaryIndex), tool: "git").output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard actualTree == intendedTree else { return false }
        let actualMessage = try requireSuccess(try await git(["log", "-1", "--format=%B", after], in: directory), tool: "git").output
            .trimmingCharacters(in: .newlines)
        return actualMessage == message
    }

    private func completeCommitAttemptDetached(
        binding: RepositoryBinding,
        request: RepositoryCommitRequest,
        message: String,
        recovery: CommitRecoveryContext,
        commandDetail: String?,
        cancelled: Bool,
        progress: @escaping RepositoryOperationProgressHandler
    ) async -> RepositoryCommitResult {
        await Task.detached { [self] in
            await self.completeCommitAttempt(
                binding: binding, request: request, message: message, recovery: recovery,
                commandDetail: commandDetail, cancelled: cancelled, progress: progress
            )
        }.value
    }

    private func completeCommitAttempt(
        binding: RepositoryBinding,
        request: RepositoryCommitRequest,
        message: String,
        recovery: CommitRecoveryContext,
        commandDetail: String?,
        cancelled: Bool,
        progress: @escaping RepositoryOperationProgressHandler
    ) async -> RepositoryCommitResult {
        do {
            let after = try await optionalHead(in: binding.root)
            guard try await confirmsStartedCommit(after: after, before: recovery.before, message: message, temporaryIndex: recovery.temporaryIndex, in: binding.root), let revisionID = after else {
                if after != recovery.before {
                    return RepositoryCommitResult(bindingID: binding.id, outcome: .unknown, revisionID: after, summary: "Git 提交结果无法确认。", details: "HEAD 已变化但不匹配本次提交；请刷新历史后核对。")
                }
                if cancelled { return RepositoryCommitResult(bindingID: binding.id, outcome: .cancelled, summary: "已取消 Git 提交。") }
                return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "Git 未创建提交。", details: commandDetail ?? "Git 未提供错误详情。")
            }
            // 已确认本次提交，即使命令返回异常也必须完成原 index 的受控收尾，避免已提交文件在真实索引中留下反向暂存差异。
            guard try indexSnapshot(at: recovery.index) == recovery.originalIndex else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .unknown, revisionID: revisionID, summary: "已创建 Git 提交，但暂存区在提交期间发生变化。", details: "RepHub 未覆盖当前暂存区；请刷新后核对。")
            }
            try await publishSelectedPathsFromNewHead(
                originalIndex: recovery.originalIndex,
                originalIndexURL: recovery.index,
                publishIndexURL: recovery.publishedIndex,
                paths: recovery.paths,
                in: binding.root
            )
            guard try indexSnapshot(at: recovery.index) == recovery.originalIndex else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .unknown, revisionID: revisionID, summary: "已创建 Git 提交，但暂存区在提交期间发生变化。", details: "RepHub 未覆盖当前暂存区；请刷新后核对。")
            }
            try replaceIndexAtomically(from: recovery.publishedIndex, to: recovery.index)
            await progress(RepositoryOperationProgress("Git 本地提交已创建。"))
            return RepositoryCommitResult(
                bindingID: binding.id,
                outcome: .succeeded,
                revisionID: revisionID,
                summary: "已创建 Git 本地提交。",
                details: "未推送远端；未选文件的暂存内容已保留。",
                committedFiles: request.files.map(\.change)
            )
        } catch {
            let revision = try? await optionalHead(in: binding.root)
            return RepositoryCommitResult(bindingID: binding.id, outcome: .unknown, revisionID: revision ?? nil, summary: "Git 提交可能已创建，但暂存区收尾未完成。", details: "RepHub 未重试；请刷新历史与暂存区后核对。")
        }
    }

    private func preCommitFailure(bindingID: String, error: Error) -> RepositoryCommitResult {
        if error is CancellationError {
            return RepositoryCommitResult(bindingID: bindingID, outcome: .cancelled, summary: "已取消 Git 提交。")
        }
        return RepositoryCommitResult(bindingID: bindingID, outcome: .failed, summary: "Git 未开始创建提交。", details: error.localizedDescription)
    }

    private func cleanupPreparedCommit(_ context: PreparedGitCommit) {
        context.lock.release()
        try? fileManager.removeItem(at: context.temporaryIndex)
        try? fileManager.removeItem(at: context.publishedIndex)
    }

    private func containsSelectedSubmodule(paths: [String], in directory: URL) async throws -> Bool {
        let result = try await git(["--literal-pathspecs", "ls-files", "--stage", "-z", "--"] + paths, in: directory)
        return try requireSuccess(result, tool: "git").data
            .split(separator: 0, omittingEmptySubsequences: true)
            .contains { $0.starts(with: Data("160000 ".utf8)) }
    }

    private func untrackedCommitDiff(path: String, root: URL) async throws -> RepositoryPatch {
        let url = try CommitFileSnapshot.validatedURL(root: root, path: path)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            return RepositoryPatch(text: "新增符号链接：\(path) → \(target)\n")
        }
        let result = try await git(["--literal-pathspecs", "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", path], in: root)
        guard result.exitCode == 0 || result.exitCode == 1 else { _ = try requireSuccess(result, tool: "git"); fatalError() }
        return RepositoryPatch(text: result.output)
    }

    private func ensureGit(_ binding: RepositoryBinding) throws {
        guard binding.providerID == .git else { throw VersionControlError.invalidRepository("该绑定不是 Git 工作区。") }
    }

    private func findGitMetadata(above directory: URL) throws -> URL? {
        var candidate = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        while true {
            try Task.checkCancellation()
            let metadata = candidate.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: metadata.path) { return candidate }
            guard candidate.path != "/", !candidate.path.isEmpty else { return nil }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path.count < candidate.path.count else { return nil }
            candidate = parent
        }
    }

    private func hasHead(_ directory: URL) async throws -> Bool {
        let result = try await git(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory)
        return result.exitCode == 0
    }

    private func isEmptyRepository(_ directory: URL) async throws -> Bool { !(try await hasHead(directory)) }
}

/// 占有真实 index 的标准 lock 文件。提交过程只操作临时 index；此锁仅用于阻止其他遵守 Git
/// 锁协议的进程在原 index 上并发写入，并在发布前发现绕过锁的外部修改。
private struct PreparedGitCommit {
    let before: String?
    let paths: [String]
    let index: URL
    let lock: GitIndexLock
    let originalIndex: Data?
    let temporaryIndex: URL
    let publishedIndex: URL
}

private struct CommitRecoveryContext: Sendable {
    let before: String?
    let paths: [String]
    let index: URL
    let originalIndex: Data?
    let temporaryIndex: URL
    let publishedIndex: URL

    init(_ prepared: PreparedGitCommit) {
        before = prepared.before
        paths = prepared.paths
        index = prepared.index
        originalIndex = prepared.originalIndex
        temporaryIndex = prepared.temporaryIndex
        publishedIndex = prepared.publishedIndex
    }
}

private final class GitIndexLock {
    private let url: URL
    private var held = false

    init(index: URL) throws {
        url = URL(fileURLWithPath: index.path + ".lock")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw VersionControlError.executionFailed("Git 暂存区正被其他操作使用，请稍后重试。")
            }
            throw VersionControlError.executionFailed("无法锁定 Git 暂存区：\(String(cString: strerror(errno)))")
        }
        close(descriptor)
        held = true
    }

    func release() {
        guard held else { return }
        try? FileManager.default.removeItem(at: url)
        held = false
    }

    deinit { release() }
}

/// Git 传输并不逐个下载工作区文件：clone/fetch 先接收 pack 对象，再在本地检出。
/// 因此只展示 Git 能可靠报告的对象阶段和进度，避免把对象编号伪装成文件名。
private actor GitTransferProgressReporter {
    private let progress: RepositoryOperationProgressHandler
    private var lastUpdate: GitTransferProgressUpdate?

    init(_ progress: @escaping RepositoryOperationProgressHandler) {
        self.progress = progress
    }

    func accept(_ lines: [CommandOutputLine]) async {
        for line in lines {
            guard let update = GitTransferProgressParser.parse(line.text), update != lastUpdate else { continue }
            let stageChanged = update.stage != lastUpdate?.stage
            lastUpdate = update
            let records = stageChanged
                ? [RepositoryProgressRecord(kind: .information, message: update.message)]
                : []
            await progress(RepositoryOperationProgress(
                update.message,
                fractionCompleted: update.fraction,
                detail: update.detail,
                records: records
            ))
        }
    }
}

struct GitTransferProgressUpdate: Equatable {
    let stage: String
    let message: String
    let fraction: Double?
    let detail: String?
}

/// 只解析 Git 自身稳定的传输进度文本，避免把远端任意输出当成进度或成功提示。
enum GitTransferProgressParser {
    /// 只识别 Git 自身稳定的传输行。远端任意输出不会被当成成功或进度信息展示。
    static func parse(_ rawLine: String) -> GitTransferProgressUpdate? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = #"^(?:remote:\s*)?(Enumerating objects|Counting objects|Compressing objects|Receiving objects|Resolving deltas|Updating files):\s*([0-9]{1,3})%\s*(?:\(([^)]*)\))?(?:,\s*(.*))?$"#
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let percentageText = capture(2, from: match, in: line),
              let percentage = Int(percentageText), (0...100).contains(percentage) else {
            // `remote: Enumerating objects: 12, done.` 这种行没有可比较的比例，但可明确说明正在建立传输清单。
            if line.range(of: #"^remote:\s*Enumerating objects:\s*[0-9]+"#, options: .regularExpression) != nil {
                return GitTransferProgressUpdate(stage: "enumerating", message: "正在枚举 Git 对象…", fraction: nil, detail: nil)
            }
            return nil
        }

        guard let stageName = capture(1, from: match, in: line) else { return nil }
        let stage: String
        let message: String
        switch stageName {
        case "Enumerating objects": stage = "enumerating"; message = "正在枚举 Git 对象…"
        case "Counting objects": stage = "counting"; message = "正在统计 Git 对象…"
        case "Compressing objects": stage = "compressing"; message = "正在压缩 Git 对象…"
        case "Receiving objects": stage = "receiving"; message = "正在接收 Git 对象…"
        case "Resolving deltas": stage = "resolving"; message = "正在解析 Git 差异…"
        case "Updating files": stage = "updating"; message = "正在更新工作区文件…"
        default: return nil
        }

        let count = capture(3, from: match, in: line)?.trimmingCharacters(in: .whitespaces)
        let suffix = capture(4, from: match, in: line)?.trimmingCharacters(in: .whitespaces)
        let reliableCount = count.flatMap { $0.range(of: #"^[0-9]+/[0-9]+$"#, options: .regularExpression) == nil ? nil : $0 }
        // 只保留 Git 客户端生成的速率形态；远端可打印任意文本，不能把它送进界面。
        let reliableRate = suffix.flatMap {
            $0.range(of: #"^[0-9.]+\s+(?:KiB|MiB|GiB)\s+\|\s+[0-9.]+\s+(?:KiB|MiB|GiB)/s$"#, options: .regularExpression) == nil ? nil : $0
        }
        let detailParts = [reliableCount, reliableRate].compactMap { $0 }.filter { !$0.isEmpty }
        return GitTransferProgressUpdate(
            stage: stage,
            message: message,
            fraction: Double(percentage) / 100,
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
        )
    }

    private static func capture(_ index: Int, from match: NSTextCheckingResult, in text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let stringRange = Range(range, in: text) else { return nil }
        return String(text[stringRange])
    }
}

private extension GitProvider {
    func parseStatus(_ data: Data) throws -> [FileChange] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        var changes: [FileChange] = []
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard !field.isEmpty else { continue }
            guard field.count >= 3 else { throw VersionControlError.invalidData("Git 状态记录格式错误。") }
            let status = String(decoding: field.prefix(2), as: UTF8.self)
            let path = String(decoding: field.dropFirst(3), as: UTF8.self)
            let first = status.first ?? " "
            let second = status.last ?? " "
            var originalPath: String?
            if first == "R" || first == "C" {
                guard index < fields.count else { throw VersionControlError.invalidData("Git 重命名记录缺少原路径。") }
                originalPath = String(decoding: fields[index], as: UTF8.self)
                index += 1
            }
            changes.append(FileChange(path: path, kind: statusKind(status), originalPath: originalPath, isStaged: first != " " && first != "?", isUnstaged: second != " " || first == "?"))
        }
        return changes
    }

    func parseNameStatus(_ data: Data) throws -> [FileChange] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        var changes: [FileChange] = []
        while index < fields.count {
            let statusField = fields[index]
            index += 1
            guard !statusField.isEmpty else { continue }
            guard index < fields.count else { throw VersionControlError.invalidData("Git 文件变更记录缺少路径。") }
            let status = String(decoding: statusField, as: UTF8.self)
            let kind = changeKind(status.first ?? " ")
            let firstPath = String(decoding: fields[index], as: UTF8.self)
            index += 1
            if kind == .renamed || kind == .copied {
                guard index < fields.count else { throw VersionControlError.invalidData("Git 重命名记录缺少目标路径。") }
                let newPath = String(decoding: fields[index], as: UTF8.self)
                index += 1
                changes.append(FileChange(path: newPath, kind: kind, originalPath: firstPath, isStaged: true, isUnstaged: false))
            } else {
                changes.append(FileChange(path: firstPath, kind: kind, isStaged: true, isUnstaged: false))
            }
        }
        return changes
    }

    func parseHistory(_ data: Data) throws -> [Revision] {
        let formatter = ISO8601DateFormatter()
        return try data.split(separator: 0x1e, omittingEmptySubsequences: true).filter { hasNonWhitespaceByte($0) }.map { record in
            let fields = record.split(separator: 0, maxSplits: 6, omittingEmptySubsequences: false)
            guard fields.count >= 6 else { throw VersionControlError.invalidData("Git 提交记录格式错误。") }
            let id = String(decoding: fields[0], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let author = String(decoding: fields[1], as: UTF8.self).trimmingCharacters(in: .newlines)
            let dateText = String(decoding: fields[2], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = formatter.date(from: dateText) else { throw VersionControlError.invalidData("无法解析 Git 提交时间。") }
            let parents = String(decoding: fields[3], as: UTF8.self).split(separator: " ").map(String.init)
            let refs = String(decoding: fields[4], as: UTF8.self).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("HEAD ->") }
            let message = String(decoding: fields[5], as: UTF8.self).trimmingCharacters(in: .newlines)
            return Revision(id: id, author: author, date: date, message: message, parents: parents, references: refs)
        }
    }

    /// `git log --name-status -z` 的每个提交由格式化记录分隔符开始；提交元数据后的 NUL 字段是文件状态及路径。
    /// 从新到旧维护追溯路径，使重命名提交之前的记录保留当时的旧路径。
    func parseFileHistory(_ data: Data, newestPath: String) throws -> [FileHistoryEntry] {
        let formatter = ISO8601DateFormatter()
        var trackedPath = newestPath
        var entries: [FileHistoryEntry] = []
        for record in data.split(separator: 0x1e, omittingEmptySubsequences: true) where hasNonWhitespaceByte(record) {
            let fields = record.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count >= 6 else { throw VersionControlError.invalidData("Git 单文件历史记录格式错误。") }
            let id = String(decoding: fields[0], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let author = String(decoding: fields[1], as: UTF8.self).trimmingCharacters(in: .newlines)
            let dateText = String(decoding: fields[2], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, let date = formatter.date(from: dateText) else {
                throw VersionControlError.invalidData("无法解析 Git 单文件历史提交。")
            }
            let parents = String(decoding: fields[3], as: UTF8.self).split(separator: " ").map(String.init)
            let references = String(decoding: fields[4], as: UTF8.self).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("HEAD ->") }
            let message = String(decoding: fields[5], as: UTF8.self).trimmingCharacters(in: .newlines)
            let revision = Revision(id: id, author: author, date: date, message: message, parents: parents, references: references)
            entries.append(FileHistoryEntry(revision: revision, path: trackedPath, pegRevision: id))

            var index = 6
            while index < fields.count {
                let status = String(decoding: fields[index], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                guard !status.isEmpty else { continue }
                guard index < fields.count else { throw VersionControlError.invalidData("Git 单文件历史缺少文件路径。") }
                let firstPath = String(decoding: fields[index], as: UTF8.self)
                index += 1
                if status.hasPrefix("R") || status.hasPrefix("C") {
                    guard index < fields.count else { throw VersionControlError.invalidData("Git 单文件历史缺少重命名目标路径。") }
                    let secondPath = String(decoding: fields[index], as: UTF8.self)
                    index += 1
                    // --follow 由新到旧追溯；遇到重命名后，下一个较旧提交使用旧路径。
                    if secondPath == trackedPath { trackedPath = firstPath }
                }
            }
        }
        return entries
    }

    func changeKind(_ marker: Character) -> FileChangeKind {
        switch marker {
        case "A": .added
        case "M": .modified
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "?": .untracked
        case "U": .conflicted
        default: .unknown
        }
    }

    func statusKind(_ status: String) -> FileChangeKind {
        let conflicts: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        if conflicts.contains(status) { return .conflicted }
        let first = status.first ?? " "
        let second = status.last ?? " "
        return changeKind(first == " " || first == "?" ? second : first)
    }

    func hasNonWhitespaceByte(_ record: Data.SubSequence) -> Bool {
        record.contains { byte in byte != 0x0A && byte != 0x0D && byte != 0x20 && byte != 0x09 }
    }
}
