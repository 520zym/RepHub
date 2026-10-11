import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ToolExecution
import VersionControlCore

/// 通过 Subversion 命令行读取工作副本，并执行受限的更新操作；不保存认证信息。
public struct SVNProvider: RepositoryOperationProvider, RepositoryHistoryProvider {
    public let runner: CommandRunner
    private let tlsFallback: SVNAutomaticTLSFallback
    private let commandExecutor: @Sendable ([String], URL, URL?) async throws -> CommandResult

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
        self.tlsFallback = SVNAutomaticTLSFallback()
        self.commandExecutor = { arguments, directory, configuration in
            try await runner.run(
                executable: "svn",
                arguments: arguments,
                directory: directory,
                opensslConfiguration: configuration
            )
        }
    }

    init(
        runner: CommandRunner = CommandRunner(),
        tlsFallback: SVNAutomaticTLSFallback,
        commandExecutor: @escaping @Sendable ([String], URL, URL?) async throws -> CommandResult
    ) {
        self.runner = runner
        self.tlsFallback = tlsFallback
        self.commandExecutor = commandExecutor
    }

    public let id: ProviderID = .svn
    public let displayName = "Subversion"

    public func detect(at directory: URL) async throws -> RepositoryBinding? {
        let fileManager = FileManager.default
        var candidate = directory.standardizedFileURL

        while true {
            try Task.checkCancellation()
            let metadata = candidate.appendingPathComponent(".svn", isDirectory: true)
            if fileManager.fileExists(atPath: metadata.path) {
                let info = try await svn(["info", "--xml"], directory: candidate)
                let document = try SVNXMLDocument(data: info.data)
                guard let entry = document.infoEntry else {
                    throw VersionControlError.invalidData("svn info 未返回工作副本信息。")
                }

                let rootPath = entry.workingCopyRoot ?? candidate.path
                let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
                return RepositoryBinding(
                    providerID: id,
                    providerName: displayName,
                    root: root,
                    remoteURL: entry.url,
                    capabilities: [.status, .diff, .history, .update, .fileHistory, .synchronization]
                )
            }

            guard candidate.path != "/", !candidate.path.isEmpty else { break }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path.count >= candidate.path.count { break }
            candidate = parent
        }

        // 只有整条目录链都没有 .svn 时，才可确定它不是工作副本。
        return nil
    }

    public func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        let result = try await svn(["status", "--xml"], directory: binding.root)
        let document = try SVNXMLDocument(data: result.data)
        return document.statusEntries.map { entry in
            FileChange(path: relativePath(entry.path, root: binding.root), kind: statusKind(entry))
        }
    }

    public func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        guard limit > 0 else { return [] }
        var arguments = ["log", "--xml", "--limit", String(limit)]
        if let reference, !reference.isEmpty {
            arguments += ["-r", normalizedRevision(reference)]
        } else {
            // 工作副本默认只查询 BASE；显式范围可在尚未 update 时读取仓库最新修订。
            arguments += ["-r", "HEAD:1"]
        }
        let result = try await svn(arguments, directory: binding.root, remoteURL: binding.remoteURL)
        let document = try SVNXMLDocument(data: result.data)
        return document.logEntries.map { entry in
            Revision(
                id: "r\(entry.revision)",
                author: entry.author ?? "",
                date: parseDate(entry.date),
                message: entry.message ?? ""
            )
        }
    }

    public func branches(in binding: RepositoryBinding) async throws -> [BranchReference] {
        []
    }

    public func fileHistory(
        in binding: RepositoryBinding,
        path: String,
        limit: Int,
        reference: String?
    ) async throws -> [FileHistoryEntry] {
        guard limit > 0 else { return [] }
        let target = try repositoryFileURL(path: path, in: binding)
        let localTarget = binding.root.appendingPathComponent(normalizedRelativePath(path))
        if FileManager.default.fileExists(atPath: localTarget.path), try await isNotVersioned(path: path, in: binding) {
            throw VersionControlError.invalidRepository("文件未受 SVN 管理，无法读取单文件提交历史：\(path)")
        }
        let requestedPeg = normalizedRevision(reference ?? "HEAD")
        let range = "\(requestedPeg):1"
        let logEntries: [SVNXMLDocument.LogEntry]
        let effectivePeg: String
        do {
            let result = try await svn(
                ["log", "--xml", "-v", "--limit", String(limit), "-r", range, "\(target)@\(requestedPeg)"],
                directory: binding.root,
                remoteURL: binding.remoteURL
            )
            logEntries = try SVNXMLDocument(data: result.data).logEntries
            effectivePeg = requestedPeg
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isMissingSVNPath(error), let number = Int(requestedPeg), number > 1 else { throw error }
            // 当文件恰好在 rD 被删除时，URL@rD 不再能定位节点。先在父目录的 rD
            // 日志中确认该路径的删除，再从 rD-1 沿旧节点读取此前历史。
            let previous = String(number - 1)
            guard let deletion = try await deletionLogEntry(
                target: target,
                path: normalizedRelativePath(path),
                revision: requestedPeg,
                binding: binding
            ) else {
                throw error
            }
            let result = try await svn(
                ["log", "--xml", "-v", "--limit", String(limit), "-r", "\(previous):1", "\(target)@\(previous)"],
                directory: binding.root,
                remoteURL: binding.remoteURL
            )
            logEntries = [deletion] + (try SVNXMLDocument(data: result.data).logEntries)
            effectivePeg = previous
        }
        let fallbackPath = normalizedRelativePath(path)
        return Array(logEntries.prefix(limit)).map { entry in
            let revision = Revision(
                id: "r\(entry.revision)",
                author: entry.author ?? "",
                date: parseDate(entry.date),
                message: entry.message ?? ""
            )
            // 复制、改名甚至跨目录移动时，使用同一个查询锚点才能让 SVN 追溯到正确的历史路径。
            // 不能把 log 的仓库绝对路径伪装成当前 binding 下的相对路径。
            return FileHistoryEntry(revision: revision, path: fallbackPath, pegRevision: "r\(effectivePeg)")
        }
    }

    public func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch {
        let target = try repositoryFileURL(path: entry.path, in: binding)
        let revision = normalizedRevision(entry.revision.id)
        let peg = normalizedRevision(entry.pegRevision ?? entry.revision.id)
        let result = try await svn(
            ["diff", "-c", revision, "--", "\(target)@\(peg)"],
            directory: binding.root,
            remoteURL: binding.remoteURL
        )
        return RepositoryPatch(text: result.output)
    }

    public func synchronization(
        in binding: RepositoryBinding,
        revisions: [Revision],
        path: String?
    ) async throws -> RepositorySyncStatus {
        let target: String?
        if let path, !path.isEmpty {
            // svnversion 不解析 peg revision；带 @ 的文件名必须原样传递。
            target = path
        } else {
            target = nil
        }
        var command: [String] = []
        if let target { command.append(target) }
        // svnversion 是独立二进制，读取本地工作副本数据库，不访问远端。
        let result = try await runner.run(executable: "svnversion", arguments: command, directory: binding.root)
        _ = try requireSuccess(result, tool: "svnversion")
        let version = try parseWorkingCopyVersion(result.output, path: path)
        let revisionNumbers = revisions.compactMap { Int(normalizedRevision($0.id)) }
        let layout = try await synchronizationLayout(in: binding, path: path)

        guard !version.hasUncertainLayout, !layout.isUncertain else {
            let states = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, RevisionSyncState.uncertain) })
            let reason = layout.reason ?? "SVN 工作副本含切换或稀疏目录"
            return RepositorySyncStatus(
                incomingCount: nil,
                outgoingCount: nil,
                states: states,
                summary: "\(reason)，提交同步状态需核对。",
                detail: "当前范围为 \(version.description)。SVN 没有 Git 式“待推送”概念；此处不显示推送计数。"
            )
        }

        var states: [String: RevisionSyncState] = [:]
        for revision in revisions {
            guard let number = Int(normalizedRevision(revision.id)) else { continue }
            if version.minimum == version.maximum {
                states[revision.id] = number > version.maximum ? .incoming : .synchronized
            } else if number > version.maximum {
                states[revision.id] = .incoming
            } else if number <= version.minimum {
                states[revision.id] = .synchronized
            } else {
                states[revision.id] = .uncertain
            }
        }
        let incoming = revisionNumbers.filter { $0 > version.maximum }.count
        let uncertain = revisions.filter { states[$0.id] == .uncertain }.count
        let scope = path.map { "文件 \($0)" } ?? "工作副本"
        let summary: String
        let detail: String
        if version.minimum == version.maximum {
            summary = incoming == 0 ? "\(scope)已更新至 r\(version.maximum)。" : "当前显示范围内有 \(incoming) 个 SVN 提交待更新。"
            detail = "以 \(scope) 的实际 BASE r\(version.maximum) 判断；SVN 没有 Git 式“待推送”概念。"
        } else {
            summary = "\(scope)处于混合修订 r\(version.minimum):r\(version.maximum)，\(uncertain) 个提交需核对。"
            detail = "高于 r\(version.maximum) 的提交标为待更新，低于或等于 r\(version.minimum) 的提交可确认已更新，中间范围无法仅凭混合 BASE 判断。SVN 不显示待推送计数。"
        }
        return RepositorySyncStatus(incomingCount: incoming, outgoingCount: nil, states: states, summary: summary, detail: detail)
    }

    public func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] {
        guard !revision.isEmpty else {
            throw VersionControlError.invalidData("缺少 Subversion 修订号。")
        }
        let result = try await svn(
            ["log", "--xml", "-v", "-r", normalizedRevision(revision)],
            directory: binding.root,
            remoteURL: binding.remoteURL
        )
        let document = try SVNXMLDocument(data: result.data)
        let prefix = try await workingCopyRepositoryPath(in: binding)

        return document.logEntries.flatMap(\.changedPaths).compactMap { path in
            guard let relativePath = relativeRepositoryPath(path.path, removing: prefix) else { return nil }
            return FileChange(path: relativePath, kind: logKind(path.action))
        }
    }

    public func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        var arguments = ["diff"]
        if let revision, !revision.isEmpty {
            arguments += ["-c", normalizedRevision(revision)]
        }
        if let path, !path.isEmpty {
            if revision == nil, try await isUnversioned(path: path, in: binding) {
                return RepositoryPatch(text: "未跟踪文件尚未加入 Subversion，无法生成 SVN 差异。\n路径：\(path)")
            }
            arguments += ["--", svnTargetPath(path)]
        }
        // 本地工作区差异不访问远端，不能因旧 TLS 兼容设置而要求 OpenSSL 3。
        let remoteURL = revision == nil ? nil : binding.remoteURL
        let result = try await svn(arguments, directory: binding.root, remoteURL: remoteURL)
        var text = result.output
        if revision == nil, path == nil {
            let untracked = try await unversionedPaths(in: binding)
            if !untracked.isEmpty {
                text += "\n\n未跟踪文件（尚未加入 Subversion，未包含在差异中）：\n"
                text += untracked.map { "  \($0)" }.joined(separator: "\n")
            }
        }
        return RepositoryPatch(text: text)
    }

    public func perform(
        _ operation: RepositoryOperationKind,
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryOperationResult {
        guard operation == .update else {
            throw VersionControlError.unsupported("Subversion 不支持“\(operation.title)”操作，请直接使用“更新工作区”。")
        }

        await progress(RepositoryOperationProgress("检查 SVN 工作副本…"))
        try Task.checkCancellation()
        let before = try await status(in: binding)
        let existingConflicts = before.filter { $0.kind == .conflicted }
        guard existingConflicts.isEmpty else {
            return RepositoryOperationResult(
                kind: operation,
                bindingID: binding.id,
                outcome: .conflicts,
                summary: "工作副本已有冲突，未执行 SVN 更新。",
                details: "请先在其他工具或编辑器中处理现有冲突，再重新更新。",
                changedFiles: existingConflicts
            )
        }

        await progress(RepositoryOperationProgress("探测 SVN 连接…"))
        let tlsMode = try await probeUpdateTLSMode(in: binding)
        try Task.checkCancellation()

        await progress(RepositoryOperationProgress("更新 SVN 工作副本…"))
        // `svn update` 本身不支持 --xml；CommandRunner 固定英文 locale，下面只读取其稳定的状态列。
        let command = ["--non-interactive", "--no-auth-cache", "update", "--ignore-externals", "--accept", "postpone"]
        let updateResult = try await runUpdate(command, directory: binding.root, tlsMode: tlsMode)
        _ = try requireSuccess(updateResult, tool: "svn")
        try Task.checkCancellation()

        await progress(RepositoryOperationProgress("核对 SVN 工作副本状态…"))
        let after = try await status(in: binding)
        let updated = changedFiles(fromUpdateOutput: updateResult.output, binding: binding, afterStatus: after)
        let revision = try await workingCopyRevision(in: binding)
        let conflicts = after.filter { $0.kind == .conflicted }
        if !conflicts.isEmpty {
            return RepositoryOperationResult(
                kind: operation,
                bindingID: binding.id,
                outcome: .conflicts,
                summary: "SVN 更新完成，但产生了冲突。",
                details: "未自动解决、清理或回退任何文件。请处理冲突后再继续。",
                changedFiles: mergedChanges(updated, conflicts)
            )
        }

        return RepositoryOperationResult(
            kind: operation,
            bindingID: binding.id,
            outcome: .succeeded,
            summary: updated.isEmpty
                ? "SVN 工作副本已是最新状态（r\(revision)）。"
                : "SVN 更新完成至 r\(revision)，共变更 \(updated.count) 个路径。",
            changedFiles: updated
        )
    }

    private func svn(_ arguments: [String], directory: URL, remoteURL: String? = nil) async throws -> CommandResult {
        // --non-interactive 防止凭据提示阻塞 UI；不接受或绕过 TLS 证书错误。
        let command = ["--non-interactive", "--no-auth-cache"] + arguments
        let executor = commandExecutor
        let runner = runner
        let result = try await tlsFallback.execute(
            remoteURL: remoteURL,
            modern: { try await executor(command, directory, nil) },
            legacy: {
                try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
                return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                    try await executor(command, directory, configuration)
                }
            }
        )
        return try requireSuccess(result, tool: "svn")
    }

    /// `svn update` 是写操作：先以 `svn info` 只读探测 TLS 模式，再只执行一次更新命令。
    /// 禁止将 update 交给自动降级重试，避免一次失败后无感重复写入工作副本。
    private func probeUpdateTLSMode(in binding: RepositoryBinding) async throws -> SVNAutomaticTLSFallback.Mode {
        guard let remoteURL = binding.remoteURL, !remoteURL.isEmpty else {
            return .modern
        }
        let probeCommand = ["--non-interactive", "--no-auth-cache", "info", "--xml", remoteURL]
        let executor = commandExecutor
        let runner = runner
        let probe = try await tlsFallback.probe(
            remoteURL: remoteURL,
            modern: { try await executor(probeCommand, binding.root, nil) },
            legacy: {
                try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
                return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                    try await executor(probeCommand, binding.root, configuration)
                }
            }
        )
        _ = try requireSuccess(probe.result, tool: "svn")
        return probe.mode
    }

    private func runUpdate(_ arguments: [String], directory: URL, tlsMode: SVNAutomaticTLSFallback.Mode) async throws -> CommandResult {
        switch tlsMode {
        case .modern:
            return try await runner.run(executable: "svn", arguments: arguments, directory: directory, timeout: 120)
        case .legacyCompatible:
            try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
            return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                try await runner.run(
                    executable: "svn",
                    arguments: arguments,
                    directory: directory,
                    timeout: 120,
                    opensslConfiguration: configuration
                )
            }
        }
    }

    /// `svn update` 的英文输出前四列依次是内容、属性、锁和树冲突；第五列固定为空，之后是路径。
    /// 只接受存在至少一个状态标记的行，忽略 "Updating"、修订号和冲突摘要等说明文字。
    private func changedFiles(
        fromUpdateOutput output: String,
        binding: RepositoryBinding,
        afterStatus: [FileChange]
    ) -> [FileChange] {
        let statusByPath = Dictionary(uniqueKeysWithValues: afterStatus.map { ($0.path, $0) })
        var seen = Set<String>()
        return output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let entry = updateEntry(from: line) else { return nil }
            let path = updateRelativePath(entry.path, root: binding.root)
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            if let status = statusByPath[path] { return status }
            return FileChange(path: path, kind: entry.kind)
        }
    }

    private func updateEntry(from line: String) -> (path: String, kind: FileChangeKind)? {
        let bytes = Array(line.utf8)
        guard bytes.count > 5, bytes[4] == 0x20 else { return nil }
        let content = bytes[0]
        let properties = bytes[1]
        let treeConflict = bytes[3]
        let recognized: Set<UInt8> = [0x20, 0x41, 0x44, 0x55, 0x43, 0x47, 0x45, 0x52]
        guard recognized.contains(content), recognized.contains(properties),
              treeConflict == 0x20 || treeConflict == 0x43,
              content != 0x20 || properties != 0x20 || treeConflict != 0x20 else { return nil }

        let path = String(decoding: bytes.dropFirst(5), as: UTF8.self)
        let kind: FileChangeKind
        if content == 0x43 || treeConflict == 0x43 { kind = .conflicted }
        else if content == 0x41 { kind = .added }
        else if content == 0x44 { kind = .deleted }
        else if content == 0x52 { kind = .renamed }
        else { kind = .modified }
        return (path, kind)
    }

    private func updateRelativePath(_ path: String, root: URL) -> String {
        if path.hasPrefix("/") { return relativePath(path, root: root) }
        return path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }

    private func mergedChanges(_ first: [FileChange], _ second: [FileChange]) -> [FileChange] {
        var paths = Set<String>()
        return (first + second).filter { paths.insert($0.path).inserted }
    }

    private func workingCopyRepositoryPath(in binding: RepositoryBinding) async throws -> String {
        let result = try await svn(["info", "--xml"], directory: binding.root)
        let document = try SVNXMLDocument(data: result.data)
        guard let entry = document.infoEntry, let url = entry.url, let repositoryRoot = entry.repositoryRoot,
              let fullURL = URL(string: url), let rootURL = URL(string: repositoryRoot) else {
            throw VersionControlError.invalidData("svn info 缺少仓库 URL。")
        }
        let full = decodedURLPath(fullURL)
        let root = decodedURLPath(rootURL)
        guard full == root || full.hasPrefix(root + "/") else {
            throw VersionControlError.invalidData("svn info 返回的仓库 URL 不一致。")
        }
        return String(full.dropFirst(root.count))
    }

    private func workingCopyRevision(in binding: RepositoryBinding) async throws -> String {
        let result = try await svn(["info", "--xml"], directory: binding.root)
        let document = try SVNXMLDocument(data: result.data)
        guard let revision = document.infoEntry?.revision, !revision.isEmpty else {
            throw VersionControlError.invalidData("svn info 未返回本地工作副本修订号。")
        }
        return revision
    }

    private func repositoryFileURL(path: String, in binding: RepositoryBinding) throws -> String {
        guard let remoteURL = binding.remoteURL, !remoteURL.isEmpty,
              var components = URLComponents(string: remoteURL) else {
            throw VersionControlError.invalidRepository("SVN 工作副本缺少仓库 URL，无法读取单文件历史。")
        }
        let relative = normalizedRelativePath(path)
        let segments = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !relative.isEmpty, !segments.contains("..") else {
            throw VersionControlError.invalidData("文件路径无效：\(path)")
        }
        let encoded = segments
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        components.percentEncodedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? "/\(encoded)" : components.percentEncodedPath + "/\(encoded)"
        guard let url = components.url else {
            throw VersionControlError.invalidData("无法构造 SVN 文件 URL。")
        }
        return url.absoluteString
    }

    private func normalizedRelativePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func parseWorkingCopyVersion(_ output: String, path: String?) throws -> WorkingCopyVersion {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try NSRegularExpression(pattern: #"^([0-9]+)(?::([0-9]+))?([A-Za-z]*)$"#)
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let minimum = Int((value as NSString).substring(with: match.range(at: 1))) else {
            let scope = path.map { "文件 \($0)" } ?? "工作副本"
            throw VersionControlError.invalidRepository("\(scope)未受 SVN 管理或无法读取 BASE 修订号。")
        }
        let maximum = match.range(at: 2).location == NSNotFound
            ? minimum
            : Int((value as NSString).substring(with: match.range(at: 2))) ?? minimum
        return WorkingCopyVersion(
            minimum: minimum,
            maximum: maximum,
            flags: (value as NSString).substring(with: match.range(at: 3))
        )
    }

    private func synchronizationLayout(in binding: RepositoryBinding, path: String?) async throws -> SynchronizationLayout {
        var arguments = ["info", "--xml", "--depth", "empty"]
        if let path, !path.isEmpty { arguments += ["--", svnTargetPath(path)] }
        let result = try await svn(arguments, directory: binding.root)
        let document = try SVNXMLDocument(data: result.data)
        guard let entry = document.infoEntry, let actualURL = entry.url else {
            throw VersionControlError.invalidData("svn info 未返回工作副本 URL。")
        }
        let expectedURL: String
        if let path, !path.isEmpty {
            expectedURL = try repositoryFileURL(path: path, in: binding)
        } else if let remoteURL = binding.remoteURL {
            expectedURL = remoteURL
        } else {
            return SynchronizationLayout(isUncertain: true, reason: "SVN 工作副本缺少远端 URL")
        }
        guard normalizedRepositoryURL(actualURL) == normalizedRepositoryURL(expectedURL) else {
            return SynchronizationLayout(isUncertain: true, reason: "所选文件已切换到其他 SVN URL")
        }
        if path == nil || path?.isEmpty == true,
           let depth = entry.depth, depth != "infinity" {
            return SynchronizationLayout(isUncertain: true, reason: "SVN 工作副本使用稀疏检出（depth: \(depth)）")
        }
        return SynchronizationLayout(isUncertain: false, reason: nil)
    }

    private func deletionLogEntry(
        target: String,
        path: String,
        revision: String,
        binding: RepositoryBinding
    ) async throws -> SVNXMLDocument.LogEntry? {
        guard let url = URL(string: target) else { return nil }
        let parent = url.deletingLastPathComponent().absoluteString
        let result = try await svn(
            ["log", "--xml", "-v", "-r", revision, "\(parent)@\(revision)"],
            directory: binding.root,
            remoteURL: binding.remoteURL
        )
        let expected = try await repositoryHistoryPath(path, in: binding)
        return try SVNXMLDocument(data: result.data).logEntries.first { entry in
            entry.changedPaths.contains { $0.action == "D" && $0.path == expected }
        }
    }

    private func repositoryHistoryPath(_ path: String, in binding: RepositoryBinding) async throws -> String {
        let prefix = try await workingCopyRepositoryPath(in: binding)
        let prefixPath = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative = normalizedRelativePath(path)
        return "/" + ([prefixPath, relative].filter { !$0.isEmpty }.joined(separator: "/"))
    }

    private func isMissingSVNPath(_ error: Error) -> Bool {
        guard case let VersionControlError.executionFailed(detail) = error else { return false }
        return detail.contains("E160013")
    }

    private func normalizedRepositoryURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func relativePath(_ path: String, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        guard absolute == rootPath || absolute.hasPrefix(rootPath + "/") else { return path }
        return String(absolute.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func relativeRepositoryPath(_ path: String, removing prefix: String) -> String? {
        // XMLParser 已将 XML 实体还原；svn log 的路径不是 URL，不可再次 percent decode。
        let normalized = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPrefix = "/" + prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPrefix == "/" {
            return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard normalized == normalizedPrefix || normalized.hasPrefix(normalizedPrefix + "/") else { return nil }
        return String(normalized.dropFirst(normalizedPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func statusKind(_ entry: SVNXMLDocument.StatusEntry) -> FileChangeKind {
        statusKind(item: entry.item, properties: entry.properties, treeConflicted: entry.treeConflicted)
    }

    private func statusKind(item: String, properties: String, treeConflicted: Bool) -> FileChangeKind {
        if treeConflicted || item == "conflicted" { return .conflicted }
        if properties == "conflicted" { return .conflicted }
        if properties == "modified" { return .modified }
        return switch item {
        case "added", "replaced": .added
        case "modified": .modified
        case "deleted", "missing": .deleted
        case "unversioned", "ignored": .untracked
        case "conflicted", "obstructed", "incomplete": .conflicted
        default: .unknown
        }
    }

    private func logKind(_ action: String) -> FileChangeKind {
        switch action {
        case "A": .added
        case "M": .modified
        case "D": .deleted
        case "R": .renamed
        default: .unknown
        }
    }

    private func parseDate(_ value: String?) -> Date {
        guard let value else { return .distantPast }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? .distantPast
    }

    private func decodedURLPath(_ url: URL) -> String {
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return encodedPath.removingPercentEncoding ?? encodedPath
    }

    private func normalizedRevision(_ revision: String) -> String {
        revision.hasPrefix("r") || revision.hasPrefix("R") ? String(revision.dropFirst()) : revision
    }

    private func svnPathArgument(_ path: String) -> String {
        // 结尾 @ 表示没有 peg revision；仅含 @ 的路径需要它，普通路径追加会变成另一个文件名。
        path + "@"
    }

    private func svnTargetPath(_ path: String) -> String {
        path.contains("@") ? svnPathArgument(path) : path
    }

    private func isUnversioned(path: String, in binding: RepositoryBinding) async throws -> Bool {
        let result = try await svn(["status", "--xml", "--", svnTargetPath(path)], directory: binding.root)
        let document = try SVNXMLDocument(data: result.data)
        return document.statusEntries.contains { $0.item == "unversioned" }
    }

    private func isNotVersioned(path: String, in binding: RepositoryBinding) async throws -> Bool {
        let result = try await svn(["status", "--xml", "--", svnTargetPath(path)], directory: binding.root)
        let document = try SVNXMLDocument(data: result.data)
        return document.statusEntries.contains { $0.item == "unversioned" || $0.item == "ignored" }
    }

    private func unversionedPaths(in binding: RepositoryBinding) async throws -> [String] {
        let result = try await svn(["status", "--xml"], directory: binding.root)
        let document = try SVNXMLDocument(data: result.data)
        return document.statusEntries
            .filter { $0.item == "unversioned" }
            .map { relativePath($0.path, root: binding.root) }
    }
}

private struct WorkingCopyVersion {
    let minimum: Int
    let maximum: Int
    let flags: String

    var hasUncertainLayout: Bool { flags.contains("S") || flags.contains("P") }
    var description: String {
        let range = minimum == maximum ? "r\(minimum)" : "r\(minimum):r\(maximum)"
        return range + flags
    }
}

private struct SynchronizationLayout {
    let isUncertain: Bool
    let reason: String?
}

private final class SVNXMLDocument: NSObject, XMLParserDelegate {
    struct InfoEntry {
        var url: String?
        var repositoryRoot: String?
        var workingCopyRoot: String?
        var revision: String?
        var depth: String?
    }

    struct StatusEntry {
        let path: String
        var item = ""
        var properties = ""
        var treeConflicted = false
    }

    struct ChangedPath {
        let path: String
        let action: String
    }

    struct LogEntry {
        var revision = ""
        var author: String?
        var date: String?
        var message: String?
        var changedPaths: [ChangedPath] = []
    }

    private(set) var infoEntry: InfoEntry?
    private(set) var statusEntries: [StatusEntry] = []
    private(set) var logEntries: [LogEntry] = []
    private var currentStatus: StatusEntry?
    private var currentLog: LogEntry?
    private var currentPathAction: String?
    private var elementStack: [String] = []
    private var text = ""

    init(data: Data) throws {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw VersionControlError.invalidData(parser.parserError?.localizedDescription ?? "svn XML 无法解析。")
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        text = ""
        switch elementName {
        case "entry" where elementStack.contains("info"):
            infoEntry = InfoEntry(revision: attributeDict["revision"])
        case "entry" where elementStack.contains("status"):
            if let path = attributeDict["path"] { currentStatus = StatusEntry(path: path) }
        case "wc-status":
            currentStatus?.item = attributeDict["item"] ?? ""
            currentStatus?.properties = attributeDict["props"] ?? ""
            currentStatus?.treeConflicted = ["true", "yes"].contains(attributeDict["tree-conflicted"]?.lowercased())
        case "logentry":
            currentLog = LogEntry(revision: attributeDict["revision"] ?? "")
        case "path" where currentLog != nil:
            currentPathAction = attributeDict["action"] ?? ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "url", currentLog == nil { infoEntry?.url = value }
        if elementName == "root", currentLog == nil { infoEntry?.repositoryRoot = value }
        if elementName == "wcroot-abspath" { infoEntry?.workingCopyRoot = value }
        if elementName == "depth", currentLog == nil { infoEntry?.depth = value }
        if elementName == "author" { currentLog?.author = value }
        if elementName == "date" { currentLog?.date = value }
        if elementName == "msg" { currentLog?.message = value }
        if elementName == "path", let action = currentPathAction {
            currentLog?.changedPaths.append(ChangedPath(path: value, action: action))
            currentPathAction = nil
        }
        if elementName == "entry", let status = currentStatus {
            statusEntries.append(status)
            currentStatus = nil
        }
        if elementName == "logentry", let log = currentLog {
            logEntries.append(log)
            currentLog = nil
        }
        _ = elementStack.popLast()
        text = ""
    }
}
