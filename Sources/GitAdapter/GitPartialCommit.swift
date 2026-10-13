import Foundation
import Darwin
import ToolExecution
import VersionControlCore

extension GitProvider: RepositoryPartialCommitProvider {
    public func preparePartialCommit(in binding: RepositoryBinding) async throws -> RepositoryPartialCommitPreparation {
        try ensureGit(binding)
        guard !(try await hasInProgressOperation(in: binding.root)) else {
            throw VersionControlError.unsupported("Git 正处于合并或变基中，不能按块提交。")
        }
        guard !(try await commitUsesUnsafeFilter(in: binding.root)) else {
            throw VersionControlError.unsupported("Git 文件过滤器可能执行外部程序，RepHub 不会构造部分提交。")
        }
        let base = try await optionalHead(in: binding.root)
        guard base != nil else { throw VersionControlError.unsupported("首个 Git 提交只能按文件提交，暂不支持按块提交。") }
        let changes = try await status(in: binding)
        var files: [RepositoryPartialCommitFile] = []
        for change in changes where !gitPartialMetadataPath(change.path) {
            let patch = try await partialPatch(for: change, root: binding.root)
            let fingerprint = try await partialFingerprint(for: change, root: binding.root)
            if change.kind != .modified || change.originalPath != nil {
                files.append(RepositoryPartialCommitFile(path: change.path, fingerprint: fingerprint,
                    mode: .fileOnly(reason: "该变更不是普通文本修改，只能按整个文件提交。"), hunks: [], fullPatch: patch))
                continue
            }
            do {
                let parsed = try GitPartialPatch.parse(patch.text, expectedPath: change.path)
                files.append(RepositoryPartialCommitFile(path: change.path, fingerprint: fingerprint,
                    mode: .lineSelection, hunks: parsed.hunks.map(\.publicHunk), fullPatch: patch))
            } catch {
                files.append(RepositoryPartialCommitFile(path: change.path, fingerprint: fingerprint,
                    mode: .fileOnly(reason: "(error.localizedDescription)；只能按整个文件提交。"), hunks: [], fullPatch: patch))
            }
        }
        return RepositoryPartialCommitPreparation(binding: binding, baseRevision: base,
            stateToken: try await partialStateToken(in: binding.root), files: files,
            notice: "勾选要提交的修改行，未选内容留在工作区。其他文件已有的暂存内容不会一并提交。")
    }

    public func previewPartialCommit(_ request: RepositoryPartialCommitRequest, in binding: RepositoryBinding) async throws -> RepositoryPartialCommitPreview {
        try ensureGit(binding)
        let built = try await buildPartialCommit(request, binding: binding)
        return RepositoryPartialCommitPreview(patch: RepositoryPatch(text: built.patch), selectedPaths: built.paths)
    }

