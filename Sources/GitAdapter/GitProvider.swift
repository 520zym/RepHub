import Foundation
import ToolExecution
import VersionControlCore

/// Git 适配器。读取与受限的获取／快进更新均通过参数数组执行，不经过 shell。
public final class GitProvider: RepositoryOperationProvider, @unchecked Sendable {
    public let id: ProviderID = .git
    public let displayName = "Git"

    private let runner: CommandRunner
    private let fileManager: FileManager

    public init(runner: CommandRunner = CommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
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
            capabilities: [.status, .diff, .history, .branches, .commitGraph, .fetch, .update]
        )
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

    private func fetch(
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryOperationResult {
        await progress(RepositoryOperationProgress("正在检查当前分支的上游配置…"))
        let upstream = try await configuredUpstream(in: binding.root)
        try Task.checkCancellation()

        await progress(RepositoryOperationProgress("正在从 \(upstream.remote) 获取远端引用…"))
        try await fetch(remote: upstream.remote, in: binding.root)
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
        try await fetch(remote: upstream.remote, in: binding.root)
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
        return value.isEmpty ? nil : value
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

    private func fetch(remote: String, in directory: URL) async throws {
        let result = try await git(
            ["fetch", "--no-write-fetch-head", "--no-tags", "--no-recurse-submodules", "--", remote],
            in: directory,
            timeout: 90
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

    private func git(
        _ command: [String],
        in directory: URL,
        timeout: TimeInterval = 20
    ) async throws -> CommandResult {
        try await runner.run(
            executable: "git",
            // hooks 可由仓库配置执行任意脚本；本客户端的更新不执行它们。
            // 禁止递归 submodule，避免一次操作继续写入子工作区。
            arguments: ["--no-optional-locks", "-c", "core.pager=cat", "-c", "pager.branch=false", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false", "-c", "fetch.recurseSubmodules=false"]
                + command,
            directory: directory,
            timeout: timeout
        )
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
