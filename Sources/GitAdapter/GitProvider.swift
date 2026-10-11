import Foundation
import ToolExecution
import VersionControlCore

/// Git 的真实只读实现。所有命令均以参数数组传递，不经过 shell。
public final class GitProvider: VersionControlProvider, @unchecked Sendable {
    public let id: ProviderID = .git
    public let displayName = "Git"

    private let runner: CommandRunner
    private let fileManager: FileManager

    public init(runner: CommandRunner = CommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func detect(at directory: URL) async throws -> RepositoryBinding? {
        guard let metadataDirectory = findGitMetadata(above: directory) else { return nil }

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
        let remoteResult = try await git(["config", "--get", "remote.origin.url"], in: root)
        if remoteResult.exitCode != 0 && remoteResult.exitCode != 1 { _ = try requireSuccess(remoteResult, tool: "git") }
        let remote = remoteResult.exitCode == 0
            ? remoteResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        return RepositoryBinding(
            providerID: .git,
            providerName: displayName,
            root: root,
            currentBranch: branch,
            remoteURL: remote?.isEmpty == false ? remote : nil,
            capabilities: [.status, .diff, .history, .branches, .commitGraph]
        )
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

    private func git(_ command: [String], in directory: URL) async throws -> CommandResult {
        try await runner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-c", "core.pager=cat", "-c", "pager.branch=false", "-c", "core.fsmonitor=false"] + command,
            directory: directory
        )
    }

    private func ensureGit(_ binding: RepositoryBinding) throws {
        guard binding.providerID == .git else { throw VersionControlError.invalidRepository("该绑定不是 Git 工作区。") }
    }

    private func findGitMetadata(above directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        while true {
            let metadata = candidate.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: metadata.path) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
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
