import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
import ToolExecution
import VersionControlCore

/// 通过 Subversion 命令行读取工作副本，并执行受限的更新、远端浏览和检出操作。
/// 用户输入的认证信息只保留在当前进程内存中，不写入 SVN 认证缓存。
public struct SVNProvider: RepositoryOperationProvider, RepositoryHistoryPagingProvider, RepositoryAcquisitionProvider, RepositoryCommitProvider, RepositorySetupProvider, RepositoryManagementProvider, RepositoryComparisonProvider, RepositoryMigrationSourceProvider, RepositoryWorkingCopyMigrationSourceProvider {
    public let runner: CommandRunner
    let shelfStorageDirectory: URL?
    private let tlsFallback: SVNAutomaticTLSFallback
    private let commandExecutor: @Sendable ([String], URL, URL?) async throws -> CommandResult
    private let migrationMetadataExecutor: @Sendable ([String], URL, URL?) async throws -> CommandResult
    private let credentials = SVNSessionCredentialStore()

    public init(runner: CommandRunner = CommandRunner(), shelfStorageDirectory: URL? = nil) {
        self.shelfStorageDirectory = shelfStorageDirectory
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
        self.migrationMetadataExecutor = { arguments, directory, configuration in
            try await runner.run(executable: "svn", arguments: arguments, directory: directory,
                                 timeout: SVNMigrationMetadataRead.timeout, opensslConfiguration: configuration)
        }
    }

    init(
        runner: CommandRunner = CommandRunner(),
        tlsFallback: SVNAutomaticTLSFallback,
        commandExecutor: @escaping @Sendable ([String], URL, URL?) async throws -> CommandResult
    ) {
        self.runner = runner
        self.shelfStorageDirectory = nil
        self.tlsFallback = tlsFallback
        self.commandExecutor = commandExecutor
        self.migrationMetadataExecutor = commandExecutor
    }

    public let id: ProviderID = .svn
    public let displayName = "Subversion"
    public let acquisitionOption = RepositoryAcquisitionOption(
        providerID: .svn,
        title: "SVN",
        actionTitle: "检出",
        supportsBrowsing: true,
        supportsCredentials: true
    )
    public let setupOption = RepositorySetupOption(providerID: .svn, title: "SVN", requiresRemote: true)

