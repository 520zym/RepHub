import Foundation
import ToolExecution
import VersionControlCore

extension SVNProvider: RepositoryIgnoreProvider {
    public func prepareIgnore(in binding: RepositoryBinding) async throws -> RepositoryIgnorePreparation {
        guard binding.providerID == .svn else { throw VersionControlError.invalidRepository("该绑定不是 SVN 工作副本。") }
        let changes = try await status(in: binding)
        var candidates: [RepositoryIgnoreCandidate] = []
        for change in changes where change.kind == .untracked && !svnIgnoreMetadataPath(change.path) {
            let fingerprint = try await svnIgnoreFingerprint(path: change.path, root: binding.root)
            let name = (change.path as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            candidates.append(RepositoryIgnoreCandidate(path: change.path, fingerprint: fingerprint,
                                                        defaultRule: name, scopes: [.currentDirectory]))
        }
        return RepositoryIgnorePreparation(binding: binding, candidates: candidates,
            notice: "SVN 的 svn:ignore 只作用于当前父文件夹。RepHub 会保留既有规则，不会自动提交属性修改。")
    }

    public func previewIgnore(_ request: RepositoryIgnoreRequest, in binding: RepositoryBinding) async throws -> RepositoryIgnorePreview {
        let resolved = try await svnIgnoreResolvedRequest(request, binding: binding)
        return RepositoryIgnorePreview(targetDescription: "\(resolved.parent == "." ? "工作副本根目录" : resolved.parent) 的 svn:ignore 属性",
                                       before: resolved.before, after: resolved.after, stateToken: resolved.stateToken)
    }

    public func applyIgnore(_ request: RepositoryIgnoreRequest, in binding: RepositoryBinding,
                            progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryIgnoreResult {
        let resolved = try await svnIgnoreResolvedRequest(request, binding: binding)
        await progress(RepositoryOperationProgress("正在复核 SVN 忽略规则…"))
        guard let token = request.previewToken, token == resolved.stateToken else {
            throw VersionControlError.invalidRepository("svn:ignore 属性或待忽略文件在预览后已变化，请重新生成预览。")
        }
        await progress(RepositoryOperationProgress("正在写入 SVN 忽略规则…"))
        // 属性写入仅发生在本地工作副本，不应触发面向远端读取的 TLS 兼容重试。
        _ = try requireSuccess(try await runner.run(executable: "svn", arguments: ["--non-interactive", "--no-auth-cache", "propset", "svn:ignore", resolved.after, "--", svnTargetPath(resolved.parent)], directory: binding.root), tool: "svn")
        await progress(RepositoryOperationProgress("已写入 SVN 忽略规则；尚未提交属性修改。", fractionCompleted: 1))
        return RepositoryIgnoreResult(summary: "已更新 \(resolved.parent == "." ? "根目录" : resolved.parent) 的 svn:ignore 属性，尚未提交。")
    }

    private func svnIgnoreResolvedRequest(_ request: RepositoryIgnoreRequest, binding: RepositoryBinding) async throws -> (parent: String, before: String, after: String, stateToken: String) {
        guard request.bindingID == binding.id, request.scope == .currentDirectory,
              request.candidate.scopes.contains(.currentDirectory), !svnIgnoreMetadataPath(request.candidate.path) else {
            throw VersionControlError.invalidRepository("待忽略文件已变化、已受跟踪，或不再可安全处理。")
        }
        let fingerprint = try await svnIgnoreFingerprint(path: request.candidate.path, root: binding.root)
        guard request.candidate.fingerprint == fingerprint else { throw VersionControlError.invalidRepository("待忽略文件已变化、已受跟踪，或不再可安全处理。") }
        let rule = try svnValidatedLiteralRule(request.rule)
        let parent = request.candidate.path.split(separator: "/").dropLast().joined(separator: "/")
        let parentPath = parent.isEmpty ? "." : parent
        // 明确要求父节点已受 SVN 管理，避免 propset 在未受管目录产生意外错误或隐式影响。
        _ = try requireSuccess(try await svn(["info", "--xml", "--", svnTargetPath(parentPath)], directory: binding.root), tool: "svn")
        let before = try await svnIgnoreValue(parent: parentPath, binding: binding)
        let after: String
        if before.split(whereSeparator: \.isNewline).map(String.init).contains(rule) { after = before }
        else if before.isEmpty || before.hasSuffix("\n") { after = before + rule + "\n" }
        else { after = before + "\n" + rule + "\n" }
        let token = CommitFileSnapshot.fingerprint(data: Data((request.candidate.fingerprint + "\u{0}" + parentPath + "\u{0}" + before + "\u{0}" + after).utf8))
        return (parentPath, before, after, token)
    }

    private func svnIgnoreValue(parent: String, binding: RepositoryBinding) async throws -> String {
        let result = try await runner.run(executable: "svn", arguments: ["--non-interactive", "--no-auth-cache", "propget", "--strict", "svn:ignore", "--", svnTargetPath(parent)], directory: binding.root)
        if result.exitCode == 1, result.error.contains("W200017") { return "" }
        let value = try requireSuccess(result, tool: "svn").output
        guard !value.contains("\0"), value.utf8.count <= 1_048_576 else {
            throw VersionControlError.unsupported("svn:ignore 属性过大或不是普通文本，RepHub 不会覆盖它。")
        }
        return value
    }

    private func svnIgnoreFingerprint(path: String, root: URL) async throws -> String {
        let url = try CommitFileSnapshot.validatedURL(root: root, path: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw VersionControlError.unsupported("符号链接不能作为 SVN 忽略规则目标。")
        }
        let state = try await svn(["status", "--xml", "--no-ignore", "--", svnTargetPath(path)], directory: root)
        let entries = try SVNXMLDocument(data: state.data).statusEntries
        guard entries.contains(where: { relativePath($0.path, root: root) == path && $0.item == "unversioned" }) else {
            throw VersionControlError.unsupported("路径已受管理或不再是未跟踪项，请重新读取忽略预览。")
        }
        return try CommitFileSnapshot.fingerprint(root: root, path: path)
    }

    private func svnValidatedLiteralRule(_ rule: String) throws -> String {
        let globCharacters = CharacterSet(charactersIn: "*?[]")
        guard !rule.isEmpty, rule == rule.trimmingCharacters(in: .whitespacesAndNewlines),
              !rule.contains("/"), !rule.contains("\\"), !rule.contains("\n"), !rule.contains("\r"), !rule.contains("\0"),
              rule.rangeOfCharacter(from: globCharacters) == nil else {
            throw VersionControlError.invalidData("SVN 忽略规则必须是当前文件夹中的字面名称，不能包含路径、通配符或换行。")
        }
        return rule
    }

    private func svnIgnoreMetadataPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { [".git", ".svn"].contains($0.lowercased()) }
    }
}
