import Foundation
import AICore
import VersionControlCore

/// 只通过 `RepositoryService` 读取已选差异，并将其收敛为可发送给 AI 的最小上下文。
/// 这里不接触适配器实现、工作副本绝对路径或远端地址。
public struct RepositoryAIContextService: Sendable {
    private static let maximumBytes = 256 * 1024
    private let service: RepositoryService

    public init(service: RepositoryService) {
        self.service = service
    }

    /// 为工作区中的选中文件建立上下文。读取结束后重新准备提交，避免把已变化的内容交给模型。
    public func workingCopy(in binding: RepositoryBinding, selectedPaths: Set<String>) async throws -> AIContext {
        let first = try await preparation(for: binding)
        let selected = try selectedFiles(from: first, paths: selectedPaths)
        let files = try await patches(for: selected, in: binding)
        try Task.checkCancellation()

        let verified = try await preparation(for: binding)
        try ensureUnchanged(before: first, after: verified, selectedPaths: selectedPaths)
        return try context(sourceLabel: "\(binding.providerName) · 工作区变更",
                           basis: basis(for: files, comparison: "基准版本 \(revisionLabel(first.baseRevision)) 与当前工作区比较。", suffix: "内容已在读取后复核。"),
                           files: files, identity: snapshotIdentity(scope: "working-copy", binding: binding,
                              baseRevision: first.baseRevision, selected: selected))
    }

    /// 为即将提交的选中文件建立上下文。传入的准备快照和文件指纹必须仍与当前工作区一致。
    public func commit(in preparation: RepositoryCommitPreparation, selectedPaths: Set<String>) async throws -> AIContext {
        let selected = try selectedFiles(from: preparation, paths: selectedPaths)
        let currentBeforeRead = try await self.preparation(for: preparation.binding)
        try ensureUnchanged(before: preparation, after: currentBeforeRead, selectedPaths: selectedPaths)
        let files = try await patches(for: selected, in: preparation.binding)
        try Task.checkCancellation()

        let currentAfterRead = try await self.preparation(for: preparation.binding)
        try ensureUnchanged(before: preparation, after: currentAfterRead, selectedPaths: selectedPaths)
        return try context(sourceLabel: "\(preparation.binding.providerName) · 待提交变更",
                           basis: basis(for: files, comparison: "基准版本 \(revisionLabel(preparation.baseRevision)) 与当前工作区比较。", suffix: "内容已在读取后复核，可用于生成提交说明。"),
                           files: files, identity: snapshotIdentity(scope: "commit", binding: preparation.binding,
                              baseRevision: preparation.baseRevision, selected: selected))
    }

    /// 为一条历史提交的选中文件建立上下文。只读取该 revision 明确列出的文件。
    public func revision(in binding: RepositoryBinding, revision: String, selectedPaths: Set<String>) async throws -> AIContext {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.failed("请选择一个有效的历史提交。")
        }
        try validate(paths: selectedPaths)
        try Task.checkCancellation()
        let changes = try await service.changedFiles(in: binding, revision: revision)
        let available = Set(changes.map(\.path))
        guard !selectedPaths.isEmpty else { throw AIError.failed("请至少选择一个文件后再运行 AI 场景。") }
        guard selectedPaths.isSubset(of: available) else {
            throw AIError.failed("所选文件不属于这条历史提交，请重新选择。")
        }

