import CryptoKit
import Foundation
import ToolExecution
import VersionControlCore

extension GitProvider: RepositoryShelfProvider {
    public func shelfPreview(in binding: RepositoryBinding, includeUntracked: Bool) async throws -> RepositoryShelfPreview {
        try ensureGit(binding)
        let changes = try await status(in: binding)
        try await ensureSafeIndexOperation(changes.map(\.path), root: binding.root)
        let files = changes.compactMap { change -> RepositoryShelfFile? in
            if change.kind == .untracked { return includeUntracked ? .init(path: change.path, kind: .untracked) : nil }
            if change.kind == .conflicted { return nil }
            return .init(path: change.path, kind: .modified)
        }
        guard !changes.contains(where: { $0.kind == .conflicted }) else {
            throw VersionControlError.unsupported("工作区存在冲突，不能安全搁置；请先解决或中止当前操作。")
        }
        let token = try await shelfStateToken(in: binding.root, includeUntracked: includeUntracked)
        var warnings: [String] = []
        if !includeUntracked, changes.contains(where: { $0.kind == .untracked }) { warnings.append("未跟踪文件不会包含在本次搁置中。") }
        if files.isEmpty { warnings.append("当前范围没有可搁置的改动。") }
        return RepositoryShelfPreview(binding: binding, files: files, stateToken: token, warnings: warnings)
    }

    public func shelves(in binding: RepositoryBinding) async throws -> [RepositoryShelfRecord] {
        try ensureGit(binding)
        let result = try await git(["stash", "list", "--format=%H%x1f%gd%x1f%ct%x1f%s"], in: binding.root)
        let output = try requireSuccess(result, tool: "git").output
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let fields = raw.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let seconds = TimeInterval(fields[2]) else { return nil }
            return RepositoryShelfRecord(id: fields[0], providerID: .git, name: fields[3],
                createdAt: Date(timeIntervalSince1970: seconds), files: [], reference: fields[1])
        }
    }

    public func createShelf(in binding: RepositoryBinding, name: String, includeUntracked: Bool,
                            mode: RepositoryShelfMode, expectedStateToken: String) async throws -> RepositoryShelfRecord {
        try ensureGit(binding)
        let currentChanges = try await status(in: binding)
        try await ensureSafeIndexOperation(currentChanges.map(\.path), root: binding.root)
        guard try await shelfStateToken(in: binding.root, includeUntracked: includeUntracked) == expectedStateToken else {
            throw VersionControlError.invalidRepository("工作区修改已变化，请重新查看搁置预览。")
        }
        let preview = try await shelfPreview(in: binding, includeUntracked: includeUntracked)
        guard !preview.files.isEmpty else { throw VersionControlError.invalidRepository("当前范围没有可搁置的改动。") }
        let before = try await stashHead(in: binding.root)
        var args = ["stash", "push", "--message", name]
        if includeUntracked { args.append("--include-untracked") }
        _ = try requireSuccess(try await git(args, in: binding.root), tool: "git")
        guard let after = try await stashHead(in: binding.root), after != before else {
            throw VersionControlError.executionFailed("Git 未创建搁置记录。")
        }
        let record = RepositoryShelfRecord(id: after, providerID: .git, name: name, files: preview.files, reference: after)
        if mode == .saveOnly {
            // stash push 会清理工作区；立即按索引恢复原始状态。记录保留，失败也不会被自动丢弃。
            let restored = try await git(["stash", "apply", "--index", after], in: binding.root)
            guard restored.exitCode == 0 else {
                throw VersionControlError.executionFailed("搁置已保存，但无法自动恢复原工作区；记录仍保留，可在搁置列表中恢复。\n\(RepositoryDisplaySanitizer.redact(restored.error))")
            }
        }
        return record
    }

    public func restoreShelf(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws -> RepositoryShelfRestoreResult {
        try ensureGit(binding)
        let currentChanges = try await status(in: binding)
        try await ensureSafeIndexOperation(currentChanges.map(\.path), root: binding.root)
        guard record.providerID == .git, let current = try await currentStashRecord(record.id, in: binding.root) else {
            throw VersionControlError.invalidRepository("找不到此 Git 搁置记录；它可能已被其他客户端删除。")
        }
        let paths = try await stashPaths(current.id, in: binding.root)
        try await ensureSafeIndexOperation(paths, root: binding.root)
        let result = try await git(["stash", "apply", "--index", current.reference], in: binding.root)
        _ = try requireSuccess(result, tool: "git")
        return RepositoryShelfRestoreResult(record: record, summary: "已恢复“\(record.name)”。搁置记录仍保留，可在确认无误后手动删除。")
    }

    public func deleteShelf(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws {
        try ensureGit(binding)
        guard record.providerID == .git, let current = try await currentStashRecord(record.id, in: binding.root) else {
            throw VersionControlError.invalidRepository("找不到此 Git 搁置记录；它可能已被其他客户端删除。")
        }
        _ = try requireSuccess(try await git(["stash", "drop", current.reference], in: binding.root), tool: "git")
    }

    private func shelfStateToken(in directory: URL, includeUntracked: Bool) async throws -> String {
        let head = try await optionalHead(in: directory) ?? "(unborn)"
        let statusResult = try await git(["status", "--porcelain=v1", "-z", includeUntracked ? "--untracked-files=all" : "--untracked-files=no"], in: directory)
        let staged = try requireSuccess(try await git(["-c", "diff.external=", "diff", "--no-ext-diff", "--no-textconv", "--cached", "--binary"], in: directory), tool: "git").data
        let unstaged = try requireSuccess(try await git(["-c", "diff.external=", "diff", "--no-ext-diff", "--no-textconv", "--binary"], in: directory), tool: "git").data
        var untracked = Data()
        if includeUntracked {
            let currentBinding = try await binding(at: directory)
            let changes = try await status(in: currentBinding)
            for change in changes where change.kind == .untracked {
                let url = directory.appendingPathComponent(change.path)
                let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                    throw VersionControlError.unsupported("未跟踪内容不是普通文件，不能安全搁置：\(change.path)")
                }
                untracked.append(Data(change.path.utf8)); untracked.append(0)
                untracked.append(try Data(contentsOf: url))
            }
        }
        let raw = try requireSuccess(statusResult, tool: "git").data
        var all = Data(head.utf8)
        all.append(raw); all.append(staged); all.append(unstaged); all.append(untracked)
        return sha256(all)
    }

    private func stashHead(in directory: URL) async throws -> String? {
        let result = try await git(["rev-parse", "--verify", "--quiet", "refs/stash"], in: directory)
        if result.exitCode == 1 { return nil }
        return try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentStashRecord(_ id: String, in directory: URL) async throws -> RepositoryShelfRecord? {
        let current = try await binding(at: directory)
        let records = try await shelves(in: current)
        return records.first { $0.id == id }
    }

    private func stashPaths(_ id: String, in directory: URL) async throws -> [String] {
        let result = try await git(["stash", "show", "--include-untracked", "--name-only", "--format=", "-z", id], in: directory)
        let data = try requireSuccess(result, tool: "git").data
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
    }

    private func binding(at directory: URL) async throws -> RepositoryBinding {
        guard let binding = try await detect(at: directory) else { throw VersionControlError.invalidRepository("未找到 Git 工作副本。") }
        return binding
    }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