    public func commitPartial(_ request: RepositoryPartialCommitRequest, in binding: RepositoryBinding,
                              progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryCommitResult {
        try ensureGit(binding)
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "未填写提交说明，未创建 Git 提交。") }
        let built: BuiltPartialCommit
        do { built = try await buildPartialCommit(request, binding: binding) }
        catch { return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "部分提交未开始。", details: error.localizedDescription) }
        guard !built.patch.isEmpty else { return RepositoryCommitResult(bindingID: binding.id, outcome: .notStarted, summary: "未选择可提交的代码块或行。") }

        let index: URL
        do { index = try await gitIndexLocation(in: binding.root) }
        catch { return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "部分提交未开始。", details: error.localizedDescription) }
        let lock: GitPartialIndexLock
        do { lock = try GitPartialIndexLock(index: index) }
        catch { return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "部分提交未开始。", details: error.localizedDescription) }
        defer { lock.release() }

        let folder = index.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent("rephub-partial-index-\(UUID().uuidString)")
        let published = folder.appendingPathComponent("rephub-partial-publish-index-\(UUID().uuidString)")
        let originalIndex = try? Data(contentsOf: index)
        defer { try? fileManager.removeItem(at: temporary); try? fileManager.removeItem(at: published) }
        do {
            // 锁住真实 index 后再次完整复核，避免预览与临时树之间混入其他客户端的改动。
            let currentToken = try await partialStateToken(in: binding.root)
            let currentBase = try await optionalHead(in: binding.root)
            guard request.stateToken == currentToken, request.baseRevision == currentBase else {
                throw VersionControlError.invalidRepository("工作区、HEAD 或暂存区已变化，请重新生成部分提交预览。")
            }
            await progress(RepositoryOperationProgress("正在构造所选代码块的临时 Git 暂存区…"))
            _ = try requireSuccess(try await git(["read-tree", request.baseRevision!], in: binding.root, gitIndexFile: temporary), tool: "git")
            _ = try requireSuccess(try await partialGitInput(["apply", "--cached", "--whitespace=nowarn", "--recount", "-"],
                                                              in: binding.root, gitIndexFile: temporary,
                                                              input: Data(built.patch.utf8)), tool: "git")
            // `git diff --cached --check` 会验证补丁应用后的索引内容，但不执行 hooks 或过滤器。
            _ = try requireSuccess(try await git(["diff", "--cached", "--check"], in: binding.root, gitIndexFile: temporary), tool: "git")
            let finalToken = try await partialStateToken(in: binding.root)
            let finalBase = try await optionalHead(in: binding.root)
            guard request.stateToken == finalToken, request.baseRevision == finalBase else {
                throw VersionControlError.invalidRepository("构造临时提交期间工作区、HEAD 或暂存区已变化，未创建提交。")
            }
            await progress(RepositoryOperationProgress("正在创建仅包含所选代码的本地 Git 提交…"))
            let committed = try await git(["commit", "--no-verify", "--no-gpg-sign", "--no-status", "--cleanup=verbatim", "-m", message],
                                          in: binding.root, timeout: 90, gitIndexFile: temporary)
            let output = try requireSuccess(committed, tool: "git")
            let revision = try await currentHead(in: binding.root)
            // 当前选中文件事先被拒绝为已暂存，所以原 index 中它仍是提交前的 HEAD。
            // 把这个路径重置到新 HEAD 后再原子发布，其他路径的预有暂存内容完全保留。
            if let originalIndex { try originalIndex.write(to: published, options: .atomic) }
            else { _ = try requireSuccess(try await git(["read-tree", "--empty"], in: binding.root, gitIndexFile: published), tool: "git") }
            _ = try requireSuccess(try await git(["--literal-pathspecs", "reset", "--mixed", "--quiet", "HEAD", "--"] + built.paths,
                                                  in: binding.root, gitIndexFile: published), tool: "git")
            guard (try? Data(contentsOf: index)) == originalIndex else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .unknown, revisionID: revision,
                    summary: "本地 Git 提交已创建，但真实暂存区在提交期间变化，未替换其内容。",
                    details: "请刷新并核对暂存区；不要直接重复提交。", committedFiles: built.paths.map { FileChange(path: $0, kind: .modified) })
            }
            try replacePartialIndexAtomically(from: published, to: index)
            await progress(RepositoryOperationProgress("已创建本地 Git 提交。", fractionCompleted: 1))
            return RepositoryCommitResult(bindingID: binding.id, outcome: .succeeded, revisionID: revision,
                summary: "已提交所选代码块；未推送远端。", details: output.error, committedFiles: built.paths.map { FileChange(path: $0, kind: .modified) })
        } catch is CancellationError {
            let after: String? = (try? await optionalHead(in: binding.root)) ?? nil
            if after != request.baseRevision {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .unknown, revisionID: after,
                    summary: "部分提交取消后发现 HEAD 已变化，请刷新核对提交和暂存区。",
                    details: "为避免误判，RepHub 没有声称提交未创建。")
            }
            return RepositoryCommitResult(bindingID: binding.id, outcome: .cancelled, summary: "部分提交已取消，未修改真实暂存区。")
        } catch {
            let after: String? = (try? await optionalHead(in: binding.root)) ?? nil
            if after != request.baseRevision {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .unknown, revisionID: after,
                    summary: "部分提交命令未确认，但 HEAD 已变化，请刷新核对提交和暂存区。",
                    details: error.localizedDescription)
            }
            return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "部分提交未完成，未修改真实暂存区。", details: error.localizedDescription)
        }
    }

    private struct BuiltPartialCommit {
        let paths: [String]
        let patch: String
    }

    private func buildPartialCommit(_ request: RepositoryPartialCommitRequest, binding: RepositoryBinding) async throws -> BuiltPartialCommit {
        guard request.bindingID == binding.id else { throw VersionControlError.invalidRepository("部分提交请求与当前 Git 工作副本不一致。") }
        let currentBase = try await optionalHead(in: binding.root)
        guard request.baseRevision == currentBase else { throw VersionControlError.invalidRepository("当前 Git 提交已变化，请刷新后重新选择代码。") }
        let currentToken = try await partialStateToken(in: binding.root)
        guard request.stateToken == currentToken else { throw VersionControlError.invalidRepository("工作区或暂存区已变化，请重新生成部分提交预览。") }
        guard !(try await hasInProgressOperation(in: binding.root)), !(try await commitUsesUnsafeFilter(in: binding.root)) else {
            throw VersionControlError.unsupported("Git 当前状态不允许构造部分提交。")
        }
        guard !request.selections.isEmpty, Set(request.selections.map(\.path)).count == request.selections.count else {
            throw VersionControlError.invalidData("请至少选择一个文件，且每个文件只能出现一次。")
        }
        var paths: [String] = [], patches: [String] = []
        let currentChanges = try await status(in: binding)
        let changes = Dictionary(uniqueKeysWithValues: currentChanges.map { ($0.path, $0) })
        for selection in request.selections {
            guard let change = changes[selection.path], !gitPartialMetadataPath(change.path) else {
                throw VersionControlError.invalidRepository("待提交文件已不在当前变更列表中：\(selection.path)")
            }
            let fingerprint = try await partialFingerprint(for: change, root: binding.root)
            guard selection.fingerprint == fingerprint else {
                throw VersionControlError.invalidRepository("文件 \(selection.path) 或其暂存状态已经变化，请重新选择代码。")
            }
            guard !change.isStaged else {
                throw VersionControlError.unsupported("\(selection.path) 已有暂存内容。为防止反向暂存，请先在 Git 中取消该文件的暂存后再按块提交；其他文件的暂存内容不会受影响。")
            }
            let full = try await partialPatch(for: change, root: binding.root)
            if selection.selectWholeFile {
                guard !full.text.isEmpty else { continue }
                paths.append(selection.path); patches.append(full.text); continue
            }
            guard change.kind == .modified, change.originalPath == nil else {
                throw VersionControlError.unsupported("\(selection.path) 只能按整个文件提交。")
            }
            let parsed = try GitPartialPatch.parse(full.text, expectedPath: selection.path)
            let patch = try parsed.render(selectedLineIDs: selection.selectedLineIDs)
            if !patch.isEmpty { paths.append(selection.path); patches.append(patch) }
        }
        guard !paths.isEmpty else { throw VersionControlError.invalidData("未选择可提交的代码块或行。") }
        try await ensureSafeIndexOperation(paths, root: binding.root)
        return BuiltPartialCommit(paths: paths, patch: patches.joined(separator: "\n"))
    }

    private func partialPatch(for change: FileChange, root: URL) async throws -> RepositoryPatch {
        let path = try CommitFileSnapshot.validatedURL(root: root, path: change.path).path
        _ = path
        let result = try await git(["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--unified=3", "HEAD", "--", change.path], in: root)
        return RepositoryPatch(text: try requireSuccess(result, tool: "git").output)
    }

    private func partialFingerprint(for change: FileChange, root: URL) async throws -> String {
        _ = try CommitFileSnapshot.validatedURL(root: root, path: change.path)
        let status = try requireSuccess(try await git(["--literal-pathspecs", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", change.path], in: root), tool: "git").data
        let difference = try requireSuccess(try await git(["--literal-pathspecs", "diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD", "--", change.path], in: root), tool: "git").data
        var data = Data(change.path.utf8); data.append(0); data.append(status); data.append(difference)
        return CommitFileSnapshot.fingerprint(data: data)
    }

    private func partialStateToken(in root: URL) async throws -> String {
        let head = try await optionalHead(in: root) ?? ""
        let status = try requireSuccess(try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root), tool: "git").data
        let worktree = try requireSuccess(try await git(["diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD", "--"], in: root), tool: "git").data
        let cached = try requireSuccess(try await git(["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--"], in: root), tool: "git").data
        var data = Data(head.utf8); data.append(0); data.append(status); data.append(worktree); data.append(cached)
        return CommitFileSnapshot.fingerprint(data: data)
    }

    private func gitPartialMetadataPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { [".git", ".svn"].contains($0.lowercased()) }
    }

    /// CommandRunner 的输入能力只用于内存中的、已复核的补丁；参数与普通 Git 调用使用相同的禁 hook 配置。
    private func partialGitInput(_ command: [String], in directory: URL, gitIndexFile: URL, input: Data) async throws -> CommandResult {
        let safeguards = ["--no-optional-locks", "-c", "core.pager=cat", "-c", "pager.branch=false", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false", "-c", "fetch.recurseSubmodules=false"]
        return try await runner.run(executable: "git", arguments: safeguards + command, directory: directory,
                                    timeout: 30, standardInput: input, maximumStandardInputBytes: 2 * 1024 * 1024,
                                    gitIndexFile: gitIndexFile)
    }

    private func replacePartialIndexAtomically(from source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw VersionControlError.executionFailed("无法同步已提交部分到真实 Git 暂存区：\(String(cString: strerror(errno)))")
        }
    }
}

