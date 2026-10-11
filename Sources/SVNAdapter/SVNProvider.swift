import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ToolExecution
import VersionControlCore

/// 通过 Subversion 命令行读取工作副本，并执行受限的更新、远端浏览和检出操作。
/// 用户输入的认证信息只保留在当前进程内存中，不写入 SVN 认证缓存。
public struct SVNProvider: RepositoryOperationProvider, RepositoryHistoryProvider, RepositoryAcquisitionProvider, RepositoryCommitProvider {
    public let runner: CommandRunner
    private let tlsFallback: SVNAutomaticTLSFallback
    private let commandExecutor: @Sendable ([String], URL, URL?) async throws -> CommandResult
    private let credentials = SVNSessionCredentialStore()

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
    public let acquisitionOption = RepositoryAcquisitionOption(
        providerID: .svn,
        title: "SVN",
        actionTitle: "检出",
        supportsBrowsing: true,
        supportsCredentials: true
    )

    public func browseRemote(_ location: RemoteRepositoryLocation) async throws -> RemoteDirectoryListing {
        let address = try normalizedRemoteAddress(location.url)
        try await rememberCredentials(location.credentials, for: address)
        let command = ["list", "--xml", svnRemoteTarget(address)]
        let result = try await runRemoteRead(command, remoteURL: address)
        let document = try SVNXMLDocument(data: result.data)
        let entries = try document.listEntries.map { entry in
            let childURL = try remoteChildURL(parent: address, name: entry.name)
            return RemoteDirectoryEntry(name: entry.name, url: childURL, isDirectory: entry.isDirectory)
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
                    capabilities: [.status, .diff, .history, .update, .fileHistory, .synchronization, .commit]
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

    public func prepareCommit(in binding: RepositoryBinding) async throws -> RepositoryCommitPreparation {
        let baseRevision = try await workingCopyRevision(in: binding)
        let changes = try await expandedCommitChanges(in: binding)
        var files: [RepositoryCommitFile] = []
        for change in changes {
            files.append(try await commitFile(change: change, in: binding))
        }
        let restricted = files.filter { $0.restriction != nil }.count
        return RepositoryCommitPreparation(
            binding: binding,
            baseRevision: baseRevision,
            files: files,
            notice: restricted == 0
                ? "已按当前工作副本状态生成提交预览。"
                : "其中 \(restricted) 个路径不能安全地按单文件范围提交。",
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
            // svn status 对未受控目录可能只显示根目录。提交预览展开为叶子文件，
            // 让用户明确选择，而不会把整个目录递归交给 svn add。
            result.append(contentsOf: try untrackedLeafFiles(in: url, root: binding.root))
        }
        var paths = Set<String>()
        return result.filter { paths.insert($0.path).inserted }
    }

    private func untrackedLeafFiles(in directory: URL, root: URL) throws -> [FileChange] {
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
            if values.isDirectory == true, values.isSymbolicLink != true { continue }
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
            let prefix = "新增未受 SVN 管理的文件：\(path)\n\n"
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
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
        return RepositoryCommitFile(change: FileChange(path: path, kind: change.kind), fingerprint: snapshot, restriction: restriction)
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
        let url = binding.root.appendingPathComponent(path)
        var directory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            return "目录提交可能包含未选择的子项；请逐个选择文件提交。"
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

    private func svn(_ arguments: [String], directory: URL, remoteURL: String? = nil) async throws -> CommandResult {
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

private final class SVNXMLDocument: NSObject, XMLParserDelegate {
    struct InfoEntry {
        var kind: String?
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
        var copied = false
        var movedFrom: String?
        var movedTo: String?
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

    struct ListEntry {
        let name: String
        let isDirectory: Bool
    }

    private(set) var infoEntry: InfoEntry?
    private(set) var statusEntries: [StatusEntry] = []
    private(set) var logEntries: [LogEntry] = []
    private(set) var listEntries: [ListEntry] = []
    private var currentStatus: StatusEntry?
    private var currentLog: LogEntry?
    private var currentPathAction: String?
    private var currentListKind: String?
    private var currentListName: String?
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
            infoEntry = InfoEntry(kind: attributeDict["kind"], revision: attributeDict["revision"])
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
            currentListKind = attributeDict["kind"]
            currentListName = nil
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
        // list 的 <name> 允许前后空格；这里不能沿用普通 XML 字段的 trim 后值。
        if elementName == "name", currentListKind != nil { currentListName = text }
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
        if elementName == "entry", let kind = currentListKind, let name = currentListName {
            listEntries.append(ListEntry(name: name, isDirectory: kind == "dir"))
            currentListKind = nil
            currentListName = nil
        }
        _ = elementStack.popLast()
        text = ""
    }
}
