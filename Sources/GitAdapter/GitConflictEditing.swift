import CryptoKit
import Foundation
import ToolExecution
import VersionControlCore

extension GitProvider: RepositoryConflictEditingProvider {
    public func contentConflict(in binding: RepositoryBinding, path: String) async throws -> RepositoryContentConflict {
        try ensureGit(binding)
        let safePath = try conflictPath(path, in: binding)
        let stages = try await conflictStages(path: safePath, in: binding)
        let working = try conflictText(at: try CommitFileSnapshot.validatedURL(root: binding.root, path: safePath))
        return RepositoryContentConflict(
            binding: binding,
            path: safePath,
            stateToken: try await conflictToken(path: safePath, stages: stages, working: working, in: binding),
            base: stages.base,
            local: stages.local,
            incoming: stages.incoming,
            working: working
        )
    }

    public func resolveContentConflict(_ request: RepositoryConflictResolutionRequest,
                                       in binding: RepositoryBinding) async throws -> RepositoryConflictResolutionResult {
        try ensureGit(binding)
        let path = try conflictPath(request.path, in: binding)
        try validateResolvedText(request.content)
        try await ensureSafeIndexOperation([path], root: binding.root)
        let stages = try await conflictStages(path: path, in: binding)
        let url = try CommitFileSnapshot.validatedURL(root: binding.root, path: path)
        let working = try conflictText(at: url)
        guard request.stateToken == (try await conflictToken(path: path, stages: stages, working: working, in: binding)) else {
            return RepositoryConflictResolutionResult(outcome: .failed, summary: "冲突文件或索引已变化，请重新打开后再保存。")
        }
        try Task.checkCancellation()
        try Data(request.content.utf8).write(to: url, options: .atomic)
        do {
            try Task.checkCancellation()
            _ = try requireSuccess(try await git(["--literal-pathspecs", "add", "--", path], in: binding.root), tool: "git")
            let after = try await status(in: binding)
            guard !after.contains(where: { $0.path == path && $0.kind == .conflicted }) else {
                return RepositoryConflictResolutionResult(outcome: .unknown,
                                                          summary: "已写入最终内容，但 Git 仍报告该文件冲突。",
                                                          details: "请刷新并在其他工具中核对索引状态。")
            }
            return RepositoryConflictResolutionResult(outcome: .succeeded,
                                                      summary: "已保存最终内容并标记 Git 冲突为已解决。")
        } catch is CancellationError {
            return RepositoryConflictResolutionResult(outcome: .unknown,
                                                      summary: "最终内容可能已写入，但冲突状态尚未确认。",
                                                      details: "请刷新工作区，确认该文件是否仍处于冲突状态。")
        } catch {
            return RepositoryConflictResolutionResult(outcome: .unknown,
                                                      summary: "最终内容已写入，但未能确认 Git 冲突状态。",
                                                      details: RepositoryDisplaySanitizer.redact(error.localizedDescription))
        }
    }
}

private extension GitProvider {
    struct ConflictStages {
        let base: String
        let local: String
        let incoming: String
        let signature: Data
    }

    func conflictPath(_ value: String, in binding: RepositoryBinding) throws -> String {
        guard !value.isEmpty, !value.contains("\0") else {
            throw VersionControlError.invalidRepository("冲突文件路径无效。")
        }
        let url = try CommitFileSnapshot.validatedURL(root: binding.root, path: value)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw VersionControlError.unsupported("符号链接、目录或特殊文件不能在 RepHub 中处理冲突。")
        }
        return value
    }

    func conflictStages(path: String, in binding: RepositoryBinding) async throws -> ConflictStages {
        let result = try requireSuccess(try await git(["--literal-pathspecs", "ls-files", "-u", "-z", "--", path], in: binding.root), tool: "git")
        var objects: [Int: (mode: String, object: String)] = [:]
        for record in result.data.split(separator: 0, omittingEmptySubsequences: true) {
            let text = String(decoding: record, as: UTF8.self)
            guard let tab = text.firstIndex(of: "\t") else { continue }
            let fields = text[..<tab].split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]), (1...3).contains(stage) else { continue }
            objects[stage] = (String(fields[0]), String(fields[1]))
        }
        guard let base = objects[1], let local = objects[2], let incoming = objects[3] else {
            throw VersionControlError.unsupported("该 Git 冲突没有完整的基准、本地和传入版本，不能安全地在 RepHub 中编辑。")
        }
        for entry in [base, local, incoming] {
            guard entry.mode == "100644" || entry.mode == "100755" else {
                throw VersionControlError.unsupported("二进制、符号链接、子模块或树冲突不能在 RepHub 中处理。")
            }
        }
        let texts = try await [1, 2, 3].asyncMap { stage in
            try await self.conflictBlob(stage: stage, path: path, in: binding)
        }
        var signature = result.data
        signature.append(Data(path.utf8))
        return ConflictStages(base: texts[0], local: texts[1], incoming: texts[2], signature: signature)
    }

    func conflictBlob(stage: Int, path: String, in binding: RepositoryBinding) async throws -> String {
        let result = try requireSuccess(try await git(["show", "--no-textconv", ":\(stage):\(path)"], in: binding.root), tool: "git")
        return try conflictText(data: result.data)
    }

    func conflictText(at url: URL) throws -> String {
        try conflictText(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    func conflictText(data: Data) throws -> String {
        guard data.count <= 4 * 1024 * 1024, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw VersionControlError.unsupported("该冲突文件不是 4 MiB 以内的 UTF-8 文本，不能在 RepHub 中处理。")
        }
        return text
    }

    func validateResolvedText(_ text: String) throws {
        guard !RepositoryConflictTextResolver.containsMarkers(in: text) else {
            throw VersionControlError.invalidData("最终内容仍含冲突标记，请处理完所有冲突块后再保存。")
        }
        guard text.utf8.count <= 4 * 1024 * 1024, !text.contains("\0") else {
            throw VersionControlError.invalidData("最终文本必须是 4 MiB 以内且不含空字符的 UTF-8 内容。")
        }
    }

    func conflictToken(path: String, stages: ConflictStages, working: String, in binding: RepositoryBinding) async throws -> String {
        var data = stages.signature
        data.append(Data("\u{0}\(working)\u{0}".utf8))
        let status = try requireSuccess(try await git(["--literal-pathspecs", "status", "--porcelain=v1", "-z", "--", path], in: binding.root), tool: "git")
        data.append(status.data)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Array {
    func asyncMap<T: Sendable>(_ transform: @escaping (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