/// 一个完整 hunk 内把未选改动还原为上下文，再由 Git 基准树应用所选改动。
/// 这样既允许选中单行，也不会把同 hunk 的其他改动混入临时 index。
private struct GitPartialPatch {
    struct Entry: Sendable {
        let id: String
        let text: String
        let kind: RepositoryPartialCommitLine.Kind
    }
    struct Hunk: Sendable {
        let id: String
        let oldStart: Int
        let header: String
        let suffix: String
        let entries: [Entry]
        var publicHunk: RepositoryPartialCommitHunk {
            RepositoryPartialCommitHunk(id: id, header: header, lines: entries.map {
                RepositoryPartialCommitLine(id: $0.id, text: $0.text, kind: $0.kind, selectable: $0.kind != .context)
            })
        }
    }
    let prefix: String
    let hunks: [Hunk]

    static func parse(_ patch: String, expectedPath: String) throws -> GitPartialPatch {
        guard !patch.isEmpty, !patch.contains("Binary files "), !patch.contains("GIT binary patch"), !patch.contains("\\ No newline at end of file") else {
            throw VersionControlError.unsupported("此文件不是可安全按行拆分的文本差异")
        }
        var lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard let firstHunk = lines.firstIndex(where: { $0.hasPrefix("@@ ") }) else { throw VersionControlError.unsupported("该文件没有可选择的文本代码块") }
        let prefix = lines[..<firstHunk].joined(separator: "\n") + "\n"
        guard prefix.contains("--- a/\(expectedPath)\n") || prefix.contains("--- \(expectedPath)\n") else {
            throw VersionControlError.invalidData("补丁路径与当前文件不一致")
        }
        var hunks: [Hunk] = [], cursor = firstHunk, ordinal = 0
        while cursor < lines.count {
            let header = lines[cursor]
            guard header.hasPrefix("@@ ") else { throw VersionControlError.invalidData("Git 差异块格式不完整") }
            let headerData = try parseHeader(header)
            var entries: [Entry] = []; cursor += 1; var lineNumber = 0
            while cursor < lines.count, !lines[cursor].hasPrefix("@@ ") {
                let raw = lines[cursor]
                guard let marker = raw.first, [" ", "+", "-"].contains(marker) else {
                    throw VersionControlError.invalidData("Git 差异行格式不完整")
                }
                let kind: RepositoryPartialCommitLine.Kind = marker == "+" ? .addition : marker == "-" ? .deletion : .context
                entries.append(Entry(id: "\(expectedPath)#\(ordinal)#\(lineNumber)#\(marker)", text: String(raw.dropFirst()), kind: kind))
                cursor += 1; lineNumber += 1
            }
            hunks.append(Hunk(id: "\(expectedPath)#h\(ordinal)", oldStart: headerData.start, header: header, suffix: headerData.suffix, entries: entries))
            ordinal += 1
        }
        return GitPartialPatch(prefix: prefix, hunks: hunks)
    }

