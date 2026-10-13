import CryptoKit
import Foundation
import ToolExecution
import VersionControlCore

/// SVN 没有可依赖的稳定 shelve 协议，因此使用应用管理的本地文本快照。
extension SVNProvider: RepositoryShelfProvider {
    public func shelfPreview(in binding: RepositoryBinding, includeUntracked: Bool) async throws -> RepositoryShelfPreview {
        let files = try await shelfFiles(in: binding, includeUntracked: includeUntracked)
        let state = try await svnShelfState(in: binding, includeUntracked: includeUntracked)
        var warnings = ["SVN 搁置是本机快照；恢复前会核对 BASE 与目标文件，绝不会覆盖新的本地改动。"]
        if !includeUntracked { warnings.append("未跟踪文件不会包含在本次快照中。") }
        if files.isEmpty { warnings.append("当前范围没有可搁置的改动。") }
        return RepositoryShelfPreview(binding: binding, files: files, stateToken: state, warnings: warnings)
    }

    public func shelves(in binding: RepositoryBinding) async throws -> [RepositoryShelfRecord] {
        let root = shelfRoot(for: binding)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .compactMap { url -> SVNShelfManifest? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                return try? decoder.decode(SVNShelfManifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
            }
            .filter { $0.bindingID == binding.id }
            .sorted { $0.createdAt > $1.createdAt }
            .map { $0.record }
    }

    public func createShelf(in binding: RepositoryBinding, name: String, includeUntracked: Bool,
                            mode: RepositoryShelfMode, expectedStateToken: String) async throws -> RepositoryShelfRecord {
        guard try await svnShelfState(in: binding, includeUntracked: includeUntracked) == expectedStateToken else {
            throw VersionControlError.invalidRepository("工作区修改已变化，请重新查看搁置预览。")
        }
        let files = try await shelfFiles(in: binding, includeUntracked: includeUntracked)
        guard !files.isEmpty else { throw VersionControlError.invalidRepository("当前范围没有可搁置的改动。") }
        let baseRevision = try await svnBaseRevision(in: binding)
        let id = UUID().uuidString.lowercased()
        let folder = shelfRoot(for: binding).appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var entries: [SVNShelfEntry] = []
        do {
            for file in files {
                let source = try shelfFileURL(file.path, root: binding.root)
                let contents = try safeTextData(at: source, path: file.path)
                let baseHash: String?
                if file.kind == .modified {
                    let original = try await svnLocal(["cat", "-r", "BASE", "--", svnTargetPath(file.path)], in: binding.root)
                    baseHash = sha256(try requireSuccess(original, tool: "svn").data)
                } else { baseHash = nil }
                let payload = folder.appendingPathComponent("files", isDirectory: true).appendingPathComponent(file.path)
                try fileManager.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try contents.write(to: payload, options: .atomic)
                entries.append(SVNShelfEntry(path: file.path, kind: file.kind, byteCount: contents.count,
                                             hash: sha256(contents), baseHash: baseHash))
            }
            let record = RepositoryShelfRecord(id: id, providerID: .svn, name: name, files: files, reference: folder.path)
            let manifest = SVNShelfManifest(bindingID: binding.id, rootPath: binding.root.standardizedFileURL.path,
                baseRevision: baseRevision, createdAt: record.createdAt, record: record, entries: entries)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            if mode == .saveAndClean {
                // 清理前逐项复核快照后的内容没有变化，避免 revert 掉刚出现的新修改。
                try await cleanSVNFiles(entries, folder: folder, in: binding)
            }
            return record
        } catch {
            // 已完整生成的 manifest 才可恢复；失败时清理仅本次尚未发布的文件夹。
            if !fileManager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { try? fileManager.removeItem(at: folder) }
            throw error
        }
    }

    public func restoreShelf(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws -> RepositoryShelfRestoreResult {
        let manifest = try readManifest(record: record, binding: binding)
        guard manifest.baseRevision == (try await svnBaseRevision(in: binding)) else {
            throw VersionControlError.invalidRepository("SVN BASE 已变化；为避免覆盖新版本，请更新或重新创建快照后再恢复。")
        }
        guard Set(manifest.entries.map(\.path)).count == manifest.entries.count else {
            throw VersionControlError.invalidData("搁置快照包含重复路径。")
        }
        let changed = try await status(in: binding)
        let changedPaths = Set(changed.map(\.path))
        var prepared: [(SVNShelfEntry, URL, Data)] = []
        for entry in manifest.entries {
            let target = try shelfFileURL(entry.path, root: binding.root)
            if entry.kind == .modified {
                guard !changedPaths.contains(entry.path) else { throw VersionControlError.invalidRepository("文件已有本地改动，未覆盖：\(entry.path)") }
                let base = try await svnLocal(["cat", "-r", "BASE", "--", svnTargetPath(entry.path)], in: binding.root)
                guard sha256(try requireSuccess(base, tool: "svn").data) == entry.baseHash else {
                    throw VersionControlError.invalidRepository("文件 BASE 内容已变化，未覆盖：\(entry.path)")
                }
                guard sha256(try safeTextData(at: target, path: entry.path)) == entry.baseHash else {
                    throw VersionControlError.invalidRepository("文件内容已变化，未覆盖：\(entry.path)")
                }
            } else if fileManager.fileExists(atPath: target.path) {
                throw VersionControlError.invalidRepository("未跟踪文件已存在，未覆盖：\(entry.path)")
            }
            let payload = try shelfPayloadURL(entry.path, folder: URL(fileURLWithPath: record.reference, isDirectory: true))
            let contents = try safeTextData(at: payload, path: entry.path)
            guard contents.count == entry.byteCount, sha256(contents) == entry.hash else {
                throw VersionControlError.invalidData("搁置快照校验失败：\(entry.path)")
            }
            prepared.append((entry, target, contents))
        }
        for (entry, target, contents) in prepared {
            if entry.kind == .modified, sha256(try safeTextData(at: target, path: entry.path)) != entry.baseHash {
                throw VersionControlError.invalidRepository("恢复期间文件发生变化，未覆盖：\(entry.path)")
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try contents.write(to: target, options: .atomic)
        }
        return RepositoryShelfRestoreResult(record: record, summary: "已恢复“\(record.name)”。快照仍保留，可在确认无误后手动删除。")
    }

    public func deleteShelf(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws {
        _ = try readManifest(record: record, binding: binding)
        let folder = URL(fileURLWithPath: record.reference, isDirectory: true).standardizedFileURL
        guard folder.deletingLastPathComponent().standardizedFileURL == shelfRoot(for: binding).standardizedFileURL else {
            throw VersionControlError.invalidRepository("搁置快照位置无效。")
        }
        try fileManager.removeItem(at: folder)
    }

    private var fileManager: FileManager { .default }

    private func shelfFiles(in binding: RepositoryBinding, includeUntracked: Bool) async throws -> [RepositoryShelfFile] {
        try await rejectUnsupportedSVNStatus(in: binding)
        let changes = try await status(in: binding)
        var result: [RepositoryShelfFile] = []
        for change in changes {
            switch change.kind {
            case .modified:
                let data = try safeTextData(at: try shelfFileURL(change.path, root: binding.root), path: change.path)
                result.append(.init(path: change.path, kind: .modified, byteCount: data.count))
            case .untracked where includeUntracked:
                let data = try safeTextData(at: try shelfFileURL(change.path, root: binding.root), path: change.path)
                result.append(.init(path: change.path, kind: .untracked, byteCount: data.count))
            case .untracked: break
            default:
                throw VersionControlError.unsupported("SVN 快照仅支持文本受管修改和普通未跟踪文件；请先处理：\(change.path)")
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// 现有通用 status 会把内容和属性修改都映射为 modified。快照只保存文本内容，
    /// 因此一旦发现属性、复制或树冲突就明确拒绝，绝不能静默丢掉元数据。
    private func rejectUnsupportedSVNStatus(in binding: RepositoryBinding) async throws {
        let result = try await svnLocal(["status", "--xml"], in: binding.root)
        let xml = try requireSuccess(result, tool: "svn").output
        let unsupported = ["props=\"modified\"", "props=\"added\"", "props=\"deleted\"",
                           "tree-conflicted=\"true\"", "copied=\"true\"", "item=\"replaced\""]
        guard !unsupported.contains(where: xml.contains) else {
            throw VersionControlError.unsupported("SVN 快照不支持属性修改、复制、替换或树冲突；请先单独处理这些改动。")
        }
    }

    private func cleanSVNFiles(_ entries: [SVNShelfEntry], folder: URL, in binding: RepositoryBinding) async throws {
        var cleaned: [SVNShelfEntry] = []
        do {
            for entry in entries {
                let target = try shelfFileURL(entry.path, root: binding.root)
                guard sha256(try safeTextData(at: target, path: entry.path)) == entry.hash else {
                    throw VersionControlError.invalidRepository("快照后文件又发生变化，未清理：\(entry.path)")
                }
                if entry.kind == .modified {
                    _ = try requireSuccess(try await svnLocal(["revert", "--", svnTargetPath(entry.path)], in: binding.root), tool: "svn")
                } else { try fileManager.removeItem(at: target) }
                cleaned.append(entry)
            }
        } catch {
            var failures: [String] = []
            for entry in cleaned.reversed() {
                do {
                    let data = try safeTextData(at: shelfPayloadURL(entry.path, folder: folder), path: entry.path)
                    let target = try shelfFileURL(entry.path, root: binding.root)
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try data.write(to: target, options: .atomic)
                } catch { failures.append(entry.path) }
            }
            let rollback = failures.isEmpty ? "已恢复此前已清理的文件。" : "以下文件未能自动恢复：\(failures.joined(separator: "、"))。"
            throw VersionControlError.executionFailed("清理未完成；\(rollback) \(error.localizedDescription)")
        }
    }

    private func svnShelfState(in binding: RepositoryBinding, includeUntracked: Bool) async throws -> String {
        let base = try await svnBaseRevision(in: binding)
        let files = try await shelfFiles(in: binding, includeUntracked: includeUntracked)
        let signature = try files.map { file -> String in
            let data = try safeTextData(at: try shelfFileURL(file.path, root: binding.root), path: file.path)
            return "\(file.kind.rawValue):\(file.path):\(sha256(data))"
        }.joined(separator: "|")
        return "\(base)|\(signature)"
    }

    private func svnBaseRevision(in binding: RepositoryBinding) async throws -> String {
        let result = try await svnLocal(["info", "--show-item", "revision"], in: binding.root)
        let revision = try requireSuccess(result, tool: "svn").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty, revision.allSatisfy(\.isNumber) else { throw VersionControlError.invalidData("无法读取 SVN 工作副本 BASE。") }
        return revision
    }

    private func svnLocal(_ arguments: [String], in directory: URL) async throws -> CommandResult {
        try await runner.run(executable: "svn", arguments: ["--non-interactive", "--no-auth-cache"] + arguments, directory: directory)
    }

    private func shelfRoot(for binding: RepositoryBinding) -> URL {
        if let shelfStorageDirectory { return shelfStorageDirectory.appendingPathComponent(sha256(Data(binding.id.utf8)), isDirectory: true) }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("RepHub", isDirectory: true).appendingPathComponent("Shelves", isDirectory: true)
            .appendingPathComponent(sha256(Data(binding.id.utf8)), isDirectory: true)
    }

    private func shelfFileURL(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw VersionControlError.invalidRepository("搁置文件路径无效。")
        }
        guard !path.split(separator: "/").contains(where: { [".git", ".svn"].contains($0.lowercased()) }) else {
            throw VersionControlError.invalidRepository("不能搁置版本控制内部文件。")
        }
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw VersionControlError.invalidRepository("搁置文件越出工作区。") }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedTarget = target.resolvingSymlinksInPath().path
        guard resolvedTarget.hasPrefix(resolvedRoot + "/") else {
            throw VersionControlError.unsupported("搁置路径包含指向工作区外的符号链接：\(path)")
        }
        var cursor = root.standardizedFileURL
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if fileManager.fileExists(atPath: cursor.path), try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw VersionControlError.unsupported("搁置路径包含符号链接：\(path)")
            }
        }
        return target
    }

    private func shelfPayloadURL(_ path: String, folder: URL) throws -> URL {
        let root = folder.appendingPathComponent("files", isDirectory: true)
        // 复用同一套相对路径和链接校验；payload 不允许绕出受控快照目录。
        return try shelfFileURL(path, root: root)
    }

    private func safeTextData(at url: URL, path: String) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VersionControlError.unsupported("仅支持普通文件：\(path)") }
        guard (values.fileSize ?? 0) <= 8 * 1024 * 1024 else { throw VersionControlError.unsupported("文件超过 8 MiB，不能创建 SVN 文本快照：\(path)") }
        let data = try Data(contentsOf: url)
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw VersionControlError.unsupported("仅支持 UTF-8 文本文件：\(path)") }
        return data
    }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func readManifest(record: RepositoryShelfRecord, binding: RepositoryBinding) throws -> SVNShelfManifest {
        guard record.providerID == .svn else { throw VersionControlError.invalidRepository("搁置记录不是 SVN 快照。") }
        let folder = URL(fileURLWithPath: record.reference, isDirectory: true).standardizedFileURL
        let expectedRoot = shelfRoot(for: binding).standardizedFileURL
        guard folder.deletingLastPathComponent() == expectedRoot,
              folder.resolvingSymlinksInPath().deletingLastPathComponent() == expectedRoot.resolvingSymlinksInPath(),
              try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw VersionControlError.invalidRepository("搁置快照位置无效。")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SVNShelfManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        guard manifest.bindingID == binding.id, manifest.rootPath == binding.root.standardizedFileURL.path, manifest.record.id == record.id, manifest.record.providerID == .svn, manifest.record.reference == folder.path else {
            throw VersionControlError.invalidData("搁置快照与当前工作副本不匹配。")
        }
        return manifest
    }
}

private struct SVNShelfManifest: Codable {
    let bindingID: String; let rootPath: String; let baseRevision: String; let createdAt: Date
    let record: RepositoryShelfRecord; let entries: [SVNShelfEntry]
}

private struct SVNShelfEntry: Codable {
    let path: String; let kind: RepositoryShelfFile.Kind; let byteCount: Int; let hash: String; let baseHash: String?
}
