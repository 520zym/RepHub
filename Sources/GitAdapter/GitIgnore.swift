import Foundation
import ToolExecution
import VersionControlCore

extension GitProvider: RepositoryIgnoreProvider {
    public func prepareIgnore(in binding: RepositoryBinding) async throws -> RepositoryIgnorePreparation {
        try ensureGit(binding)
        let changes = try await status(in: binding)
        var candidates: [RepositoryIgnoreCandidate] = []
        for change in changes {
            guard change.kind == .untracked, !gitIgnoreMetadataPath(change.path) else { continue }
            let fingerprint = try await gitIgnoreFingerprint(path: change.path, root: binding.root)
            candidates.append(RepositoryIgnoreCandidate(path: change.path, fingerprint: fingerprint,
                                                        defaultRule: gitLiteralIgnoreRule(change.path),
                                                        scopes: [.currentDirectory, .repository]))
        }
        return RepositoryIgnorePreparation(binding: binding, candidates: candidates,
            notice: "Git 会把规则写入对应 .gitignore；不会自动暂存、提交或推送。已跟踪路径和符号链接不能添加忽略规则。")
    }

    public func previewIgnore(_ request: RepositoryIgnoreRequest, in binding: RepositoryBinding) async throws -> RepositoryIgnorePreview {
        try ensureGit(binding)
        let resolved = try await gitIgnoreResolvedRequest(request, root: binding.root)
        return RepositoryIgnorePreview(targetDescription: resolved.target.path.replacingOccurrences(of: binding.root.path + "/", with: ""),
                                       before: resolved.before, after: resolved.after, stateToken: resolved.stateToken)
    }

    public func applyIgnore(_ request: RepositoryIgnoreRequest, in binding: RepositoryBinding,
                            progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryIgnoreResult {
        try ensureGit(binding)
        let resolved = try await gitIgnoreResolvedRequest(request, root: binding.root)
        try Task.checkCancellation()
        await progress(RepositoryOperationProgress("正在复核 Git 忽略规则…"))
        guard let token = request.previewToken, token == resolved.stateToken else {
            throw VersionControlError.invalidRepository(".gitignore 或待忽略文件在预览后已变化，请重新生成预览。")
        }
        await progress(RepositoryOperationProgress("正在写入 Git 忽略规则…"))
        try Data(resolved.after.utf8).write(to: resolved.target, options: .atomic)
        await progress(RepositoryOperationProgress("已写入 Git 忽略规则；尚未提交。", fractionCompleted: 1))
        return RepositoryIgnoreResult(summary: "已更新 \(resolved.target.lastPathComponent)，尚未暂存或提交。")
    }

    private func gitIgnoreResolvedRequest(_ request: RepositoryIgnoreRequest, root: URL) async throws -> (target: URL, before: String, after: String, stateToken: String) {
        guard request.bindingID == "git:\(root.standardizedFileURL.path)" else {
            throw VersionControlError.invalidRepository("忽略规则请求与当前 Git 工作副本不一致。")
        }
        let candidate = request.candidate
        let fingerprint = try await gitIgnoreFingerprint(path: candidate.path, root: root)
        guard candidate.scopes.contains(request.scope), !gitIgnoreMetadataPath(candidate.path),
              candidate.fingerprint == fingerprint else {
            throw VersionControlError.invalidRepository("待忽略文件已变化、已受跟踪，或不再可安全处理。")
        }
        let rule = try gitValidatedLiteralRule(request.rule)
        let parent: URL
        let outputRule: String
        switch request.scope {
        case .repository:
            parent = root; outputRule = rule.hasPrefix("/") ? rule : "/\(rule)"
        case .currentDirectory:
            let file = try CommitFileSnapshot.validatedURL(root: root, path: candidate.path)
            parent = file.deletingLastPathComponent()
            guard !rule.contains("/") else { throw VersionControlError.invalidData("当前文件夹规则只能填写文件名；如需完整路径，请选择“整个仓库”。") }
            outputRule = rule
        }
        let target = parent.appendingPathComponent(".gitignore")
        try gitRejectMetadataOrSymlink(target, root: root)
        let before = try gitIgnoreText(at: target)
        let line = outputRule + "\n"
        let after: String
        if before.split(whereSeparator: \.isNewline).map(String.init).contains(outputRule) { after = before }
        else if before.isEmpty || before.hasSuffix("\n") { after = before + line }
        else { after = before + "\n" + line }
        let token = CommitFileSnapshot.fingerprint(data: Data((candidate.fingerprint + "\u{0}" + target.path + "\u{0}" + before + "\u{0}" + after).utf8))
        return (target, before, after, token)
    }

    private func gitIgnoreFingerprint(path: String, root: URL) async throws -> String {
        let candidate = try CommitFileSnapshot.validatedURL(root: root, path: path)
        let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw VersionControlError.unsupported("符号链接不能作为忽略规则目标。")
        }
        // `status` 是调用方 prepare 的来源；再通过 Git 自身确认此路径未被跟踪。
        let tracked = try await git(["--literal-pathspecs", "ls-files", "--error-unmatch", "--", path], in: root)
        if tracked.exitCode == 0 { throw VersionControlError.unsupported("已受 Git 跟踪的路径不能添加忽略规则。") }
        if tracked.exitCode != 1 { _ = try requireSuccess(tracked, tool: "git") }
        return try CommitFileSnapshot.fingerprint(root: root, path: path)
    }

    private func gitIgnoreText(at url: URL) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else {
            throw VersionControlError.unsupported(".gitignore 不是可安全修改的普通文本文件。")
        }
        let data = try Data(contentsOf: url)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw VersionControlError.unsupported(".gitignore 不是 UTF-8 文本，RepHub 不会覆盖它。")
        }
        return text
    }

    private func gitRejectMetadataOrSymlink(_ target: URL, root: URL) throws {
        let relative = target.standardizedFileURL.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        guard !gitIgnoreMetadataPath(relative), (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) == nil else {
            throw VersionControlError.unsupported("不能通过符号链接或版本管理元数据写入忽略规则。")
        }
    }

    private func gitValidatedLiteralRule(_ rule: String) throws -> String {
        guard !rule.isEmpty, rule == rule.trimmingCharacters(in: .whitespacesAndNewlines),
              !rule.contains("\n"), !rule.contains("\r"), !rule.contains("\0"), rule != ".", rule != ".." else {
            throw VersionControlError.invalidData("忽略规则必须是一条非空路径，不能包含换行或控制字符。")
        }
        return rule
    }

    private func gitLiteralIgnoreRule(_ path: String) -> String {
        var rule = ""
        for scalar in path.unicodeScalars {
            if "\\*?[]#!".unicodeScalars.contains(scalar) { rule.append("\\") }
            rule.unicodeScalars.append(scalar)
        }
        return rule
    }

    private func gitIgnoreMetadataPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { [".git", ".svn"].contains($0.lowercased()) }
    }
}