        var files: [AIInputFile] = []
        for path in selectedPaths.sorted() {
            try Task.checkCancellation()
            let patch = try await service.diff(in: binding, path: path, revision: revision)
            try append(path: path, patch: patch, to: &files)
        }
        return try context(sourceLabel: "\(binding.providerName) · 历史提交变更",
                           basis: basis(for: files, comparison: "历史提交 \(revision) 与其父版本比较。", suffix: "来自所选历史提交。"),
                           files: files, identity: snapshotIdentity(scope: "revision:\(revision)", binding: binding,
                              baseRevision: revision, selected: selectedPaths.sorted().map {
                                  RepositoryCommitFile(change: .init(path: $0, kind: .unknown), fingerprint: revision)
                              }))
    }

    private func preparation(for binding: RepositoryBinding) async throws -> RepositoryCommitPreparation {
        let workspace = Workspace(directory: binding.root, bindings: [binding], issues: [])
        let preparations = try await service.prepareCommits(in: workspace)
        guard let preparation = preparations.first(where: { $0.binding.id == binding.id }) else {
            throw AIError.failed("当前版本控制来源不能读取待提交文件。")
        }
        if let reason = preparation.blockingReason, !reason.isEmpty {
            throw AIError.failed("无法读取待提交内容：\(reason)")
        }
        return preparation
    }

    private func selectedFiles(from preparation: RepositoryCommitPreparation,
                               paths: Set<String>) throws -> [RepositoryCommitFile] {
        try validate(paths: paths)
        guard !paths.isEmpty else { throw AIError.failed("请至少选择一个文件后再运行 AI 场景。") }
        let filesByPath = Dictionary(uniqueKeysWithValues: preparation.files.map { ($0.change.path, $0) })
        guard paths.allSatisfy({ filesByPath[$0] != nil }) else {
            throw AIError.failed("所选文件已不在当前变更范围内，请刷新后重新选择。")
        }
        let selected = paths.sorted().compactMap { filesByPath[$0] }
        guard !selected.isEmpty else { throw AIError.failed("所选文件没有可读取的变更。") }
        return selected
    }

    private func patches(for files: [RepositoryCommitFile], in binding: RepositoryBinding) async throws -> [AIInputFile] {
        var result: [AIInputFile] = []
        for file in files {
            try Task.checkCancellation()
            let patch = try await service.commitDiff(in: binding, file: file)
            try append(path: file.change.path, patch: patch, to: &result)
        }
        return result
    }

    private func append(path: String, patch: RepositoryPatch, to files: inout [AIInputFile]) throws {
        guard !patch.isTruncated else { throw AIError.contextTooLarge }
        let text = normalizedText(from: patch.text)
        let input = AIInputFile(path: path, patch: text)
        let total = files.reduce(0) { $0 + $1.path.utf8.count + $1.patch.utf8.count }
            + input.path.utf8.count + input.patch.utf8.count
        guard total <= Self.maximumBytes else { throw AIError.contextTooLarge }
        files.append(input)
    }

    private func normalizedText(from patch: String) -> String {
        if patch.utf8.contains(0) || hasBinaryDiffMarker(in: patch) {
            return "[二进制文件：未提供可供审查的文本差异，不能据此判断代码内容。]"
        }
        if patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "[未读取到可供审查的文本差异。]"
        }
        return patch
    }

    private func hasBinaryDiffMarker(in patch: String) -> Bool {
        patch.split(whereSeparator: \.isNewline).contains { line in
            let text = String(line)
            return text == "GIT binary patch"
                || (text.hasPrefix("Binary files ") && text.hasSuffix(" differ"))
                || text.hasPrefix("Cannot display: file marked as a binary type.")
                || (text.hasPrefix("二进制文件，大小 ") && text.hasSuffix(" 字节。"))
        }
    }

    private func basis(for files: [AIInputFile], comparison: String, suffix: String) -> String {
        let unavailable = files.filter { $0.patch.hasPrefix("[") }.count
        if unavailable == files.count {
            return "\(comparison)已选择 \(files.count) 个文件，但没有可供审查的文本差异；每个文件均以明确状态标记提供。\(suffix)"
        }
        return "\(comparison)仅包含已选择的 \(files.count) 个文件差异。\(unavailable > 0 ? "其中 \(unavailable) 个文件没有可读文本差异。" : "")\(suffix)"
    }

    private func context(sourceLabel: String, basis: String, files: [AIInputFile], identity: String) throws -> AIContext {
        guard !files.isEmpty else { throw AIError.failed("没有可供 AI 分析的文件。") }
        let context = AIContext(sourceLabel: sourceLabel, basis: basis, files: files, identity: identity)
        guard context.byteCount <= Self.maximumBytes else { throw AIError.contextTooLarge }
        return context
    }

    private func ensureUnchanged(before: RepositoryCommitPreparation, after: RepositoryCommitPreparation,
                                 selectedPaths: Set<String>) throws {
        guard before.binding.id == after.binding.id, before.baseRevision == after.baseRevision else {
            throw AIError.failed("工作区基准已变化，请重新选择文件后再运行 AI 场景。")
        }
        let beforeFiles = Dictionary(uniqueKeysWithValues: before.files.map { ($0.change.path, $0) })
        let afterFiles = Dictionary(uniqueKeysWithValues: after.files.map { ($0.change.path, $0) })
        for path in selectedPaths {
            guard beforeFiles[path]?.fingerprint == afterFiles[path]?.fingerprint else {
                throw AIError.failed("所选文件在读取期间发生变化，请重新选择后再运行 AI 场景。")
            }
        }
    }

    private func revisionLabel(_ revision: String?) -> String {
        revision?.isEmpty == false ? revision! : "无父版本"
    }

    /// 路径、指纹和基准采用长度编码，避免拼接歧义；identity 只参与摘要，不进入模型提示词。
    private func snapshotIdentity(scope: String, binding: RepositoryBinding, baseRevision: String?,
                                  selected: [RepositoryCommitFile]) -> String {
        let entries = selected.sorted { $0.change.path < $1.change.path }.map {
            "\($0.change.path.utf8.count):\($0.change.path)\($0.fingerprint.utf8.count):\($0.fingerprint)"
        }
        let fields = [scope, binding.id, baseRevision ?? ""] + entries
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private func validate(paths: Set<String>) throws {
        for path in paths {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                  path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.split(separator: "/").contains(where: { [".git", ".svn"].contains($0.lowercased()) }) else {
                throw AIError.failed("所选文件路径无效，请重新选择。")
            }
        }
    }
}