    func render(selectedLineIDs: Set<String>) throws -> String {
        var output = prefix
        var emitted = false
        for hunk in hunks {
            let selected = hunk.entries.filter { $0.kind != .context && selectedLineIDs.contains($0.id) }
            guard !selected.isEmpty else { continue }
            guard selectedLineIDs.isSubset(of: Set(hunks.flatMap(\.entries).filter { $0.kind != .context }.map(\.id))) else {
                throw VersionControlError.invalidData("所选代码行已变化，请重新生成预览。")
            }
            var old: [String] = [], new: [String] = [], lines: [String] = []
            let selectedIDs = Set(selected.map(\.id))
            for entry in hunk.entries {
                switch entry.kind {
                case .context:
                    old.append(entry.text); new.append(entry.text); lines.append(" \(entry.text)")
                case .deletion:
                    if selectedIDs.contains(entry.id) { old.append(entry.text); lines.append("-\(entry.text)") }
                    else { old.append(entry.text); new.append(entry.text); lines.append(" \(entry.text)") }
                case .addition:
                    if selectedIDs.contains(entry.id) { new.append(entry.text); lines.append("+\(entry.text)") }
                    // 未选新增行不在提交前的基准树中，不能伪装为上下文；直接省略。
                    else { continue }
                }
            }
            output += "@@ -\(hunk.oldStart),\(old.count) +\(hunk.oldStart),\(new.count) @@\(hunk.suffix)\n"
            output += lines.joined(separator: "\n") + "\n"
            emitted = true
        }
        return emitted ? output : ""
    }