    public func browseRemote(_ location: RemoteRepositoryLocation) async throws -> RemoteDirectoryListing {
        let address = try normalizedRemoteAddress(location.url)
        try await rememberCredentials(location.credentials, for: address)
        let command = ["list", "--xml", svnRemoteTarget(address)]
        let result = try await runRemoteRead(command, remoteURL: address)
        let document = try SVNXMLDocument(data: result.data)
        let entries = try document.listEntries.map { entry in
            let childURL = try remoteChildURL(parent: address, name: entry.name)
            return RemoteDirectoryEntry(
                name: entry.name,
                url: childURL,
                isDirectory: entry.isDirectory,
                latestRevision: entry.revision,
                latestDate: optionalDate(entry.date),
                latestAuthor: entry.author
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return RemoteDirectoryListing(url: address, entries: entries)
    }

    public func acquire(
        _ location: RemoteRepositoryLocation,
        to destination: URL,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws {
        let address = try normalizedRemoteAddress(location.url)
        try await rememberCredentials(location.credentials, for: address)
        let destination = destination.standardizedFileURL
        let fileManager = FileManager.default
        let isDestinationLink = (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil
        guard !fileManager.fileExists(atPath: destination.path), !isDestinationLink else {
            throw VersionControlError.invalidRepository("检出目标已存在：\(destination.path)")
        }
        var parentIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw VersionControlError.invalidRepository("检出目标的父目录不存在：\(destination.deletingLastPathComponent().path)")
        }

        await progress(RepositoryOperationProgress("检查 SVN 目录…"))
        // 这里先只读探测 TLS 模式，随后 checkout 仅执行一次，避免自动兼容重放写操作。
        let tlsMode = try await probeRemoteTLSMode(address)
        try Task.checkCancellation()

        await progress(RepositoryOperationProgress("检出 SVN 工作副本…", detail: "等待 SVN 返回已处理的文件…"))
        let command = ["--non-interactive", "--no-auth-cache", "checkout", "--ignore-externals", svnRemoteTarget(address), destination.path]
        let reporter = SVNTransferProgressReporter(root: destination, operationName: "正在检出 SVN…", progress: progress)
        let output: CommandOutputHandler = { lines in
            await reporter.receive(lines: lines.compactMap { $0.stream == .stdout ? $0.text : nil })
        }
        let result: CommandResult
        do {
            result = try await runRemoteWrite(command, remoteURL: address, tlsMode: tlsMode, timeout: 600, onOutput: output)
            await reporter.finish()
        } catch {
            await reporter.finish()
            throw error
        }
        _ = try requireSuccess(result, tool: "svn")
        try Task.checkCancellation()
        await progress(RepositoryOperationProgress("SVN 检出完成。"))
    }

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
                    capabilities: [.status, .diff, .history, .update, .fileHistory, .synchronization, .commit, .conflictResolution, .revisionComparison]
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

    /// SVN 的修订号在整个仓库内单调递增，但某个目录可能跳过许多修订。分页游标因此保存
    /// 下一次查询的数值下界，而不是把 `offset` 交给 SVN；这样新增的 HEAD 不会插入旧分页。
    public func historyPage(
        in binding: RepositoryBinding,
        request: HistoryPageRequest
    ) async throws -> RepositoryHistoryPage {
        let limit = try historyPageLimit(request.limit)
        let state: SVNHistoryCursor
        if let rawCursor = request.cursor, !rawCursor.isEmpty {
            state = try decodeHistoryCursor(rawCursor, binding: binding, path: nil, reference: request.reference)
        } else {
            let requested = try await resolvedPagingRevision(request.reference, in: binding)
            // 新建但尚未产生任何修订的仓库是合法状态（HEAD=r0），不能构造 `0:1` 倒序范围。
            guard requested != "0" else { return RepositoryHistoryPage(revisions: []) }
            let target = try repositoryHistoryTarget(in: binding, pegRevision: requested)
            let entries = try await svnLogEntries(
                arguments: ["log", "--xml", "--limit", "1", "-r", "\(requested):1", target],
                in: binding
            )
            guard let first = entries.first, let top = Int(first.revision), top > 0 else {
                return RepositoryHistoryPage(revisions: [])
            }
            // URL 的 peg、查询上界和调用方原始引用都固定在游标中；续页绝不重新解析 HEAD。
            state = SVNHistoryCursor(
                bindingID: binding.id, path: nil, reference: requested,
                requestScope: historyRequestScope(request.reference), pegRevision: requested, nextRevision: top
            )
        }

        let target = try repositoryHistoryTarget(in: binding, pegRevision: state.pegRevision)
        let entries = try await svnLogEntries(
            arguments: ["log", "--xml", "--limit", String(limit + 1), "-r", "\(state.nextRevision):1", target],
            in: binding
        )
        let pageEntries = Array(entries.prefix(limit))
        let revisions = pageEntries.map { revision(from: $0) }
        let nextCursor = entries.count > limit
            ? try makeNextHistoryCursor(from: pageEntries, state: state)
            : nil
        return RepositoryHistoryPage(revisions: revisions, nextCursor: nextCursor)
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

    public func fileHistoryPage(
        in binding: RepositoryBinding,
        path: String,
        request: HistoryPageRequest
    ) async throws -> FileHistoryPage {
        let limit = try historyPageLimit(request.limit)
        let normalizedPath = normalizedRelativePath(path)
        let target = try repositoryFileURL(path: normalizedPath, in: binding)
        let localTarget = binding.root.appendingPathComponent(normalizedPath)
        if FileManager.default.fileExists(atPath: localTarget.path), try await isNotVersioned(path: normalizedPath, in: binding) {
            throw VersionControlError.invalidRepository("文件未受 SVN 管理，无法读取单文件提交历史：\(normalizedPath)")
        }

        let state: SVNHistoryCursor
        let initialDeletion: SVNXMLDocument.LogEntry?
        if let rawCursor = request.cursor, !rawCursor.isEmpty {
            state = try decodeHistoryCursor(rawCursor, binding: binding, path: normalizedPath, reference: request.reference)
            initialDeletion = nil
        } else {
            let requestedPeg = try await resolvedPagingRevision(request.reference, in: binding)
            // 还没有任何修订时文件不可能存在；直接返回空页，避免把 r0 交给 svn log。
            guard requestedPeg != "0" else { return FileHistoryPage(entries: []) }
            do {
                _ = try await svnLogEntries(
                    arguments: ["log", "--xml", "--limit", "1", "-r", "\(requestedPeg):1", "\(target)@\(requestedPeg)"],
                    in: binding
                )
                state = SVNHistoryCursor(
                    bindingID: binding.id, path: normalizedPath, reference: requestedPeg,
                    requestScope: historyRequestScope(request.reference), pegRevision: requestedPeg,
                    nextRevision: Int(requestedPeg) ?? 0
                )
                initialDeletion = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isMissingSVNPath(error), let number = Int(requestedPeg), number > 1,
                      let deletion = try await deletionLogEntry(
                        target: target, path: normalizedPath, revision: requestedPeg, binding: binding
                      ) else {
                    throw error
                }
                state = SVNHistoryCursor(
                    bindingID: binding.id, path: normalizedPath, reference: requestedPeg,
                    requestScope: historyRequestScope(request.reference), pegRevision: String(number - 1),
                    nextRevision: number - 1
                )
                initialDeletion = deletion
            }
        }

        let logEntries = try await svnLogEntries(
            arguments: [
                "log", "--xml", "-v", "--limit", String(limit + 1),
                "-r", "\(state.nextRevision):1", "\(target)@\(state.pegRevision)"
            ],
            in: binding
        )
        // 删除修订只属于首屏；后续页固定使用删除前的 peg，才能继续沿复制/改名链追溯。
        let entries = (initialDeletion.map { [$0] } ?? []) + logEntries
        let pageEntries = Array(entries.prefix(limit))
        let fileEntries = pageEntries.map { entry in
            FileHistoryEntry(
                revision: revision(from: entry), path: normalizedPath,
                pegRevision: "r\(state.pegRevision)"
            )
        }
        // `logEntries` 比页面多取一条；首屏存在删除记录时，仍需保证删除记录占用一个位置。
        let hasMore = entries.count > limit
        let nextCursor = hasMore
            ? try makeNextHistoryCursor(from: pageEntries, state: state)
            : nil
        return FileHistoryPage(entries: fileEntries, nextCursor: nextCursor)
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
        // 混合工作副本中 rMax 不能仅按范围推断：它可能刚由当前工作副本提交，
        // 也可能只是别的节点的 BASE。只为这个一个候选修订按实际变更路径读取
        // 本地 BASE；不能证明时仍保持“需核对”。
        if version.minimum != version.maximum, path == nil,
           let maximumRevision = revisions.first(where: { Int(normalizedRevision($0.id)) == version.maximum }),
           await maximumRevisionIsPresentLocally(maximumRevision.id, in: binding) {
            states[maximumRevision.id] = .synchronized
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

    public func prepareCommit(in binding: RepositoryBinding) async throws -> RepositoryCommitPreparation {
        let baseRevision = try await workingCopyRevision(in: binding)
        let changes = try await expandedCommitChanges(in: binding)
        var files: [RepositoryCommitFile] = []
        for change in changes {
            files.append(try await commitFile(change: change, in: binding))
        }
        let restricted = files.filter { $0.restriction != nil }.count
        let directoryCount = files.filter(\.isDirectory).count
        let noticeParts = [
            restricted == 0
                ? "已按当前工作副本状态生成提交预览。"
                : "其中 \(restricted) 个路径不能安全地按单文件范围提交。",
            directoryCount > 0 ? "目录勾选仅提交自身，子项须单独选择。" : nil
        ].compactMap { $0 }
        return RepositoryCommitPreparation(
            binding: binding,
            baseRevision: baseRevision,
            files: files,
            notice: noticeParts.joined(separator: " "),
            blockingReason: nil
        )
    }

    private func expandedCommitChanges(in binding: RepositoryBinding) async throws -> [FileChange] {
        let initial = try await status(in: binding)
        var result: [FileChange] = []
        for change in initial {
            if change.path.split(separator: "/").contains(where: { $0.lowercased() == ".svn" || $0.lowercased() == ".git" }) {
                continue
            }
            guard change.kind == .untracked else {
                result.append(change)
                continue
            }
            let url = binding.root.appendingPathComponent(change.path)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                result.append(change)
                continue
            }
            var directory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
                result.append(change)
                continue
            }
            // 保留目录节点：`svn add --depth empty` 与随后的同深度提交只会带入这个
            // 节点本身，因而空目录可以提交；非空目录也可明确选择“只加入目录”。
            // 同时列出叶子文件，供用户选择实际文件，而不会把整棵目录递归交给 svn。
            result.append(change)
            result.append(contentsOf: try untrackedDescendants(in: url, root: binding.root))
        }
        var paths = Set<String>()
        return result.filter { paths.insert($0.path).inserted }
    }

    private func untrackedDescendants(in directory: URL, root: URL) throws -> [FileChange] {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return [FileChange(path: relativePath(directory.path, root: root), kind: .untracked)]
        }
        let properties: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(properties),
            options: [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { return [] }
        var files: [FileChange] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(url.path, root: root)
            let parts = relative.split(separator: "/")
            if parts.contains(where: { $0.lowercased() == ".svn" || $0.lowercased() == ".git" }) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: properties)
            // 即使为空的嵌套目录也必须成为明确候选。选中它时只会按 empty
            // 深度加入该节点及必要父节点，旁路子项永远不会被隐式递归加入。
            if values.isDirectory == true, values.isSymbolicLink != true {
                files.append(FileChange(path: relative, kind: .untracked))
                continue
            }
            files.append(FileChange(path: relative, kind: .untracked))
        }
        if let enumerationError { throw enumerationError }
        return files
    }

    public func commitDiff(in binding: RepositoryBinding, file: RepositoryCommitFile) async throws -> RepositoryPatch {
        let path = try validatedCommitPath(file.change.path, in: binding)
        let current = try await commitFile(change: file.change, in: binding)
        guard current.fingerprint == file.fingerprint else {
            throw VersionControlError.invalidData("文件 \(path) 在提交预览后已变化，请重新查看提交内容。")
        }
        if file.change.kind == .untracked {
            let url = binding.root.appendingPathComponent(path)
            let prefix = "新增未受 SVN 管理的路径：\(path)\n\n"
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                return RepositoryPatch(text: prefix + "目录将以仅此节点的方式加入 SVN；未选择的子文件和子目录不会被递归加入或提交。\n")
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return RepositoryPatch(text: prefix + "符号链接 → \(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))\n")
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: min(size, 1_048_576)) ?? Data()
            if data.contains(0) { return RepositoryPatch(text: prefix + "二进制文件，大小 \(size) 字节。") }
            let suffix = size > data.count ? "\n\n… 已截断，文件共 \(size) 字节。" : ""
            return RepositoryPatch(text: prefix + String(decoding: data, as: UTF8.self) + suffix, isTruncated: size > data.count)
        }
        if file.isDirectory {
            // 与实际的 `svn commit --depth empty` 对齐：目录预览只读取自身属性，
            // 不把未选择的子文件内容差异显示为本次提交范围。
            let result = try await svn(["diff", "--depth", "empty", "--", svnTargetPath(path)], directory: binding.root)
            return RepositoryPatch(text: result.output)
        }
        return try await diff(in: binding, path: path, revision: nil)
    }

    public func commit(
        _ request: RepositoryCommitRequest,
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryCommitResult {
        guard request.bindingID == binding.id else {
            return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "提交请求与当前 SVN 工作副本不匹配。")
        }
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "提交说明不能为空。") }
        guard !request.files.isEmpty else { return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "请选择至少一个要提交的文件。") }

        await progress(RepositoryOperationProgress("核对 SVN 提交范围…"))
        let selected: [RepositoryCommitFile]
        do {
            let revision = try await workingCopyRevision(in: binding)
            guard request.baseRevision == revision else {
                return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "工作副本 BASE 已变化，请重新查看提交内容。")
            }
            var verified: [RepositoryCommitFile] = []
            var seen = Set<String>()
            for file in request.files {
                let path = try validatedCommitPath(file.change.path, in: binding)
                guard seen.insert(path).inserted else { continue }
                guard file.restriction == nil else { return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: file.restriction ?? "该路径不能安全地按当前范围提交。") }
                let current = try await commitFile(change: file.change, in: binding)
                guard current.restriction == nil else { return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: current.restriction ?? "该路径不能安全地按当前范围提交。") }
                guard current.fingerprint == file.fingerprint else { return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "文件 \(path) 在提交预览后已变化，请重新查看提交内容。") }
                verified.append(current)
            }
            guard !verified.isEmpty else { return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "未找到可提交的文件。") }
            try Task.checkCancellation()
            selected = verified
        } catch is CancellationError {
            return RepositoryCommitResult(bindingID: binding.id, outcome: .cancelled, summary: "SVN 提交在启动前已取消。")
        } catch {
            return RepositoryCommitResult(bindingID: binding.id, outcome: .failed, summary: "SVN 提交尚未启动。", details: sanitizedCommitDetails(error.localizedDescription))
        }

        let setup: (SVNAutomaticTLSFallback.Mode, [String], URL, [String])
        do {
            await progress(RepositoryOperationProgress("探测 SVN 提交连接…"))
            let tlsMode = try await probeUpdateTLSMode(in: binding)
            try Task.checkCancellation()
            // 连接探测期间用户仍可能在编辑器修改文件，进入本地写阶段前再次核对。
            for file in selected {
                let current = try await commitFile(change: file.change, in: binding)
                guard current.fingerprint == file.fingerprint else {
                    throw VersionControlError.invalidData("连接检查期间文件已变化，请重新准备提交：\(file.change.path)")
                }
            }
            // 对新增的嵌套文件，仅把必要父目录按 empty 深度加入，绝不递归 add 未选择的同级文件。
            var implicitDirectories: [String] = []
            for file in selected where file.change.kind == .untracked || file.change.kind == .added {
                implicitDirectories += try await addUnversionedParents(of: file.change.path, in: binding)
                if file.change.kind == .untracked {
                    let result = try await svn(["add", "--depth", "empty", "--", svnTargetPath(file.change.path)], directory: binding.root)
                    _ = try requireSuccess(result, tool: "svn")
                }
            }
            let messageFile = try writeCommitMessage(message)
            let paths = (implicitDirectories + selected.map(\.change.path)).reduce(into: [String]()) { paths, path in
                if !paths.contains(path) { paths.append(path) }
            }
            setup = (tlsMode, implicitDirectories, messageFile, paths)
        } catch is CancellationError {
            return RepositoryCommitResult(bindingID: binding.id, outcome: .cancelled, summary: "SVN 提交在启动前已取消。")
        } catch {
            return RepositoryCommitResult(
                bindingID: binding.id, outcome: .failed,
                summary: "SVN 提交尚未启动。",
                details: sanitizedCommitDetails(error.localizedDescription) + " 本地新增文件可能已被调度添加；请刷新工作副本状态确认。"
            )
        }
        let (tlsMode, _, messageFile, paths) = setup
        defer { try? FileManager.default.removeItem(at: messageFile) }
        let command = ["--non-interactive", "--no-auth-cache", "commit", "--depth", "empty", "--file", messageFile.path, "--"] + paths.map(svnTargetPath)
        await progress(RepositoryOperationProgress("正在提交到 SVN…", detail: "已限定为 \(paths.count) 个路径。"))
        do {
            let result = try await runCommit(command, directory: binding.root, remoteURL: binding.remoteURL, tlsMode: tlsMode)
            let knownRevision = committedRevision(from: result.output)
            if result.exitCode != 0, knownRevision == nil { _ = try requireSuccess(result, tool: "svn") }
            guard let committedRevision = knownRevision else {
                return RepositoryCommitResult(
                    bindingID: binding.id, outcome: .unknown,
                    summary: "SVN 命令已结束，但无法确认提交修订号。",
                    details: sanitizedCommitDetails(result.output + "\n" + result.error),
                    committedFiles: selected.map(\.change)
                )
            }
            await progress(RepositoryOperationProgress("SVN 提交完成。"))
            return RepositoryCommitResult(
                bindingID: binding.id, outcome: .succeeded, revisionID: "r\(committedRevision)",
                summary: "SVN 已提交 r\(committedRevision)。",
                details: sanitizedCommitDetails(result.output + "\n" + result.error),
                committedFiles: selected.map(\.change)
            )
        } catch is CancellationError {
            return RepositoryCommitResult(
                bindingID: binding.id, outcome: .unknown,
                summary: "SVN 提交已启动后被取消，无法确认服务器是否已接收。",
                details: "请刷新历史和工作副本状态后再决定是否重试。",
                committedFiles: selected.map(\.change)
            )
        } catch {
            return RepositoryCommitResult(
                bindingID: binding.id, outcome: .unknown,
                summary: "SVN 提交命令未能确认结果。",
                details: sanitizedCommitDetails(error.localizedDescription) + " 请刷新历史和工作副本状态后再决定是否重试。",
                committedFiles: selected.map(\.change)
            )
        }
    }

    private func commitFile(change: FileChange, in binding: RepositoryBinding) async throws -> RepositoryCommitFile {
        let path = try validatedCommitPath(change.path, in: binding)
        let restriction = try await commitRestriction(for: change, path: path, in: binding)
        let snapshot = try await commitSnapshot(path: path, change: change, in: binding)
        let url = binding.root.appendingPathComponent(path)
        var directory = ObjCBool(false)
        let isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        return RepositoryCommitFile(
            change: FileChange(path: path, kind: change.kind), fingerprint: snapshot,
            restriction: restriction, isDirectory: isDirectory
        )
    }

    private func validatedCommitPath(_ value: String, in binding: RepositoryBinding) throws -> String {
        _ = try CommitFileSnapshot.validatedURL(root: binding.root, path: value)
        return value
    }

    private func commitRestriction(for change: FileChange, path: String, in binding: RepositoryBinding) async throws -> String? {
        if change.kind != .untracked {
            let state = try await svn(["status", "--xml", "--verbose", "--depth", "empty", "--", svnTargetPath(path)], directory: binding.root)
            if try SVNXMLDocument(data: state.data).statusEntries.contains(where: { $0.copied || $0.movedFrom != nil || $0.movedTo != nil }) {
                return "SVN 复制或移动节点涉及关联路径，当前不支持提交该范围。"
            }
        }
        switch change.kind {
        case .renamed, .copied, .conflicted, .unknown, .typeChanged:
            return "该 SVN 状态无法保证只影响所选路径，请先在其他工具中处理后再提交。"
        case .deleted:
            // 本地删除后用 BASE 节点判断它原本是否为目录；普通文件删除仍可安全地按单路径提交。
            let baseInfo = try? await svn(["info", "--xml", "-r", "BASE", "--", svnTargetPath(path)], directory: binding.root)
            guard let baseInfo, let document = try? SVNXMLDocument(data: baseInfo.data), let kind = document.infoEntry?.kind else {
                return "无法确认删除节点类型，不能安全地按当前范围提交。"
            }
            if kind == "dir" {
                return "删除目录会递归影响子项，无法保证只影响所选路径。"
            }
            return nil
        case .added:
            let state = try await svn(["status", "--xml", "--verbose", "--", svnTargetPath(path)], directory: binding.root)
            if try SVNXMLDocument(data: state.data).statusEntries.contains(where: { $0.copied || $0.movedFrom != nil || $0.movedTo != nil }) {
                return "SVN 复制或移动节点可能涉及原路径，无法保证只影响所选路径。"
            }
            return nil
        default:
            // `svn commit --depth empty <目录>` 只提交目录自身的属性变化，不会递归
            // 提交子节点。受控目录因此可以作为明确的属性提交范围。
            return nil
        }
    }

    private func commitSnapshot(path: String, change: FileChange, in binding: RepositoryBinding) async throws -> String {
        // 包含 SVN 状态、属性状态、BASE 信息和实际文件指纹；任一项变化都会拒绝提交。
        let status = try await svn(["status", "--xml", "--verbose", "--", svnTargetPath(path)], directory: binding.root)
        let local = try CommitFileSnapshot.fingerprint(root: binding.root, path: path)
        if change.kind == .untracked {
            return CommitFileSnapshot.fingerprint(data: Data(["path=\(path)", "kind=untracked", "status=\(try stableCommitXML(status.data))", "local=\(local)"].joined(separator: "\n").utf8))
        }
        let infoArguments = change.kind == .deleted
            ? ["info", "--xml", "-r", "BASE", "--", svnTargetPath(path)]
            : ["info", "--xml", "--", svnTargetPath(path)]
        let info = try await svn(infoArguments, directory: binding.root)
        let properties = try await svn(["diff", "--properties-only", "--depth", "empty", "--", svnTargetPath(path)], directory: binding.root)
        let material = [
            "path=\(path)", "kind=\(change.kind.rawValue)",
            "status=\(try stableCommitXML(status.data))", "info=\(try stableCommitXML(info.data))",
            "properties=\(properties.output)", "local=\(local)"
        ].joined(separator: "\n")
        return CommitFileSnapshot.fingerprint(data: Data(material.utf8))
    }

    /// SVN 的 XML 属性顺序受进程内哈希表影响；规范化后再比较，避免未修改文件被误判过期。
    private func stableCommitXML(_ data: Data) throws -> String {
        try XMLDocument(data: data, options: []).canonicalXMLStringPreservingComments(false)
    }

    private func addUnversionedParents(of path: String, in binding: RepositoryBinding) async throws -> [String] {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return [] }
        var parents: [String] = []
        var current = ""
        for part in components.dropLast() {
            current = current.isEmpty ? part : current + "/" + part
            let state = try await svn(["status", "--xml", "--", svnTargetPath(current)], directory: binding.root)
            let statuses = try SVNXMLDocument(data: state.data).statusEntries
            let currentStatus = statuses.first { relativePath($0.path, root: binding.root) == current }
            if currentStatus?.item == "added" {
                // 父目录之前可能因用户选择了另一个新文件而已调度添加；提交它时仍用 depth empty，
                // 不会把该目录中的未选 sibling 一并递归提交。
                parents.append(current)
            } else if currentStatus?.item == "unversioned" {
                let directory = binding.root.appendingPathComponent(current)
                var isDirectory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw VersionControlError.invalidData("新增文件的父目录不存在：\(current)")
                }
                _ = try await svn(["add", "--depth", "empty", "--", svnTargetPath(current)], directory: binding.root)
                parents.append(current)
            }
        }
        return parents
    }

    private func writeCommitMessage(_ message: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-svn-message-\(UUID().uuidString)")
        try Data(message.utf8).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private func runCommit(
        _ arguments: [String], directory: URL, remoteURL: String?, tlsMode: SVNAutomaticTLSFallback.Mode
    ) async throws -> CommandResult {
        switch tlsMode {
        case .modern:
            return try await runRemoteCommand(arguments, directory: directory, remoteURL: remoteURL, configuration: nil, timeout: 120)
        case .legacyCompatible:
            try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
            return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                try await runRemoteCommand(arguments, directory: directory, remoteURL: remoteURL, configuration: configuration, timeout: 120)
            }
        }
    }

    private func committedRevision(from output: String) -> String? {
        let expression = try? NSRegularExpression(pattern: #"Committed revision ([0-9]+)\."#)
        let range = NSRange(output.startIndex..., in: output)
        guard let match = expression?.firstMatch(in: output, range: range), match.numberOfRanges > 1 else { return nil }
        return (output as NSString).substring(with: match.range(at: 1))
    }

    private func sanitizedCommitDetails(_ value: String) -> String {
        RepositoryDisplaySanitizer.redact(value).trimmingCharacters(in: .whitespacesAndNewlines)
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

        await progress(RepositoryOperationProgress("更新 SVN 工作副本…", detail: "等待 SVN 返回已处理的文件…"))
        // `svn update` 本身不支持 --xml；CommandRunner 固定英文 locale，下面只读取其稳定的状态列。
        let command = ["--non-interactive", "--no-auth-cache", "update", "--ignore-externals", "--accept", "postpone"]
        let reporter = SVNTransferProgressReporter(root: binding.root, operationName: "正在更新 SVN…", progress: progress)
        let output: CommandOutputHandler = { lines in
            await reporter.receive(lines: lines.compactMap { $0.stream == .stdout ? $0.text : nil })
        }
        let updateResult: CommandResult
        do {
            updateResult = try await runUpdate(
                command,
                directory: binding.root,
                remoteURL: binding.remoteURL,
                tlsMode: tlsMode,
                onOutput: output
            )
            await reporter.finish()
        } catch {
            await reporter.finish()
            throw error
        }
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

    public func initialize(
        _ request: RepositorySetupRequest,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositorySetupResult {
        guard request.providerID == id else {
            return RepositorySetupResult(outcome: .failed, directory: request.directory, summary: "初始化方式与 SVN 不匹配。")
        }
        guard let remote = request.remote else {
            return RepositorySetupResult(outcome: .failed, directory: request.directory, summary: "SVN 初始化需要明确的新远端地址。")
        }
        let source = request.directory.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return RepositorySetupResult(outcome: .failed, directory: source, summary: "要导入的本地文件夹不存在。")
        }
        guard try await detect(at: source) == nil else {
            return RepositorySetupResult(outcome: .failed, directory: source, summary: "该文件夹已受版本控制管理，不能初始化为新的 SVN 工作副本。")
        }
        let address: String
        do {
            address = try normalizedRemoteAddress(remote.url)
            try await rememberCredentials(remote.credentials, for: address)
        } catch {
            return RepositorySetupResult(
                outcome: .failed,
                directory: source,
                summary: "SVN 远端地址或凭据无效，未开始导入。",
                details: RepositoryDisplaySanitizer.redact(error.localizedDescription)
            )
        }
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return RepositorySetupResult(outcome: .failed, directory: source, summary: "SVN 初始提交说明不能为空。")
        }

        await progress(RepositoryOperationProgress("检查 SVN 远端路径…"))
        do {
            _ = try await runRemoteRead(["info", "--xml", svnRemoteTarget(address)], remoteURL: address)
            return RepositorySetupResult(outcome: .failed, directory: source, summary: "SVN 远端路径已存在，拒绝覆盖。")
        } catch is CancellationError {
            return RepositorySetupResult(outcome: .cancelled, directory: source, summary: "SVN 导入在开始前已取消。")
        } catch {
            guard isMissingSVNPath(error) else { throw error }
        }

        let parentAddress = try remoteParentAddress(of: address)
        await progress(RepositoryOperationProgress("验证 SVN 远端父目录与连接…"))
        let tlsMode = try await probeRemoteTLSMode(parentAddress)
        try Task.checkCancellation()

        await progress(RepositoryOperationProgress("准备不含版本控制元数据的导入快照…"))
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-svn-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try makeSVNImportSnapshot(from: source, to: staging)
        let sourceFingerprint = try importManifest(at: source)
        let snapshotFingerprint = try importManifest(at: staging)
        guard sourceFingerprint == snapshotFingerprint else {
            throw VersionControlError.invalidData("导入快照与原目录不一致，已停止导入。")
        }
        try Task.checkCancellation()

        await progress(RepositoryOperationProgress("正在导入到 SVN…", detail: "远端写入只执行一次。"))
        guard try importManifest(at: source) == sourceFingerprint else {
            return RepositorySetupResult(outcome: .failed, directory: source,
                                         summary: "原目录在导入前发生变化，未写入 SVN。",
                                         details: "原目录未替换；请重新确认内容后再导入。")
        }
        let imported: CommandResult
        do {
            imported = try await runRemoteWrite(
                ["--non-interactive", "--no-auth-cache", "import", "--no-ignore", "--no-auto-props", staging.path, address, "-m", message],
                remoteURL: address, tlsMode: tlsMode, timeout: 120
            )
            _ = try requireSuccess(imported, tool: "svn")
        } catch is CancellationError {
            return RepositorySetupResult(outcome: .unknown, directory: source,
                                         summary: "SVN 导入已启动后被取消，无法确认远端是否已创建。",
                                         details: "原目录未改动；请先在远端核对 \(address)。")
        } catch {
            return RepositorySetupResult(outcome: .unknown, directory: source,
                                         summary: "SVN 导入结果无法确认，未自动重试。",
                                         details: "原目录未改动；请先在远端核对 \(address)。\n\(RepositoryDisplaySanitizer.redact(error.localizedDescription))")
        }

        let temporaryCheckout = source.deletingLastPathComponent().appendingPathComponent(".rephub-svn-checkout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryCheckout) }
        await progress(RepositoryOperationProgress("验证导入结果并生成新的 SVN 工作副本…"))
        do {
            let result = try await runRemoteWrite(
                ["--non-interactive", "--no-auth-cache", "checkout", "--ignore-externals", svnRemoteTarget(address), temporaryCheckout.path],
                remoteURL: address, tlsMode: tlsMode, timeout: 600
            )
            _ = try requireSuccess(result, tool: "svn")
            guard try await detect(at: temporaryCheckout) != nil else {
                throw VersionControlError.invalidRepository("导入后的临时工作副本无法识别。")
            }
            guard try importManifest(at: temporaryCheckout) == snapshotFingerprint else {
                throw VersionControlError.invalidData("检出内容与导入快照不一致。")
            }
        } catch {
            return RepositorySetupResult(outcome: .unknown, directory: source,
                                         summary: "SVN 已导入，但未能安全替换本地文件夹。",
                                         details: "原目录仍保留；请核对远端 \(address) 后手工检出。\n\(RepositoryDisplaySanitizer.redact(error.localizedDescription))")
        }

        let backup = source.deletingLastPathComponent().appendingPathComponent("\(source.lastPathComponent).rephub-backup-\(UUID().uuidString)", isDirectory: true)
        do {
            try Task.checkCancellation()
            guard try importManifest(at: source) == sourceFingerprint else {
                return RepositorySetupResult(outcome: .unknown, directory: source,
                                             summary: "SVN 已导入，但原目录在发布前发生变化。",
                                             details: "原目录未替换；请核对远端 \(address) 后手工合并或检出。")
            }
            try FileManager.default.moveItem(at: source, to: backup)
            do {
                try FileManager.default.moveItem(at: temporaryCheckout, to: source)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: source)
                return RepositorySetupResult(outcome: .unknown, directory: source,
                                             summary: "SVN 已导入，但本地工作副本发布失败。",
                                             details: "原目录已尝试恢复；远端请手工核对。", backupDirectory: backup)
            }
        } catch {
            return RepositorySetupResult(outcome: .unknown, directory: source,
                                         summary: "SVN 已导入，但无法保留原目录后发布工作副本。",
                                         details: "原目录或备份可能仍在原位置，请先手工核对。")
        }
        await progress(RepositoryOperationProgress("SVN 初始化完成。"))
        let revision = committedRevision(from: imported.output).map { " r\($0)" } ?? ""
        return RepositorySetupResult(outcome: .succeeded, directory: source,
                                     summary: "已导入 SVN\(revision)，原文件夹已保留为备份。",
                                     details: "远端：\(address)", backupDirectory: backup)
    }

    public func managementContext(in binding: RepositoryBinding) async throws -> RepositoryManagementContext {
        let status = try await svn(["status", "--xml"], directory: binding.root)
        let document = try SVNXMLDocument(data: status.data)
        let changes = document.statusEntries.map { FileChange(path: relativePath($0.path, root: binding.root), kind: statusKind($0)) }
        let conflicts = document.statusEntries.compactMap { entry -> RepositoryConflict? in
            guard statusKind(entry) == .conflicted else { return nil }
            let path = relativePath(entry.path, root: binding.root)
            let unsupported = entry.treeConflicted || entry.properties == "conflicted"
            let editable = !unsupported && fileLooksLikeResolvedText(binding.root.appendingPathComponent(path))
            let detail: String = entry.treeConflicted ? "SVN 树冲突，不能在 RepHub 中标记解决。"
                : entry.properties == "conflicted" ? "SVN 属性冲突，不能在 RepHub 中标记解决。"
                : editable ? "内容冲突已无标记，可标记为已解决。" : "请先在编辑器中解决内容冲突并移除冲突标记。"
            return RepositoryConflict(path: path, detail: detail, canMarkResolved: editable)
        }
        let base = try await workingCopyRevision(in: binding)
        let token = try managementToken(status: status.data, baseRevision: base, root: binding.root, entries: document.statusEntries)
        return RepositoryManagementContext(binding: binding, stateToken: token, headRevision: "r\(base)", changes: changes, conflicts: conflicts)
    }

    public func performManagement(
        _ request: RepositoryManagementRequest,
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryManagementResult {
        guard case let .markResolved(paths) = request.action else {
            throw VersionControlError.unsupported("SVN 不支持该仓库管理操作。")
        }
        guard !paths.isEmpty else { return RepositoryManagementResult(outcome: .failed, summary: "请选择要标记为已解决的冲突文件。") }
        let context = try await managementContext(in: binding)
        guard context.stateToken == request.stateToken else {
            return RepositoryManagementResult(outcome: .failed, summary: "SVN 工作副本状态已变化，请刷新冲突列表后重试。")
        }
        let conflicts = Dictionary(uniqueKeysWithValues: context.conflicts.map { ($0.path, $0) })
        let selected = Array(Set(paths)).sorted()
        for path in selected {
            _ = try validatedCommitPath(path, in: binding)
            guard let conflict = conflicts[path] else {
                return RepositoryManagementResult(outcome: .failed, summary: "路径不是当前 SVN 冲突：\(path)")
            }
            guard conflict.canMarkResolved else {
                return RepositoryManagementResult(outcome: .failed, summary: "\(path)：\(conflict.detail)")
            }
        }
        await progress(RepositoryOperationProgress("标记 SVN 内容冲突已解决…"))
        do {
            for path in selected {
                try Task.checkCancellation()
                _ = try await svn(["resolve", "--accept", "working", "--", svnTargetPath(path)], directory: binding.root)
            }
        } catch is CancellationError {
            return RepositoryManagementResult(outcome: .cancelled, summary: "标记冲突已解决已取消；请刷新状态确认。")
        } catch {
            return RepositoryManagementResult(outcome: .failed, summary: "无法标记 SVN 冲突已解决。", details: RepositoryDisplaySanitizer.redact(error.localizedDescription))
        }
        let after = try await managementContext(in: binding)
        let unresolved = Set(after.conflicts.map(\.path)).intersection(selected)
        guard unresolved.isEmpty else {
            return RepositoryManagementResult(outcome: .failed, summary: "部分路径仍处于冲突状态。", details: unresolved.sorted().joined(separator: "、"))
        }
        return RepositoryManagementResult(outcome: .succeeded, summary: "已标记 \(selected.count) 个 SVN 内容冲突为已解决。")
    }

    public func compare(in binding: RepositoryBinding, from: String, to: String) async throws -> RepositoryComparison {
        let start = try numericSVNRevision(from)
        let end = try numericSVNRevision(to)
        guard start != end else { return RepositoryComparison(fromRevision: "r\(start)", toRevision: "r\(end)", files: []) }
        let target = try repositoryHistoryTarget(in: binding, pegRevision: String(max(start, end)))
        let result = try await svn(["diff", "--summarize", "--xml", "-r", "\(start):\(end)", target], directory: binding.root, remoteURL: binding.remoteURL)
        let paths = try SVNDiffSummaryDocument(data: result.data).entries.compactMap { entry -> FileChange? in
            guard let relative = relativeSummaryPath(entry.path, binding: binding) else { return nil }
            // `.` 是仅供修订比较读取的仓库根标记；绝不进入普通工作副本写路径验证。
            return FileChange(path: relative.isEmpty ? "." : relative, kind: summaryKind(entry.item, properties: entry.properties))
        }
        return RepositoryComparison(fromRevision: "r\(start)", toRevision: "r\(end)", files: paths)
    }

    public func comparisonDiff(in binding: RepositoryBinding, comparison: RepositoryComparison, path: String) async throws -> RepositoryPatch {
        let normalized = normalizedRelativePath(path)
        guard let change = comparison.files.first(where: { $0.path == normalized }) else {
            throw VersionControlError.invalidData("该文件不属于当前 SVN 修订比较范围：\(normalized)")
        }
        let from = try numericSVNRevision(comparison.fromRevision)
        let to = try numericSVNRevision(comparison.toRevision)
        // 删除节点只在 from 修订存在，新增节点只在 to 修订存在；普通变更取较新可见节点。
        let peg: Int = switch change.kind {
        case .deleted: from
        case .added: to
        default: max(from, to)
        }
        if normalized == "." {
            let target = try repositoryHistoryTarget(in: binding, pegRevision: String(peg))
            // 根节点比较仅读取自身属性，不能让根路径的普通 diff 把整个子树加载进来。
            let result = try await svn(["diff", "--depth", "empty", "-r", "\(from):\(to)", "--", target], directory: binding.root, remoteURL: binding.remoteURL)
            return RepositoryPatch(text: result.output)
        }
        let target = try repositoryFileURL(path: normalized, in: binding)
        let result = try await svn(["diff", "-r", "\(from):\(to)", "--", "\(target)@\(peg)"], directory: binding.root, remoteURL: binding.remoteURL)
        return RepositoryPatch(text: result.output)
    }

    // MARK: - Repository migration source

    /// 迁移计划始终先把远端 HEAD 固定为一个数值修订。后续历史读取和每一次导出都使用
    /// 同一个 peg，避免迁移过程中有新提交时把不同版本混在同一条 Git 历史里。
    public func planMigration(
        from location: RemoteRepositoryLocation,
        mode: MigrationMode,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> MigrationSourcePlan {
        try await planMigration(from: location, mode: mode, includeCopyHistory: true, progress: progress)
    }

    public func planMigration(
        from location: RemoteRepositoryLocation,
        mode: MigrationMode,
        includeCopyHistory: Bool,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> MigrationSourcePlan {
        let address = try normalizedRemoteAddress(location.url)
        try await rememberCredentials(location.credentials, for: address)
        await progress(RepositoryOperationProgress("固定 SVN 来源版本…"))

        let info = try await runRemoteRead(["info", "--xml", "-r", "HEAD", svnRemoteTarget(address)], remoteURL: address)
        guard let entry = try SVNXMLDocument(data: info.data).infoEntry,
              entry.kind == "dir",
              let rawAnchor = entry.revision,
              let anchorNumber = Int(rawAnchor), anchorNumber > 0 else {
            throw VersionControlError.invalidRepository("SVN 迁移来源必须是已有修订的目录。")
        }
        let anchor = String(anchorNumber)
        let target = migrationTarget(address, pegRevision: anchor)

        switch mode {
        case .snapshot:
            // 不读取仓库根目录：只对已获授权的选定目录查询，避免子目录权限用户在
            // 实际导出前就被根目录日志拒绝。该记录仅提供快照上下文，不能伪装成 rN 本身。
            let metadata = try await runRemoteRead(
                ["log", "--xml", "--limit", "1", "-r", "\(anchor):1", target],
                remoteURL: address
            )
            guard let log = try SVNXMLDocument(data: metadata.data).logEntries.first else {
                throw VersionControlError.invalidData("无法读取选定 SVN 目录在固定版本 r\(anchor) 的提交上下文。")
            }
            let revision = try migrationSnapshotRevision(anchor: anchor, context: log)
            var warnings = migrationWarnings(mode: mode)
            if revision.author.isEmpty {
                warnings.append("SVN 快照上下文未包含作者；发布前需为该提交指定 Git 作者。")
            }
            await progress(RepositoryOperationProgress("已固定 SVN r\(anchor)，将仅导出当前快照。"))
            return MigrationSourcePlan(
                providerID: id, location: RemoteRepositoryLocation(url: address, credentials: location.credentials), anchor: "r\(anchor)",
                mode: mode, includeCopyHistory: includeCopyHistory, revisions: [revision], warnings: warnings
            )

        case .history:
            let scope = includeCopyHistory ? "包含复制前祖先历史" : "仅当前路径，复制点前停止"
            await progress(RepositoryOperationProgress("读取 SVN 目录历史…", detail: "已固定到 r\(anchor)，\(scope)，正在分页读取。"))
            let revisions = try await migrationHistory(target: target, address: address, anchor: anchor,
                                                        includeCopyHistory: includeCopyHistory, progress: progress)
            guard !revisions.isEmpty else {
                throw VersionControlError.invalidData("SVN 目录没有可迁移的提交历史。")
            }
            var warnings = migrationWarnings(mode: mode, includeCopyHistory: includeCopyHistory)
            if revisions.contains(where: { $0.author.isEmpty }) {
                warnings.append("部分 SVN 提交未包含作者；发布前需为这些提交指定 Git 作者。")
            }
            return MigrationSourcePlan(
                providerID: id, location: RemoteRepositoryLocation(url: address, credentials: location.credentials), anchor: "r\(anchor)",
                mode: mode, includeCopyHistory: includeCopyHistory, revisions: revisions, warnings: warnings
            )
        }
    }

    /// 导出始终写入业务层已分配的全新目录。SVN 远端和源工作副本均不会被写入。
    public func exportMigrationSnapshot(
        plan: MigrationSourcePlan,
        revision: MigrationRevision,
        to directory: URL,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws {
        guard plan.providerID == id else {
            throw VersionControlError.invalidData("迁移计划不属于 SVN 来源适配器。")
        }
        let address = try normalizedRemoteAddress(plan.location.url)
        try await rememberCredentials(plan.location.credentials, for: address)
        let anchor = try migrationAnchor(plan.anchor)
        guard plan.revisions.contains(revision) else {
            throw VersionControlError.invalidData("请求导出的修订不在当前固定迁移计划中。")
        }
        let exportRevision = try numericSVNRevision(revision.id)
        guard exportRevision > 0, exportRevision <= anchor else {
            throw VersionControlError.invalidData("SVN 导出修订超出固定迁移范围。")
        }

        let destination = directory.standardizedFileURL
        let manager = FileManager.default
        let isLink = (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != nil
        guard !manager.fileExists(atPath: destination.path), !isLink else {
            throw VersionControlError.invalidRepository("迁移快照目标已存在：\(destination.path)")
        }
        var parentIsDirectory = ObjCBool(false)
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard manager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw VersionControlError.invalidRepository("迁移快照目标的父目录不存在：\(parent.path)")
        }

        await progress(RepositoryOperationProgress("检查 SVN r\(exportRevision) 导出连接…"))
        let tlsMode = try await probeRemoteTLSMode(address)
        try Task.checkCancellation()

        await progress(RepositoryOperationProgress("导出 SVN r\(exportRevision)…", detail: "正在生成隔离迁移快照。"))
        let reporter = SVNTransferProgressReporter(root: destination, operationName: "正在导出 SVN 快照…", progress: progress)
        let output: CommandOutputHandler = { lines in
            await reporter.receive(lines: lines.compactMap { $0.stream == .stdout ? $0.text : nil })
        }
        let command = [
            "--non-interactive", "--no-auth-cache", "export", "--ignore-externals",
            "-r", String(exportRevision), migrationTarget(address, pegRevision: String(anchor)), destination.path
        ]
        do {
            let result = try await runRemoteWrite(command, remoteURL: address, tlsMode: tlsMode, timeout: 600, onOutput: output)
            _ = try requireSuccess(result, tool: "svn")
            await reporter.finish()
        } catch {
            await reporter.finish()
            // 复制/改名祖先、删除节点等导致的历史路径不可导出时，必须阻断整个迁移，
            // 不能跳过该修订后继续生成一条看似完整的 Git 历史。
            if isMissingSVNPath(error) {
                throw VersionControlError.invalidData("SVN r\(exportRevision) 无法从固定来源路径导出；该目录可能在此修订尚不存在、已删除，或需要无法解析的复制/改名祖先。请改用快照模式或调整迁移范围。")
            }
            throw error
        }
        try Task.checkCancellation()
        await progress(RepositoryOperationProgress("SVN r\(exportRevision) 快照导出完成。"))
    }

    /// 历史迁移会话只维护一份隔离 SVN 工作副本。首次检出（或从经过核对的本地基线
    /// 构造缓存）后，后续修订通过 `svn switch -r` 递进，快照则从本地缓存导出。
    /// 这样不会为每一条 SVN 修订重新进行远端 export。
    public func makeMigrationSnapshotSession(
        plan: MigrationSourcePlan,
        in workspace: URL
    ) async throws -> any RepositoryMigrationSnapshotSession {
        try await makeMigrationSnapshotSession(plan: plan, in: workspace, seedWorkingCopy: nil)
    }

    /// `seedWorkingCopy` 只用于首次工作副本迁移中、已经由业务层确认干净的 BASE。
    /// 仍会在本地再次核对，且第一条历史修订仍通过固定 URL/anchor switch 到指定版本；
    /// 因此不会把用户工作副本中的未跟踪或本地改动混入迁移缓存。
    public func makeMigrationSnapshotSession(
        plan: MigrationSourcePlan,
        in workspace: URL,
        seedWorkingCopy: URL?
    ) async throws -> any RepositoryMigrationSnapshotSession {
        guard plan.providerID == id else {
            throw VersionControlError.invalidData("迁移计划不属于 SVN 来源适配器。")
        }
        let address = try normalizedRemoteAddress(plan.location.url)
        let anchor = try migrationAnchor(plan.anchor)
        guard !plan.revisions.isEmpty else {
            throw VersionControlError.invalidData("SVN 迁移计划没有可导出的修订。")
        }
        try await rememberCredentials(plan.location.credentials, for: address)

        let cache = workspace.standardizedFileURL
        let manager = FileManager.default
        let isLink = (try? manager.destinationOfSymbolicLink(atPath: cache.path)) != nil
        guard !manager.fileExists(atPath: cache.path), !isLink else {
            throw VersionControlError.invalidRepository("SVN 迁移缓存目录已存在，拒绝复用：\(cache.path)")
        }
        let parent = cache.deletingLastPathComponent().standardizedFileURL
        var parentIsDirectory = ObjCBool(false)
        guard manager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue,
              (try? manager.destinationOfSymbolicLink(atPath: parent.path)) == nil else {
            throw VersionControlError.invalidRepository("SVN 迁移缓存的父目录不可用：\(parent.path)")
        }
        try manager.createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        return SVNMigrationSnapshotSession(
            provider: self,
            plan: plan,
            address: address,
            anchor: anchor,
            cache: cache,
            seedWorkingCopy: seedWorkingCopy?.standardizedFileURL
        )
    }

    /// 只读取已有工作副本。首次迁移要求一个完整、单一 BASE、没有已管改动的 SVN
    /// 工作副本；补迁阶段由 Git 侧负责冲突处理，因此不触碰 SVN 本地状态。
    public func inspectMigrationWorkingCopy(
        at directory: URL,
        requireClean: Bool
    ) async throws -> MigrationWorkingCopyInfo {
        guard let binding = try await detect(at: directory) else {
            throw VersionControlError.invalidRepository("所选目录不是 SVN 工作副本。")
        }
        let root = binding.root.standardizedFileURL
        // detect 会沿父目录查找 `.svn`，因此内部目录会得到父工作副本根。迁移若接受
        // 该结果会无声扩大范围，必须要求用户显式选择根目录。解析链接后比较，避免 /var
        // 等系统别名或指向根目录的链接被误判成内部目录。
        let selectedPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.resolvingSymlinksInPath().path
        guard selectedPath == rootPath else {
            throw VersionControlError.invalidRepository("请选择 SVN 工作副本根目录：\(root.path)")
        }
        let info = try await svn(["info", "--xml", "--depth", "empty"], directory: root, remoteURL: binding.remoteURL)
        guard let entry = try SVNXMLDocument(data: info.data).infoEntry,
              entry.kind == "dir",
              let rawURL = entry.url,
              let rawUUID = entry.repositoryUUID, !rawUUID.isEmpty,
              let revision = entry.revision, Int(revision) != nil else {
            throw VersionControlError.invalidRepository("SVN 工作副本缺少 URL、仓库 UUID 或 BASE 修订号。")
        }
        let sourceURL = try normalizedRemoteAddress(rawURL)

        guard requireClean else {
            return MigrationWorkingCopyInfo(directory: root, sourceURL: sourceURL, repositoryUUID: rawUUID, baseRevision: "r\(normalizedRevision(revision))")
        }

        let status = try await svn(
            ["status", "--xml", "--no-ignore", "--ignore-externals"], directory: root, remoteURL: sourceURL
        )
        let statuses = try SVNXMLDocument(data: status.data).statusEntries
        let managedChanges = statuses.filter { entry in
            // 未跟踪/已忽略文件不会被 SVN 或 Git 的首次历史提交隐式纳入，允许原样留在目录。
            guard entry.item != "unversioned", entry.item != "ignored" else { return false }
            return entry.item != "normal" || !["normal", "none", ""].contains(entry.properties) || entry.treeConflicted
        }
        guard managedChanges.isEmpty else {
            let paths = managedChanges.prefix(8).map { relativePath($0.path, root: root) }.joined(separator: "、")
            throw VersionControlError.invalidRepository("首次迁移要求 SVN 工作副本没有已管修改或冲突：\(paths)")
        }

        let versionResult = try await runner.run(executable: "svnversion", arguments: [], directory: root)
        _ = try requireSuccess(versionResult, tool: "svnversion")
        let version = try parseWorkingCopyVersion(versionResult.output, path: nil)
        guard version.minimum == version.maximum else {
            throw VersionControlError.invalidRepository("首次迁移不支持混合 SVN 修订（\(version.description)）。请先在其他工具中统一工作副本。")
        }
        guard !version.hasUncertainLayout else {
            throw VersionControlError.invalidRepository("首次迁移不支持切换或稀疏 SVN 工作副本（\(version.description)）。")
        }
        guard entry.depth == "infinity" else {
            throw VersionControlError.invalidRepository("首次迁移不支持稀疏 SVN 工作副本（depth: \(entry.depth ?? "unknown")）。")
        }
        let externals = try await svn(["propget", "svn:externals", "-R"], directory: root, remoteURL: sourceURL)
        guard externals.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VersionControlError.invalidRepository("首次迁移不支持包含 svn:externals 的工作副本，请先拆分外部依赖。")
        }
        return MigrationWorkingCopyInfo(directory: root, sourceURL: sourceURL, repositoryUUID: rawUUID, baseRevision: "r\(version.maximum)")
    }

    /// URL 相同不足以证明仍是同一 SVN 仓库：服务端可能在相同地址恢复、替换了仓库。
    /// 因此每次准备和应用迁移前，都在固定修订读取仓库 UUID 进行精确身份复核。
    public func verifyWorkingCopyMigrationSource(
        _ location: RemoteRepositoryLocation,
        repositoryUUID: String,
        revision: String
    ) async throws {
        let address = try normalizedRemoteAddress(location.url)
        try await rememberCredentials(location.credentials, for: address)
        let fixed = try numericSVNRevision(revision)
        guard fixed > 0 else {
            throw VersionControlError.invalidData("SVN 迁移来源复核必须使用正整数修订号。")
        }
        let response = try await runRemoteRead(
            ["info", "--xml", "-r", String(fixed), migrationTarget(address, pegRevision: String(fixed))],
            remoteURL: address
        )
        guard let entry = try SVNXMLDocument(data: response.data).infoEntry,
              entry.kind == "dir",
              let actualURL = entry.url,
              let actualUUID = entry.repositoryUUID, !actualUUID.isEmpty else {
            throw VersionControlError.invalidRepository("无法读取固定 SVN r\(fixed) 的来源身份信息。")
        }
        guard try normalizedRemoteAddress(actualURL) == address else {
            throw VersionControlError.invalidRepository("SVN 来源 URL 与迁移记录不一致，已停止迁移。")
        }
        guard actualUUID == repositoryUUID else {
            throw VersionControlError.invalidRepository("SVN 来源仓库 UUID 与迁移记录不一致；该 URL 可能已被替换，已停止迁移。")
        }
    }

    /// 首次迁移通常传入本地 BASE，补迁传入 nil 以固定当次远端 HEAD；两种情况都不会
    /// 让后续分页重新解析 HEAD。after 仅作为严格下界，因而补迁不会重复旧修订。
    public func planWorkingCopyHistory(
        from location: RemoteRepositoryLocation,
        mode: MigrationMode,
        through revision: String?,
        after previousRevision: String?,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> MigrationSourcePlan {
        try await planWorkingCopyHistory(from: location, mode: mode, through: revision,
                                         after: previousRevision, includeCopyHistory: true, progress: progress)
    }

    public func planWorkingCopyHistory(
        from location: RemoteRepositoryLocation,
        mode: MigrationMode,
        through revision: String?,
        after previousRevision: String?,
        includeCopyHistory: Bool,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> MigrationSourcePlan {
        let address = try normalizedRemoteAddress(location.url)
        try await rememberCredentials(location.credentials, for: address)
        let anchor: String
        if let revision, !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            anchor = String(try numericSVNRevision(revision))
            let info = try await runRemoteRead(
                ["info", "--xml", "-r", anchor, migrationTarget(address, pegRevision: anchor)], remoteURL: address
            )
            guard try SVNXMLDocument(data: info.data).infoEntry?.kind == "dir" else {
                throw VersionControlError.invalidRepository("指定的 SVN 迁移修订不是可导出的目录。")
            }
        } else {
            await progress(RepositoryOperationProgress("固定 SVN 来源版本…"))
            let info = try await runRemoteRead(["info", "--xml", "-r", "HEAD", svnRemoteTarget(address)], remoteURL: address)
            guard let raw = try SVNXMLDocument(data: info.data).infoEntry?.revision,
                  let value = Int(raw), value > 0 else {
                throw VersionControlError.invalidRepository("SVN 迁移来源必须是已有修订的目录。")
            }
            anchor = String(value)
        }
        // 补迁以已迁入修订为严格下界。即使初次迁移选择了“只保留当前路径”，
        // 之后发生 copy/rename 仍必须跨祖先把下界后的每条可读修订补入 Git，不能
        // 让新的复制点截断尚未迁移的历史。
        let effectiveIncludeCopyHistory: Bool
        let lowerBound: Int
        if let previousRevision, !previousRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectiveIncludeCopyHistory = true
            guard mode == .history else {
                throw VersionControlError.unsupported("SVN 补迁只能按提交历史执行，不能使用单快照模式。")
            }
            let previous = try numericSVNRevision(previousRevision)
            let fixed = try numericSVNRevision(anchor)
            guard previous <= fixed else {
                throw VersionControlError.invalidData("补迁起点 r\(previous) 高于当前固定 SVN r\(fixed)。")
            }
            // after == anchor 是合法的“无新增”状态，必须让业务层可正常展示。
            if previous == fixed {
                return MigrationSourcePlan(providerID: id, location: RemoteRepositoryLocation(url: address, credentials: location.credentials),
                                           anchor: "r\(anchor)", mode: mode, includeCopyHistory: effectiveIncludeCopyHistory,
                                           revisions: [], warnings: migrationWarnings(mode: mode, includeCopyHistory: effectiveIncludeCopyHistory))
            }
            lowerBound = previous + 1
        } else {
            effectiveIncludeCopyHistory = includeCopyHistory
            lowerBound = 1
        }
        let target = migrationTarget(address, pegRevision: anchor)
        switch mode {
        case .history:
            let scope = effectiveIncludeCopyHistory ? "包含复制前祖先历史" : "仅当前路径，复制点前停止"
            await progress(RepositoryOperationProgress("读取 SVN 目录历史…", detail: "已固定到 r\(anchor)，\(scope)，正在分页读取。"))
            let revisions = try await migrationHistory(target: target, address: address, anchor: anchor,
                                                        lowerBound: lowerBound, includeCopyHistory: effectiveIncludeCopyHistory,
                                                        progress: progress)
            var warnings = migrationWarnings(mode: mode, includeCopyHistory: effectiveIncludeCopyHistory)
            if revisions.contains(where: { $0.author.isEmpty }) {
                warnings.append("部分 SVN 提交未包含作者；发布前需为这些提交指定 Git 作者。")
            }
            return MigrationSourcePlan(providerID: id, location: RemoteRepositoryLocation(url: address, credentials: location.credentials),
                                       anchor: "r\(anchor)", mode: mode, includeCopyHistory: effectiveIncludeCopyHistory,
                                       revisions: revisions, warnings: warnings)
        case .snapshot:
            let metadata = try await runRemoteRead(["log", "--xml", "--limit", "1", "-r", "\(anchor):1", target], remoteURL: address)
            guard let context = try SVNXMLDocument(data: metadata.data).logEntries.first else {
                throw VersionControlError.invalidData("无法读取固定 SVN r\(anchor) 的快照上下文。")
            }
            let revision = try migrationSnapshotRevision(anchor: anchor, context: context)
            return MigrationSourcePlan(providerID: id, location: RemoteRepositoryLocation(url: address, credentials: location.credentials),
                                       anchor: "r\(anchor)", mode: mode, includeCopyHistory: effectiveIncludeCopyHistory,
                                       revisions: [revision], warnings: migrationWarnings(mode: mode, includeCopyHistory: effectiveIncludeCopyHistory))
        }
    }

    private func migrationHistory(
        target: String,
        address: String,
        anchor: String,
        lowerBound: Int = 1,
        includeCopyHistory: Bool = true,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> [MigrationRevision] {
        // 与普通界面分页不同，迁移不允许为了响应速度静默停在 150 条。每轮由 SVN
        // 返回最多 500 条，下一轮严格从上一批最旧修订的前一个数值继续。
        let pageSize = 500
        var upper = try numericSVNRevision(anchor)
        guard lowerBound > 0, lowerBound <= upper else { return [] }
        var result: [MigrationRevision] = []
        var seen = Set<String>()
        while upper > 0 {
            try Task.checkCancellation()
            // 迁移计划只需要修订号、作者、时间和提交说明；变更路径列表只会增加
            // 大型历史的传输与 XML 解析成本，实际文件内容由后续快照会话读取。
            var command = ["log", "--xml"]
            if !includeCopyHistory { command.append("--stop-on-copy") }
            command += ["--limit", String(pageSize), "-r", "\(upper):\(lowerBound)", target]
            let response = try await runRemoteRead(
                command,
                remoteURL: address
            )
            let entries = try SVNXMLDocument(data: response.data).logEntries
            guard !entries.isEmpty else { break }
            for entry in entries {
                let revision = try migrationRevision(from: entry, fallbackRevision: entry.revision)
                guard seen.insert(revision.id).inserted else {
                    throw VersionControlError.invalidData("SVN 迁移历史出现重复修订：\(revision.id)")
                }
                result.append(revision)
            }
            guard let last = entries.last, let lastNumber = Int(last.revision), lastNumber > 0 else {
                throw VersionControlError.invalidData("SVN 返回了无效的迁移历史修订号。")
            }
            await progress(RepositoryOperationProgress("读取 SVN 目录历史…", detail: "已读取 \(result.count) 条提交，当前到 r\(lastNumber)。"))
            if entries.count < pageSize || lastNumber <= lowerBound { break }
            upper = lastNumber - 1
        }
        // SVN 按从新到旧返回；Git 目标需要从旧到新逐个重建快照提交。
        return result.reversed()
    }

    private func migrationRevision(from entry: SVNXMLDocument.LogEntry, fallbackRevision: String) throws -> MigrationRevision {
        let raw = entry.revision.isEmpty ? fallbackRevision : entry.revision
        return MigrationRevision(
            id: "r\(normalizedRevision(raw))", author: entry.author ?? "",
            date: try migrationDate(entry.date, revision: raw), message: entry.message ?? ""
        )
    }

    private func migrationSnapshotRevision(anchor: String, context: SVNXMLDocument.LogEntry) throws -> MigrationRevision {
        let contextRevision = normalizedRevision(context.revision)
        let originalMessage = (context.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let contextDescription = originalMessage.isEmpty
            ? "目录最近相关提交 r\(contextRevision)"
            : "目录最近相关提交 r\(contextRevision)：\(originalMessage)"
        return MigrationRevision(
            // 快照内容始终来自固定锚点；不能用目录最近提交的 rM 冒充实际导出版本。
            id: "r\(anchor)", author: context.author ?? "",
            date: try migrationDate(context.date, revision: contextRevision),
            message: "SVN 快照 r\(anchor)（\(contextDescription)）"
        )
    }

    private func migrationDate(_ value: String?, revision: String) throws -> Date {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VersionControlError.invalidData("SVN r\(normalizedRevision(revision)) 缺少提交时间，无法如实保留迁移历史。")
        }
        let date = parseDate(value)
        guard date != .distantPast else {
            throw VersionControlError.invalidData("SVN r\(normalizedRevision(revision)) 的提交时间无法解析，无法如实保留迁移历史。")
        }
        return date
    }

    private func migrationAnchor(_ raw: String) throws -> Int {
        let anchor = try numericSVNRevision(raw)
        guard anchor > 0 else { throw VersionControlError.invalidData("SVN 迁移锚点必须是正整数修订号。") }
        return anchor
    }

    private func migrationTarget(_ address: String, pegRevision: String) -> String {
        "\(address)@\(normalizedRevision(pegRevision))"
    }

    private func migrationWarnings(mode: MigrationMode, includeCopyHistory: Bool = true) -> [String] {
        [
            mode == .snapshot
                ? "本次仅迁移固定修订的代码快照，生成一个新的 Git 初始提交，不包含原 SVN 历史。"
                : includeCopyHistory
                    ? "迁移当前账号在所选 SVN 目录可读取的历史，并包含复制或改名前祖先路径的历史；服务端权限或保留策略导致不可读取的历史不会被伪称已迁移。跨目录复制、改名或删除导致任一历史修订无法导出时会停止，不会跳过。"
                    : "仅迁移当前 SVN 路径自最近复制点起可读取的历史；复制前祖先路径的提交不会迁入。服务端权限或保留策略导致不可读取的历史不会被伪称已迁移。",
            "SVN 的自定义属性、锁、权限与目录属性不能完整映射到 Git；可执行位和符号链接由 SVN 导出结果保留。",
            "SVN externals 不会随迁移导出；请在预览中单独处理外部依赖。",
            "迁移过程中本地未提交修改不属于远端 SVN 历史，不会被包含。"
        ]
    }

    func svn(_ arguments: [String], directory: URL, remoteURL: String? = nil) async throws -> CommandResult {
        // --non-interactive 防止凭据提示阻塞 UI；不接受或绕过 TLS 证书错误。
        let command = ["--non-interactive", "--no-auth-cache"] + arguments
        let result = try await tlsFallback.execute(
            remoteURL: remoteURL,
            modern: { try await runRemoteCommand(command, directory: directory, remoteURL: remoteURL, configuration: nil) },
            legacy: {
                try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
                return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                    try await runRemoteCommand(command, directory: directory, remoteURL: remoteURL, configuration: configuration)
                }
            }
        )
        return try requireSuccess(result, tool: "svn")
    }

    private func makeSVNImportSnapshot(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else {
            throw VersionControlError.invalidData("无法枚举要导入的目录。")
        }
        while let item = enumerator.nextObject() as? URL {
            let relative = relativePath(item.path, root: source)
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: { $0 == ".svn" || $0 == ".git" }) {
                enumerator.skipDescendants()
                continue
            }
            let values = try item.resourceValues(forKeys: keys)
            // 不静默丢弃链接：导入对象必须完全可见且可复核，外部链接一律要求用户先处理。
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw VersionControlError.invalidData("导入目录包含符号链接，无法安全导入：\(relative)")
            }
            let target = destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try manager.copyItem(at: item, to: target)
            }
        }
        if let enumerationError { throw enumerationError }
    }

    private func importManifest(at root: URL) throws -> String {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw VersionControlError.invalidData("无法核对导入目录。") }
        var records: [String] = []
        while let item = enumerator.nextObject() as? URL {
            let relative = relativePath(item.path, root: root)
            let parts = relative.split(separator: "/")
            if parts.contains(where: { $0 == ".svn" || $0 == ".git" }) {
                enumerator.skipDescendants()
                continue
            }
            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw VersionControlError.invalidData("导入目录包含符号链接，无法安全核对：\(relative)")
            }
            if values.isDirectory == true {
                records.append("d:\(relative)")
            } else {
                records.append("f:\(relative):\(try CommitFileSnapshot.fingerprint(root: root, path: relative))")
            }
        }
        if let enumerationError { throw enumerationError }
        return CommitFileSnapshot.fingerprint(data: Data(records.sorted().joined(separator: "\n").utf8))
    }

    private func remoteParentAddress(of address: String) throws -> String {
        guard let url = URL(string: address) else { throw VersionControlError.invalidRepository("SVN 远端地址无效。") }
        let parent = url.deletingLastPathComponent().absoluteString
        let normalized = try normalizedRemoteAddress(parent)
        guard normalized != address else { throw VersionControlError.invalidRepository("SVN 导入地址必须位于已存在的父目录下。") }
        return normalized
    }

    private func fileLooksLikeResolvedText(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= 4_194_304,
              let data = try? Data(contentsOf: url), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { return false }
        return !text.contains("<<<<<<<") && !text.contains("=======") && !text.contains(">>>>>>>")
    }

    private func managementToken(
        status: Data,
        baseRevision: String,
        root: URL,
        entries: [SVNXMLDocument.StatusEntry]
    ) throws -> String {
        let canonical = try stableCommitXML(status)
        let fingerprints = entries.map { entry -> String in
            let path = relativePath(entry.path, root: root)
            let url = root.appendingPathComponent(path)
            var isDirectory = ObjCBool(false)
            let value: String
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                value = (try? importManifest(at: url)) ?? "unavailable-directory"
            } else {
                value = (try? CommitFileSnapshot.fingerprint(root: root, path: path)) ?? "unavailable"
            }
            return "\(path)=\(value)"
        }.sorted().joined(separator: "\n")
        return CommitFileSnapshot.fingerprint(data: Data(("base=\(baseRevision)\n" + canonical + "\n" + fingerprints).utf8))
    }

    private func numericSVNRevision(_ value: String) throws -> Int {
        let normalized = normalizedRevision(value)
        guard let revision = Int(normalized), revision >= 0 else {
            throw VersionControlError.invalidData("SVN 修订号无效：\(value)")
        }
        return revision
    }

    private func relativeSummaryPath(_ value: String, binding: RepositoryBinding) -> String? {
        if let url = URL(string: value), let remote = binding.remoteURL.flatMap(URL.init(string:)) {
            let full = decodedURLPath(url).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let root = decodedURLPath(remote).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard full == root || full.hasPrefix(root + "/") else { return nil }
            return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return normalizedRelativePath(value)
    }

    private func summaryKind(_ item: String, properties: String) -> FileChangeKind {
        switch item.lowercased() {
        case "added": return .added
        case "deleted": return .deleted
        case "modified": return .modified
        default:
            // `svn diff --summarize --xml` 对纯属性修改会给出 item=none/normal，
            // 同时以 props=modified 标记；这仍是实际可读取的修改。
            return properties.lowercased() == "modified" ? .modified : .unknown
        }
    }

    private func runRemoteRead(_ command: [String], remoteURL: String) async throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory
        let result = try await tlsFallback.execute(
            remoteURL: remoteURL,
            modern: { try await runRemoteCommand(["--non-interactive", "--no-auth-cache"] + command, directory: directory, remoteURL: remoteURL, configuration: nil) },
            legacy: {
                try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
                return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                    try await runRemoteCommand(["--non-interactive", "--no-auth-cache"] + command, directory: directory, remoteURL: remoteURL, configuration: configuration)
                }
            }
        )
        return try requireSuccess(result, tool: "svn")
    }

    private func probeRemoteTLSMode(_ remoteURL: String) async throws -> SVNAutomaticTLSFallback.Mode {
        let command = ["--non-interactive", "--no-auth-cache", "info", "--xml", svnRemoteTarget(remoteURL)]
        let directory = FileManager.default.temporaryDirectory
        let probe = try await tlsFallback.probe(
            remoteURL: remoteURL,
            modern: { try await runRemoteCommand(command, directory: directory, remoteURL: remoteURL, configuration: nil) },
            legacy: {
                try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
                return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                    try await runRemoteCommand(command, directory: directory, remoteURL: remoteURL, configuration: configuration)
                }
            }
        )
        _ = try requireSuccess(probe.result, tool: "svn")
        let document = try SVNXMLDocument(data: probe.result.data)
        guard document.infoEntry?.kind == "dir" else {
            throw VersionControlError.invalidRepository("SVN 地址不是可检出的目录。")
        }
        return probe.mode
    }

    private func runRemoteWrite(
        _ command: [String], remoteURL: String, tlsMode: SVNAutomaticTLSFallback.Mode, timeout: TimeInterval,
        onOutput: CommandOutputHandler? = nil
    ) async throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory
        switch tlsMode {
        case .modern:
            return try await runRemoteCommand(command, directory: directory, remoteURL: remoteURL, configuration: nil, timeout: timeout, onOutput: onOutput)
        case .legacyCompatible:
            try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
            return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                try await runRemoteCommand(command, directory: directory, remoteURL: remoteURL, configuration: configuration, timeout: timeout, onOutput: onOutput)
            }
        }
    }

    private func runRemoteCommand(
        _ arguments: [String], directory: URL, remoteURL: String?, configuration: URL?, timeout: TimeInterval = 20,
        onOutput: CommandOutputHandler? = nil
    ) async throws -> CommandResult {
        guard let remoteURL, let credential = await credentials.credential(for: remoteURL) else {
            // 获取写操作的时限不能被测试注入的只读执行器悄然缩回默认 20 秒。
            if timeout != 20 || onOutput != nil {
                return try await runner.run(
                    executable: "svn", arguments: arguments, directory: directory,
                    timeout: timeout, opensslConfiguration: configuration, onOutput: onOutput
                )
            }
            return try await commandExecutor(arguments, directory, configuration)
        }
        // 密码只通过本进程 stdin pipe 传入；不出现在 argv、环境变量、文件或错误文本中。
        var authenticated = arguments
        authenticated.insert(contentsOf: ["--username", credential.username, "--password-from-stdin"], at: 0)
        return try await runner.run(
            executable: "svn",
            arguments: authenticated,
            directory: directory,
            timeout: timeout,
            opensslConfiguration: configuration,
            standardInput: Data((credential.password + "\n").utf8),
            onOutput: onOutput
        )
    }

    private func rememberCredentials(_ credential: RepositoryCredentials?, for remoteURL: String) async throws {
        guard let credential else { return }
        guard !credential.username.isEmpty, !credential.password.isEmpty,
              !credential.username.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }),
              !credential.password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw VersionControlError.invalidData("SVN 用户名和密码不能为空，且不能包含换行或空字符。")
        }
        await credentials.store(credential, for: remoteURL)
    }

    private func normalizedRemoteAddress(_ raw: String) throws -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "svn", "svn+ssh", "file"].contains(scheme),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw VersionControlError.invalidRepository("SVN 远端地址无效。")
        }
        if scheme == "file" {
            guard components.host == nil || components.host?.isEmpty == true else {
                throw VersionControlError.invalidRepository("仅支持本机 file:// SVN 地址。")
            }
        } else if components.host?.isEmpty != false {
            throw VersionControlError.invalidRepository("SVN 远端地址缺少主机名。")
        }
        let forbidden = CharacterSet(charactersIn: "/")
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        let normalized = try segments.map { rawSegment -> String in
            guard let decoded = String(rawSegment).removingPercentEncoding,
                  !decoded.isEmpty, decoded != ".", decoded != "..", !decoded.contains("\0"),
                  decoded.rangeOfCharacter(from: forbidden) == nil else {
                throw VersionControlError.invalidRepository("SVN 远端地址包含无效路径。")
            }
            return encodeRemotePathSegment(decoded)
        }
        components.percentEncodedPath = "/" + normalized.joined(separator: "/")
        guard let url = components.url else { throw VersionControlError.invalidRepository("无法构造 SVN 远端地址。") }
        return trimTrailingSlashes(url.absoluteString)
    }

    private func remoteChildURL(parent: String, name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\0"), !name.contains("/") else {
            throw VersionControlError.invalidData("SVN 返回了无效目录名称。")
        }
        return trimTrailingSlashes(parent) + "/" + encodeRemotePathSegment(name)
    }

    private func encodeRemotePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%@")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// SVN 会把最后一个 `@` 解释为 peg revision 分隔符。添加空 peg 可让路径本身包含 `@`。
    private func svnRemoteTarget(_ address: String) -> String { address + "@" }

    private func trimTrailingSlashes(_ value: String) -> String {
        var value = value
        while value.hasSuffix("/") && !value.hasSuffix("://") { value.removeLast() }
        return value
    }

    /// `svn update` 是写操作：先以 `svn info` 只读探测 TLS 模式，再只执行一次更新命令。
    /// 禁止将 update 交给自动降级重试，避免一次失败后无感重复写入工作副本。
    private func probeUpdateTLSMode(in binding: RepositoryBinding) async throws -> SVNAutomaticTLSFallback.Mode {
        guard let remoteURL = binding.remoteURL, !remoteURL.isEmpty else {
            return .modern
        }
        let probeCommand = ["--non-interactive", "--no-auth-cache", "info", "--xml", svnRemoteTarget(remoteURL)]
        let probe = try await tlsFallback.probe(
            remoteURL: remoteURL,
            modern: { try await runRemoteCommand(probeCommand, directory: binding.root, remoteURL: remoteURL, configuration: nil) },
            legacy: {
                try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
                return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                    try await runRemoteCommand(probeCommand, directory: binding.root, remoteURL: remoteURL, configuration: configuration)
                }
            }
        )
        _ = try requireSuccess(probe.result, tool: "svn")
        return probe.mode
    }

    private func runUpdate(
        _ arguments: [String], directory: URL, remoteURL: String?, tlsMode: SVNAutomaticTLSFallback.Mode,
        onOutput: CommandOutputHandler? = nil
    ) async throws -> CommandResult {
        switch tlsMode {
        case .modern:
            return try await runRemoteCommand(arguments, directory: directory, remoteURL: remoteURL, configuration: nil, timeout: 120, onOutput: onOutput)
        case .legacyCompatible:
            try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
            return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                try await runRemoteCommand(
                    arguments, directory: directory, remoteURL: remoteURL,
                    configuration: configuration, timeout: 120, onOutput: onOutput
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

    /// `svnversion` 的最高修订只说明工作副本中至少有一个节点到达该修订，不能据此
    /// 推定某条历史提交已经落在本地。这里仅核对 mixed range 的 rMax：要求它在当前
    /// 绑定目录内的所有变更都是非复制的普通文件，并且每个文件的本地 BASE 都是该修订。
    /// 任何目录、删除、复制、缺失或本地信息读取失败都保守返回 false。
    private func maximumRevisionIsPresentLocally(_ revision: String, in binding: RepositoryBinding) async -> Bool {
        guard let expected = Int(normalizedRevision(revision)), expected > 0 else { return false }
        do {
            let changes = try await changedPaths(in: binding, revision: revision)
            guard !changes.isEmpty,
                  changes.allSatisfy({ $0.action == "M" || ($0.action == "A" && $0.copyFromPath == nil && $0.copyFromRevision == nil) }) else {
                return false
            }

            var paths: [String] = []
            var seen = Set<String>()
            for change in changes where seen.insert(change.path).inserted {
                let local = try CommitFileSnapshot.validatedURL(root: binding.root, path: change.path)
                let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { return false }
                paths.append(change.path)
            }
            guard !paths.isEmpty else { return false }

            // 一次 `svn info --xml` 批量读取所有路径；这是本地工作副本数据库读取，
            // 不触发 update。不能使用 --show-item：多目标输出会附带路径列。
            let result = try await svn(
                ["info", "--xml", "--"] + paths.map(svnTargetPath),
                directory: binding.root
            )
            _ = try requireSuccess(result, tool: "svn")
            let entries = try SVNXMLDocument(data: result.data).infoEntries
            guard entries.count == paths.count else { return false }
            var expectedURLs: [String: String] = [:]
            for path in paths { expectedURLs[path] = try repositoryFileURL(path: path, in: binding) }
            var confirmed = Set<String>()
            for entry in entries {
                guard let rawPath = entry.path, let actualURL = entry.url,
                      let base = entry.revision, Int(base) == expected else { return false }
                let path = relativePath(rawPath, root: binding.root)
                guard let expectedURL = expectedURLs[path],
                      confirmed.insert(path).inserted,
                      sameRepositoryNodeURL(actualURL, expectedURL) else { return false }
            }
            return confirmed.count == paths.count
        } catch {
            return false
        }
    }

    private struct SynchronizationChangedPath {
        let path: String
        let action: String
        let copyFromPath: String?
        let copyFromRevision: String?
    }

    /// 日志是修订的权威变更范围；只接受位于当前工作副本 URL 子树内的路径。
    /// XML 中的路径已经解码，故这里绝不能再按 URL percent decode。
    private func changedPaths(in binding: RepositoryBinding, revision: String) async throws -> [SynchronizationChangedPath] {
        let result = try await svn(
            ["log", "--xml", "-v", "-r", normalizedRevision(revision)],
            directory: binding.root,
            remoteURL: binding.remoteURL
        )
        let document = try SVNXMLDocument(data: result.data)
        let prefix = try await workingCopyRepositoryPath(in: binding)
        var paths: [SynchronizationChangedPath] = []
        for change in document.logEntries.flatMap(\.changedPaths) {
            // 绑定目录的祖先被复制、替换或修改时，不能只核对其中列出的文件。
            // 反向包含检查保留目录边界，避免把相似前缀的兄弟目录当作祖先。
            if let descendant = relativeRepositoryPath(prefix, removing: change.path), !descendant.isEmpty {
                return []
            }
            // 根目录属性变更属于当前绑定范围；不能悄悄滤掉后把同一修订误判为已同步。
            guard let path = relativeRepositoryPath(change.path, removing: prefix) else { continue }
            guard !path.isEmpty else { return [] }
            paths.append(SynchronizationChangedPath(path: path, action: change.action,
                                                    copyFromPath: change.copyFromPath,
                                                    copyFromRevision: change.copyFromRevision))
        }
        return paths
    }

    private func sameRepositoryNodeURL(_ actual: String, _ expected: String) -> Bool {
        guard let actualURL = URL(string: actual), let expectedURL = URL(string: expected),
              let actualComponents = URLComponents(url: actualURL, resolvingAgainstBaseURL: false),
              let expectedComponents = URLComponents(url: expectedURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        return actualComponents.scheme?.lowercased() == expectedComponents.scheme?.lowercased()
            && actualComponents.host?.lowercased() == expectedComponents.host?.lowercased()
            && actualComponents.port == expectedComponents.port
            && decodedURLPath(actualURL) == decodedURLPath(expectedURL)
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
        if detail.contains("E160013") { return true }
        // 新版 SVN 对 `info` 不存在 URL 会组合输出 W170000 与 E200009；只有同时具备
        // “non-existent in revision” 这一明确路径缺失描述时才允许初始化继续，不能吞掉认证/连接错误。
        return detail.contains("W170000") && detail.contains("E200009") && detail.contains("non-existent in revision")
    }

    private func normalizedRepositoryURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func relativePath(_ path: String, root: URL) -> String {
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

    func parseDate(_ value: String?) -> Date {
        guard let value else { return .distantPast }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? .distantPast
    }

    private func optionalDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let date = parseDate(value)
        return date == .distantPast ? nil : date
    }

    private func decodedURLPath(_ url: URL) -> String {
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return encodedPath.removingPercentEncoding ?? encodedPath
    }

    func normalizedRevision(_ revision: String) -> String {
        revision.hasPrefix("r") || revision.hasPrefix("R") ? String(revision.dropFirst()) : revision
    }

    private func historyPageLimit(_ requested: Int) throws -> Int {
        guard (1...500).contains(requested) else {
            throw VersionControlError.invalidData("历史分页大小必须在 1 到 500 之间。")
        }
        return requested
    }

    private func normalizedPagingReference(_ reference: String?) -> String {
        let value = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
        return value.isEmpty ? "HEAD" : normalizedRevision(value)
    }

    /// `nil`、显式 `HEAD` 与指定修订代表不同的首屏请求，不能把它们的游标混用。
    private func historyRequestScope(_ reference: String?) -> String {
        guard let reference else { return "default" }
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        let normalized = normalizedPagingReference(trimmed)
        if normalized.uppercased() == "HEAD" { return "head" }
        return "revision:\(normalized)"
    }

    /// `HEAD` 不能直接写入游标。先通过当前工作副本 URL 固定为数值修订，即使下一页期间
    /// 仓库有新提交，后续查询也只会继续本次快照以下的历史。
    private func resolvedPagingRevision(_ reference: String?, in binding: RepositoryBinding) async throws -> String {
        let requested = normalizedPagingReference(reference)
        if let number = Int(requested), number >= 0 { return String(number) }
        guard requested.uppercased() == "HEAD", let remoteURL = binding.remoteURL, !remoteURL.isEmpty else {
            throw VersionControlError.invalidData("SVN 历史引用必须是修订号或 HEAD。")
        }
        let result = try await svn(
            ["info", "--xml", "-r", "HEAD", svnRemoteTarget(remoteURL)],
            directory: binding.root,
            remoteURL: remoteURL
        )
        guard let revision = try SVNXMLDocument(data: result.data).infoEntry?.revision,
              let number = Int(revision), number >= 0 else {
            throw VersionControlError.invalidData("无法固定 SVN 历史的 HEAD 修订号。")
        }
        return String(number)
    }

    private func svnLogEntries(arguments: [String], in binding: RepositoryBinding) async throws -> [SVNXMLDocument.LogEntry] {
        let result = try await svn(arguments, directory: binding.root, remoteURL: binding.remoteURL)
        return try SVNXMLDocument(data: result.data).logEntries
    }

    private func repositoryHistoryTarget(in binding: RepositoryBinding, pegRevision: String) throws -> String {
        guard let remoteURL = binding.remoteURL, !remoteURL.isEmpty,
              let peg = Int(pegRevision), peg > 0 else {
            throw VersionControlError.invalidRepository("SVN 工作副本缺少远端 URL，无法固定历史分页范围。")
        }
        return "\(remoteURL)@\(peg)"
    }

    private func revision(from entry: SVNXMLDocument.LogEntry) -> Revision {
        Revision(
            id: "r\(entry.revision)", author: entry.author ?? "",
            date: parseDate(entry.date), message: entry.message ?? ""
        )
    }

    private func decodeHistoryCursor(
        _ raw: String,
        binding: RepositoryBinding,
        path: String?,
        reference: String?
    ) throws -> SVNHistoryCursor {
        let cursor = try SVNHistoryCursor.decode(raw)
        guard cursor.version == SVNHistoryCursor.currentVersion,
              cursor.bindingID == binding.id,
              cursor.path == path,
              cursor.nextRevision > 0,
              Int(cursor.reference) != nil,
              Int(cursor.pegRevision) != nil else {
            throw VersionControlError.invalidData("SVN 历史游标不适用于当前仓库或路径，请刷新历史。")
        }
        guard cursor.requestScope == historyRequestScope(reference) else {
            throw VersionControlError.invalidData("SVN 历史游标与当前引用不一致，请刷新历史。")
        }
        return cursor
    }

    private func makeNextHistoryCursor(
        from entries: [SVNXMLDocument.LogEntry],
        state: SVNHistoryCursor
    ) throws -> String? {
        guard let last = entries.last, let revision = Int(last.revision), revision > 1 else { return nil }
        var next = state
        next.nextRevision = revision - 1
        return try next.encode()
    }

    func svnPathArgument(_ path: String) -> String {
        // 结尾 @ 表示没有 peg revision；仅含 @ 的路径需要它，普通路径追加会变成另一个文件名。
        path + "@"
    }

    func svnTargetPath(_ path: String) -> String {
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

    /// 单个迁移任务专用的 SVN 缓存。actor 既保护 `svn switch` 的顺序，也避免调用方在
    /// `await` 间隙并发导出同一工作副本。任何失败都会让会话失效，不能继续使用半更新缓存。
    private actor SVNMigrationSnapshotSession: RepositoryMigrationSnapshotSession {
        private let provider: SVNProvider
        private let plan: MigrationSourcePlan
        private let address: String
        private let anchor: Int
        private let cache: URL
        private let workingCopy: URL
        private let seedWorkingCopy: URL?
        private var tlsMode: SVNAutomaticTLSFallback.Mode?
        private var repositoryUUID: String?
        private var lastRevision: Int?
        private var busy = false
        private var invalidated = false

        init(
            provider: SVNProvider,
            plan: MigrationSourcePlan,
            address: String,
            anchor: Int,
            cache: URL,
            seedWorkingCopy: URL?
        ) {
            self.provider = provider
            self.plan = plan
            self.address = address
            self.anchor = anchor
            self.cache = cache
            self.workingCopy = cache.appendingPathComponent("working-copy", isDirectory: true)
            self.seedWorkingCopy = seedWorkingCopy
        }

        func exportSnapshot(
            revision: MigrationRevision,
            to directory: URL,
            progress: @escaping RepositoryOperationProgressHandler
        ) async throws {
            guard !busy else {
                throw VersionControlError.invalidRepository("SVN 迁移缓存正在导出另一条修订，请等待当前操作完成。")
            }
            guard !invalidated else {
                throw VersionControlError.invalidRepository("SVN 迁移缓存上一操作未完成，不能继续复用。请重新生成迁移预览。")
            }
            busy = true
            defer { busy = false }

            do {
                try Task.checkCancellation()
                let requested = try validatedRevision(revision)
                if let lastRevision {
                    guard requested > lastRevision else {
                        throw VersionControlError.invalidData("SVN 迁移快照必须按计划从旧到新递增导出；r\(requested) 不能接在 r\(lastRevision) 后。")
                    }
                }
                try validateDestination(directory)

                if lastRevision == nil {
                    if let seedWorkingCopy {
                        try await prepareSeed(seedWorkingCopy, progress: progress)
                        // 快照模式常见的首条修订就是本地 BASE。此时已从干净 seed 构造出
                        // 独立缓存，完全没有必要再访问远端或做一次无意义的 switch。
                        if requested != anchor {
                            try await ensureTLSMode(progress: progress)
                            await progress(RepositoryOperationProgress(
                                "增量获取 SVN 快照…",
                                detail: "本地基线已核对，正在切换至 r\(requested)。"
                            ))
                            // 固定 peg 的历史 URL 查询只读远端，和对隔离工作副本的
                            // switch 没有共享状态。并发仅限一个只读查询与一次隔离缓存更新，
                            // 可隐藏每修订一次 info 的 RTT；随后仍必须同时成功
                            // 并以查询到的 URL 核对 switch 结果。
                            async let expectedURL = historicalURL(at: requested, progress: progress)
                            async let switched: Void = switchWorkingCopy(to: requested, progress: progress)
                            let (resolvedURL, _) = try await (expectedURL, switched)
                            try await validateWorkingCopy(at: requested, expectedURL: resolvedURL)
                        }
                    } else {
                        try await ensureTLSMode(progress: progress)
                        await progress(RepositoryOperationProgress(
                            "首次检出 SVN 快照…",
                            detail: "正在检出固定来源的 r\(requested)。"
                        ))
                        // checkout 与固定 peg 的 info 分别只写隔离缓存和只读远端；
                        // 同样可并行，但完成后保留 URL/UUID/精确 revision 的完整核对。
                        async let expectedURL = historicalURL(at: requested, progress: progress)
                        async let checkedOut: Void = checkoutWorkingCopy(at: requested, progress: progress)
                        let (resolvedURL, _) = try await (expectedURL, checkedOut)
                        try await validateWorkingCopy(at: requested, expectedURL: resolvedURL)
                    }
                } else {
                    try await ensureTLSMode(progress: progress)
                    await progress(RepositoryOperationProgress(
                        "增量获取 SVN 快照…",
                        detail: "正在从 r\(lastRevision!) 切换至 r\(requested)。"
                    ))
                    async let expectedURL = historicalURL(at: requested, progress: progress)
                    async let switched: Void = switchWorkingCopy(to: requested, progress: progress)
                    let (resolvedURL, _) = try await (expectedURL, switched)
                    try await validateWorkingCopy(at: requested, expectedURL: resolvedURL)
                }

                try Task.checkCancellation()
                if requested == anchor, lastRevision == nil, seedWorkingCopy != nil {
                    try await validateWorkingCopy(at: requested, expectedURL: address)
                }
                await progress(RepositoryOperationProgress(
                    "本地整理 SVN 快照…",
                    detail: "r\(requested) 已在隔离缓存就绪，正在本地导出，不访问 SVN 服务端。"
                ))
                let exportResult = try await localExport(from: workingCopy, to: directory.standardizedFileURL)
                _ = try requireSuccess(exportResult, tool: "svn")
                try Task.checkCancellation()
                lastRevision = requested
                await progress(RepositoryOperationProgress(
                    "SVN r\(requested) 本地快照已就绪。",
                    detail: "已从隔离缓存导出，不重新拉取该修订。"
                ))
            } catch {
                invalidated = true
                if case VersionControlError.timedOut(let tool) = error, tool == "svn" || tool == "svnversion" {
                    throw VersionControlError.timedOut("\(tool) 准备或核对 \(revision.id) 快照")
                }
                throw error
            }
        }

        private func validatedRevision(_ revision: MigrationRevision) throws -> Int {
            guard plan.revisions.contains(revision) else {
                throw VersionControlError.invalidData("请求导出的修订不在当前固定 SVN 迁移计划中。")
            }
            let value = try provider.numericSVNRevision(revision.id)
            guard value > 0, value <= anchor else {
                throw VersionControlError.invalidData("SVN 导出修订超出固定迁移范围。")
            }
            return value
        }

        private func validateDestination(_ raw: URL) throws {
            let destination = raw.standardizedFileURL
            let manager = FileManager.default
            let cachePath = cache.resolvingSymlinksInPath().path
            let destinationPath = destination.resolvingSymlinksInPath().path
            guard destinationPath != cachePath, !destinationPath.hasPrefix(cachePath + "/") else {
                throw VersionControlError.invalidRepository("迁移快照目标不能位于 SVN 缓存目录内。")
            }
            let isLink = (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != nil
            guard !manager.fileExists(atPath: destination.path), !isLink else {
                throw VersionControlError.invalidRepository("迁移快照目标已存在：\(destination.path)")
            }
            let parent = destination.deletingLastPathComponent().standardizedFileURL
            var parentIsDirectory = ObjCBool(false)
            guard manager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue,
                  (try? manager.destinationOfSymbolicLink(atPath: parent.path)) == nil else {
                throw VersionControlError.invalidRepository("迁移快照目标的父目录不可用：\(parent.path)")
            }
        }

        private func checkoutWorkingCopy(
            at revision: Int,
            progress: @escaping RepositoryOperationProgressHandler
        ) async throws {
            let reporter = SVNTransferProgressReporter(root: workingCopy, operationName: "正在首次检出 SVN…", progress: progress)
            let output: CommandOutputHandler = { lines in
                await reporter.receive(lines: lines.compactMap { $0.stream == .stdout ? $0.text : nil })
            }
            do {
                let result = try await provider.runRemoteWrite(
                    ["--non-interactive", "--no-auth-cache", "checkout", "--ignore-externals", "-r", String(revision), provider.migrationTarget(address, pegRevision: String(anchor)), workingCopy.path],
                    remoteURL: address,
                    tlsMode: try requiredTLSMode(),
                    timeout: 600,
                    onOutput: output
                )
                _ = try requireSuccess(result, tool: "svn")
                await reporter.finish()
            } catch {
                await reporter.finish()
                throw normalizedSnapshotError(error, revision: revision, operation: "首次检出")
            }
        }

        private func switchWorkingCopy(
            to revision: Int,
            progress: @escaping RepositoryOperationProgressHandler
        ) async throws {
            let reporter = SVNTransferProgressReporter(root: workingCopy, operationName: "正在增量获取 SVN…", progress: progress)
            let output: CommandOutputHandler = { lines in
                await reporter.receive(lines: lines.compactMap { $0.stream == .stdout ? $0.text : nil })
            }
            do {
                let result = try await provider.runRemoteWrite(
                    ["--non-interactive", "--no-auth-cache", "switch", "--ignore-externals", "--accept", "postpone", "-r", String(revision), provider.migrationTarget(address, pegRevision: String(anchor)), workingCopy.path],
                    remoteURL: address,
                    tlsMode: try requiredTLSMode(),
                    timeout: 600,
                    onOutput: output
                )
                _ = try requireSuccess(result, tool: "svn")
                await reporter.finish()
            } catch {
                await reporter.finish()
                throw normalizedSnapshotError(error, revision: revision, operation: "增量获取")
            }
        }

        private func prepareSeed(
            _ seed: URL,
            progress: @escaping RepositoryOperationProgressHandler
        ) async throws {
            let seed = seed.standardizedFileURL
            let cachePath = cache.resolvingSymlinksInPath().path
            let seedPath = seed.resolvingSymlinksInPath().path
            guard seedPath != cachePath, !seedPath.hasPrefix(cachePath + "/") else {
                throw VersionControlError.invalidRepository("SVN 本地基线不能位于迁移缓存目录内。")
            }
            await progress(RepositoryOperationProgress(
                "核对本地 SVN 基线…",
                detail: "仅复制已管版本到隔离缓存，不修改当前工作副本。"
            ))
            let info = try await provider.inspectMigrationWorkingCopy(at: seed, requireClean: true)
            let expectedAddress = try provider.normalizedRemoteAddress(plan.location.url)
            guard info.sourceURL == expectedAddress, info.baseRevision == "r\(anchor)" else {
                throw VersionControlError.invalidRepository("本地 SVN 基线与固定迁移来源或 BASE 修订不一致，不能复用。")
            }
            let seedMetadata = seed.appendingPathComponent(".svn", isDirectory: true)
            let manager = FileManager.default
            let seedMetadataLink = (try? manager.destinationOfSymbolicLink(atPath: seedMetadata.path)) != nil
            guard manager.fileExists(atPath: seedMetadata.path), !seedMetadataLink else {
                throw VersionControlError.invalidRepository("本地 SVN 基线元数据不可用，不能复用。")
            }

            await progress(RepositoryOperationProgress(
                "本地整理 SVN 基线…",
                detail: "正在将已管文件和 SVN 元数据复制到隔离缓存，不访问 SVN 服务端。"
            ))
            let beforeDatabase = try seedDatabaseFingerprint(at: seedMetadata)
            let exportResult = try await localExport(from: seed, to: workingCopy)
            _ = try requireSuccess(exportResult, tool: "svn")
            try Task.checkCancellation()
            try manager.copyItem(at: seedMetadata, to: workingCopy.appendingPathComponent(".svn", isDirectory: true))
            guard beforeDatabase == (try seedDatabaseFingerprint(at: seedMetadata)) else {
                throw VersionControlError.invalidRepository("复制 SVN 本地基线期间检测到工作副本元数据变化，拒绝复用该缓存。")
            }
            repositoryUUID = info.repositoryUUID
            try await validateWorkingCopy(at: anchor, expectedURL: address)
        }

        /// 导出只读取本地缓存；它可能遍历大型代码树，因此使用与远端迁移一致的 600 秒
        /// 上限，但不传 remoteURL/TLS 配置，也不报告网络传输统计。
        private func localExport(from source: URL, to destination: URL) async throws -> CommandResult {
            try await provider.runner.run(
                executable: "svn",
                arguments: ["--non-interactive", "--no-auth-cache", "export", "--ignore-externals", provider.svnPathArgument(source.path), destination.path],
                directory: cache,
                timeout: 600
            )
        }

        private func seedDatabaseFingerprint(at metadata: URL) throws -> String {
            let database = metadata.appendingPathComponent("wc.db")
            let manager = FileManager.default
            let isLink = (try? manager.destinationOfSymbolicLink(atPath: database.path)) != nil
            guard manager.fileExists(atPath: database.path), !isLink else {
                throw VersionControlError.invalidRepository("本地 SVN 基线缺少可安全复制的 wc.db。")
            }
            let data = try Data(contentsOf: database, options: .mappedIfSafe)
            #if canImport(CryptoKit)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #else
            // 支持旧系统工具链：同时包含字节数与稳定 hash，仍可发现复制期间的常见变更。
            return "\(data.count):\(data.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 })"
            #endif
        }

        private func ensureTLSMode(progress: @escaping RepositoryOperationProgressHandler) async throws {
            guard tlsMode == nil else { return }
            await progress(RepositoryOperationProgress(
                "探测 SVN 迁移连接…",
                detail: "固定来源 r\(anchor)，仅执行一次 TLS 兼容探测。"
            ))
            tlsMode = try await provider.probeRemoteTLSMode(address)
            try Task.checkCancellation()
        }

        /// 对复制/改名节点，固定 URL 在较早修订可能解析为其历史祖先 URL。先以同一 peg
        /// 查询实际节点 URL，再核对本地 switch 结果，不能把“当前 URL”硬套给旧修订。
        private func historicalURL(at revision: Int, progress: @escaping RepositoryOperationProgressHandler) async throws -> String {
            do {
                let arguments = ["--non-interactive", "--no-auth-cache", "info", "--xml", "-r", String(revision), provider.migrationTarget(address, pegRevision: String(anchor))]
                let mode = try requiredTLSMode()
                let result = try await SVNMigrationMetadataRead.run(revision: revision, progress: progress) {
                    // 保持固定 TLS 模式和认证；只读 info 可重试，绝不重放 switch/checkout。
                    if await self.provider.credentials.credential(for: self.address) != nil {
                        return try await self.provider.runRemoteWrite(arguments, remoteURL: self.address, tlsMode: mode,
                                                                     timeout: SVNMigrationMetadataRead.timeout)
                    }
                    let directory = FileManager.default.temporaryDirectory
                    switch mode {
                    case .modern:
                        return try await self.provider.migrationMetadataExecutor(arguments, directory, nil)
                    case .legacyCompatible:
                        return try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                            try await self.provider.migrationMetadataExecutor(arguments, directory, configuration)
                        }
                    }
                }
                _ = try requireSuccess(result, tool: "svn")
                guard let raw = try SVNXMLDocument(data: result.data).infoEntry?.url else {
                    throw VersionControlError.invalidData("无法核对 SVN r\(revision) 的历史节点 URL。")
                }
                return try provider.normalizedRemoteAddress(raw)
            } catch {
                throw normalizedSnapshotError(error, revision: revision, operation: "查询历史节点")
            }
        }

        private func validateWorkingCopy(at expectedRevision: Int, expectedURL: String) async throws {
            try Task.checkCancellation()
            let info = try await localVerificationCommand("svn", ["--non-interactive", "--no-auth-cache", "info", "--xml", "--depth", "empty"], revision: expectedRevision, phase: "节点核验")
            guard let entry = try SVNXMLDocument(data: info.data).infoEntry,
                  entry.kind == "dir",
                  let url = entry.url,
                  let uuid = entry.repositoryUUID, !uuid.isEmpty,
                  entry.workingCopyRoot.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) == workingCopy.standardizedFileURL.resolvingSymlinksInPath().path else {
                throw VersionControlError.invalidRepository("SVN 迁移缓存不是独立完整的工作副本。")
            }
            guard try provider.normalizedRemoteAddress(url) == expectedURL else {
                throw VersionControlError.invalidRepository("SVN 迁移缓存 URL 与 r\(expectedRevision) 的固定历史节点不一致，拒绝继续导出。")
            }
            if let repositoryUUID {
                guard repositoryUUID == uuid else {
                    throw VersionControlError.invalidRepository("SVN 迁移缓存的仓库 UUID 发生变化，拒绝继续导出。")
                }
            } else {
                repositoryUUID = uuid
            }
            let versionResult = try await localVerificationCommand("svnversion", [], revision: expectedRevision, phase: "版本核验")
            _ = try requireSuccess(versionResult, tool: "svnversion")
            let version = try provider.parseWorkingCopyVersion(versionResult.output, path: nil)
            guard version.minimum == expectedRevision, version.maximum == expectedRevision,
                  !version.flags.contains("M"), !version.flags.contains("S"), !version.flags.contains("P") else {
                throw VersionControlError.invalidRepository("SVN 迁移缓存未处于精确 r\(expectedRevision) 的干净完整状态（\(version.description)）。")
            }
            let status = try await localVerificationCommand("svn", ["--non-interactive", "--no-auth-cache", "status", "--xml", "--no-ignore", "--ignore-externals"], revision: expectedRevision, phase: "状态核验")
            let entries = try SVNXMLDocument(data: status.data).statusEntries
            let dirty = entries.filter { entry in
                entry.item != "normal" || !["normal", "none", ""].contains(entry.properties) || entry.treeConflicted
            }
            guard dirty.isEmpty else {
                throw VersionControlError.invalidRepository("SVN 迁移缓存存在本地修改、切换残留或冲突，拒绝继续导出。")
            }
        }

        private func requiredTLSMode() throws -> SVNAutomaticTLSFallback.Mode {
            guard let tlsMode else {
                throw VersionControlError.invalidData("SVN 迁移连接尚未完成 TLS 探测。")
            }
            return tlsMode
        }

        private func localVerificationCommand(_ tool: String, _ arguments: [String], revision: Int, phase: String) async throws -> CommandResult {
            do {
                // 完整状态核验可能遍历大型目录。保留所有校验，避免沿用普通查询的 20 秒上限。
                let result = try await provider.runner.run(executable: tool, arguments: arguments, directory: workingCopy, timeout: 120)
                return try requireSuccess(result, tool: tool)
            } catch VersionControlError.timedOut {
                throw VersionControlError.timedOut("SVN r\(revision) 本地\(phase)")
            }
        }

        private func normalizedSnapshotError(_ error: Error, revision: Int, operation: String) -> Error {
            if case VersionControlError.timedOut = error {
                return VersionControlError.timedOut("SVN r\(revision) \(operation)")
            }
            if provider.isMissingSVNPath(error) {
                return VersionControlError.invalidData("SVN r\(revision) 无法从固定来源路径导出；该目录可能在此修订尚不存在、已删除，或需要无法解析的复制/改名祖先。请改用快照模式或调整迁移范围。")
            }
            return error
        }
    }
}

/// 游标只在 SVN 适配器内解释。它同时绑定工作副本、引用和文件路径，避免把上一仓库或
/// 另一文件的数值修订错误地带到当前查询中。
private struct SVNHistoryCursor: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let bindingID: String
    let path: String?
    let reference: String
    let requestScope: String
    let pegRevision: String
    var nextRevision: Int

    init(
        version: Int = SVNHistoryCursor.currentVersion,
        bindingID: String,
        path: String?,
        reference: String,
        requestScope: String,
        pegRevision: String,
        nextRevision: Int
    ) {
        self.version = version
        self.bindingID = bindingID
        self.path = path
        self.reference = reference
        self.requestScope = requestScope
        self.pegRevision = pegRevision
        self.nextRevision = nextRevision
    }

    func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        return data.base64EncodedString()
    }

    static func decode(_ value: String) throws -> SVNHistoryCursor {
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(SVNHistoryCursor.self, from: data) else {
            throw VersionControlError.invalidData("SVN 历史游标无效，请刷新历史。")
        }
        return cursor
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

/// 只保存当前应用进程中、明确输入过的凭据。一个作用域只可用于该 URL 及其子路径，
/// 不会因同主机的其他仓库路径而泄漏。
private actor SVNSessionCredentialStore {
    private var values: [String: RepositoryCredentials] = [:]

    func store(_ credential: RepositoryCredentials, for remoteURL: String) {
        values[remoteURL] = credential
    }

    func credential(for remoteURL: String) -> RepositoryCredentials? {
        values
            .filter { remoteURL == $0.key || remoteURL.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}

final class SVNXMLDocument: NSObject, XMLParserDelegate {
    struct InfoEntry {
        var path: String?
        var kind: String?
        var url: String?
        var repositoryRoot: String?
        var repositoryUUID: String?
        var workingCopyRoot: String?
        var revision: String?
        var depth: String?
    }

    struct StatusEntry {
        let path: String
        var item = ""
        var properties = ""
        var treeConflicted = false
        var copied = false
        var movedFrom: String?
        var movedTo: String?
    }

    struct ChangedPath {
        let path: String
        let action: String
        let copyFromPath: String?
        let copyFromRevision: String?
    }

    struct LogEntry {
        var revision = ""
        var author: String?
        var date: String?
        var message: String?
        var changedPaths: [ChangedPath] = []
    }

    struct ListEntry {
        let name: String
        let isDirectory: Bool
        let revision: String?
        let author: String?
        let date: String?
    }

    private(set) var infoEntry: InfoEntry?
    private(set) var infoEntries: [InfoEntry] = []
    private(set) var statusEntries: [StatusEntry] = []
    private(set) var logEntries: [LogEntry] = []
    private(set) var listEntries: [ListEntry] = []
    private var currentStatus: StatusEntry?
    private var currentInfo: InfoEntry?
    private var currentLog: LogEntry?
    private var currentPathAction: String?
    private var currentPathCopyFromPath: String?
    private var currentPathCopyFromRevision: String?
    private var currentList: ListEntry?
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
            currentInfo = InfoEntry(path: attributeDict["path"], kind: attributeDict["kind"], revision: attributeDict["revision"])
        case "entry" where elementStack.contains("status"):
            if let path = attributeDict["path"] { currentStatus = StatusEntry(path: path) }
        case "wc-status":
            currentStatus?.item = attributeDict["item"] ?? ""
            currentStatus?.properties = attributeDict["props"] ?? ""
            currentStatus?.treeConflicted = ["true", "yes"].contains(attributeDict["tree-conflicted"]?.lowercased())
            currentStatus?.copied = ["true", "yes"].contains(attributeDict["copied"]?.lowercased())
            currentStatus?.movedFrom = attributeDict["moved-from"]
            currentStatus?.movedTo = attributeDict["moved-to"]
        case "logentry":
            currentLog = LogEntry(revision: attributeDict["revision"] ?? "")
        case "entry" where elementStack.contains("list"):
            currentList = ListEntry(
                name: "",
                isDirectory: attributeDict["kind"] == "dir",
                revision: nil,
                author: nil,
                date: nil
            )
        case "commit" where currentList != nil:
            currentList = ListEntry(
                name: currentList?.name ?? "",
                isDirectory: currentList?.isDirectory ?? false,
                revision: attributeDict["revision"],
                author: currentList?.author,
                date: currentList?.date
            )
        case "path" where currentLog != nil:
            currentPathAction = attributeDict["action"] ?? ""
            currentPathCopyFromPath = attributeDict["copyfrom-path"]
            currentPathCopyFromRevision = attributeDict["copyfrom-rev"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "url", currentLog == nil { currentInfo?.url = value }
        if elementName == "root", currentLog == nil { currentInfo?.repositoryRoot = value }
        if elementName == "uuid", currentLog == nil { currentInfo?.repositoryUUID = value }
        if elementName == "wcroot-abspath" { currentInfo?.workingCopyRoot = value }
        if elementName == "depth", currentLog == nil { currentInfo?.depth = value }
        if elementName == "author" {
            if currentLog != nil { currentLog?.author = value }
            else if let list = currentList {
                currentList = ListEntry(name: list.name, isDirectory: list.isDirectory,
                                        revision: list.revision, author: value, date: list.date)
            }
        }
        if elementName == "date" {
            if currentLog != nil { currentLog?.date = value }
            else if let list = currentList {
                currentList = ListEntry(name: list.name, isDirectory: list.isDirectory,
                                        revision: list.revision, author: list.author, date: value)
            }
        }
        if elementName == "msg" { currentLog?.message = value }
        // list 的 <name> 允许前后空格；这里不能沿用普通 XML 字段的 trim 后值。
        if elementName == "name", let list = currentList {
            currentList = ListEntry(name: text, isDirectory: list.isDirectory,
                                    revision: list.revision, author: list.author, date: list.date)
        }
        if elementName == "path", let action = currentPathAction {
            // SVN log 的 <path> 是原始节点名，允许前后空格；不能沿用 trim 后的 value。
            currentLog?.changedPaths.append(ChangedPath(path: text, action: action,
                                                        copyFromPath: currentPathCopyFromPath,
                                                        copyFromRevision: currentPathCopyFromRevision))
            currentPathAction = nil
            currentPathCopyFromPath = nil
            currentPathCopyFromRevision = nil
        }
        if elementName == "entry", let status = currentStatus {
            statusEntries.append(status)
            currentStatus = nil
        }
        if elementName == "entry", let info = currentInfo {
            infoEntries.append(info)
            infoEntry = info
            currentInfo = nil
        }
        if elementName == "logentry", let log = currentLog {
            logEntries.append(log)
            currentLog = nil
        }
        if elementName == "entry", let list = currentList, !list.name.isEmpty {
            listEntries.append(list)
            currentList = nil
        }
        _ = elementStack.popLast()
        text = ""
    }
}