    private static func parseHeader(_ header: String) throws -> (start: Int, suffix: String) {
        // @@ -12,3 +12,4 @@ optional function context
        let pattern = "^@@ -([0-9]+)(?:,[0-9]+)? \\+[0-9]+(?:,[0-9]+)? @@(.*)$"
        guard let match = header.range(of: pattern, options: .regularExpression) else { throw VersionControlError.invalidData("Git 差异块行号格式无效") }
        let value = String(header[match])
        let parts = value.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { throw VersionControlError.invalidData("Git 差异块行号格式无效") }
        let old = parts[1].dropFirst().split(separator: ",", maxSplits: 1)[0]
        guard let start = Int(old) else { throw VersionControlError.invalidData("Git 差异块行号格式无效") }
        let suffixStart = value.range(of: " @@")!.upperBound
        return (start, String(value[suffixStart...]))
    }
}

private final class GitPartialIndexLock {
    private let url: URL
    private var held = false
    init(index: URL) throws {
        url = URL(fileURLWithPath: index.path + ".lock")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == EEXIST { throw VersionControlError.executionFailed("Git 暂存区正被其他操作使用，请稍后重试。") }
            throw VersionControlError.executionFailed("无法锁定 Git 暂存区：\(String(cString: strerror(errno)))")
        }
        close(descriptor); held = true
    }
    func release() { guard held else { return }; try? FileManager.default.removeItem(at: url); held = false }
    deinit { release() }
}
