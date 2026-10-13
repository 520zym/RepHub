import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ToolExecution
import VersionControlCore

extension SVNProvider: RepositoryConflictEditingProvider {
    public func contentConflict(in binding: RepositoryBinding, path: String) async throws -> RepositoryContentConflict {
        let loaded = try await loadedConflict(in: binding, path: path)
        return RepositoryContentConflict(binding: binding, path: loaded.path, stateToken: loaded.token,
                                         base: loaded.base, local: loaded.local,
                                         incoming: loaded.incoming, working: loaded.working)
    }

    public func resolveContentConflict(_ request: RepositoryConflictResolutionRequest,
                                       in binding: RepositoryBinding) async throws -> RepositoryConflictResolutionResult {
        try validateConflictText(request.content)
        let loaded = try await loadedConflict(in: binding, path: request.path)
        guard request.stateToken == loaded.token else {
            return RepositoryConflictResolutionResult(outcome: .failed, summary: "冲突文件或 SVN 工作副本已变化，请重新打开后再保存。")
        }
        try Task.checkCancellation()
        try Data(request.content.utf8).write(to: loaded.workingURL, options: .atomic)
        do {
            try Task.checkCancellation()
            // 本地 working-copy resolve 不访问远端；仍沿用 SVNProvider 的受控参数数组入口。
            _ = try requireSuccess(try await runner.run(executable: "svn", arguments: ["resolve", "--non-interactive", "--no-auth-cache", "--accept", "working", "--", svnTargetPath(loaded.path)], directory: binding.root), tool: "svn")
            let status = try await conflictStatus(in: binding, path: loaded.path)
            guard status == nil else {
                return RepositoryConflictResolutionResult(outcome: .unknown,
                                                          summary: "已写入最终内容，但 SVN 仍报告该文件冲突。",
                                                          details: "请刷新工作区并核对冲突状态。")
            }
            return RepositoryConflictResolutionResult(outcome: .succeeded,
                                                      summary: "已保存最终内容并标记 SVN 冲突为已解决。")
        } catch is CancellationError {
            return RepositoryConflictResolutionResult(outcome: .unknown,
                                                      summary: "最终内容可能已写入，但 SVN 冲突状态尚未确认。",
                                                      details: "请刷新工作区，确认该文件是否仍处于冲突状态。")
        } catch {
            return RepositoryConflictResolutionResult(outcome: .unknown,
                                                      summary: "最终内容已写入，但未能确认 SVN 冲突状态。",
                                                      details: RepositoryDisplaySanitizer.redact(error.localizedDescription))
        }
    }
}

private extension SVNProvider {
    struct LoadedConflict {
        let path: String
        let base: String
        let local: String
        let incoming: String
        let working: String
        let workingURL: URL
        let token: String
    }

    func loadedConflict(in binding: RepositoryBinding, path: String) async throws -> LoadedConflict {
        let workingURL = try conflictWorkingURL(path, in: binding)
        guard let status = try await conflictStatus(in: binding, path: path) else {
            throw VersionControlError.invalidRepository("该文件已不处于 SVN 内容冲突状态，请刷新后重试。")
        }
        guard !status.entry.treeConflicted, status.entry.properties != "conflicted" else {
            throw VersionControlError.unsupported("SVN 树冲突或属性冲突不能在 RepHub 中处理。")
        }
        let info = try await svn(["info", "--xml", "--", svnTargetPath(path)], directory: binding.root)
        let locations = try SVNConflictInfoDocument(data: info.data).locations
        guard let baseURL = try conflictArtifactURL(locations.base, root: binding.root),
              let localURL = try conflictArtifactURL(locations.local, root: binding.root),
              let incomingURL = try conflictArtifactURL(locations.incoming, root: binding.root) else {
            throw VersionControlError.unsupported("SVN 未提供完整的冲突版本文件路径，不能安全地在 RepHub 中处理。")
        }
        let base = try conflictText(at: baseURL)
        let local = try conflictText(at: localURL)
        let incoming = try conflictText(at: incomingURL)
        let working = try conflictText(at: workingURL)
        // XML 属性顺序由 SVN 进程决定，不能用序列化原文作为稳定令牌。
        var tokenData = Data([path, status.entry.item, status.entry.properties,
                              String(status.entry.treeConflicted), baseURL.path, localURL.path, incomingURL.path].joined(separator: "\u{0}").utf8)
        for text in [base, local, incoming, working] { tokenData.append(Data(("\u{0}" + text).utf8)) }
        return LoadedConflict(path: path, base: base, local: local, incoming: incoming, working: working,
                              workingURL: workingURL, token: CommitFileSnapshot.fingerprint(data: tokenData))
    }

    func conflictWorkingURL(_ path: String, in binding: RepositoryBinding) throws -> URL {
        guard !path.isEmpty, !path.contains("\0") else { throw VersionControlError.invalidRepository("冲突文件路径无效。") }
        let url = try CommitFileSnapshot.validatedURL(root: binding.root, path: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw VersionControlError.unsupported("符号链接、目录或特殊文件不能在 RepHub 中处理冲突。")
        }
        return url
    }

    /// 返回 XML 原文一并进入令牌，使内容、节点和冲突描述任一变化均拒绝过期保存。
    func conflictStatus(in binding: RepositoryBinding, path: String) async throws -> (entry: SVNXMLDocument.StatusEntry, raw: Data)? {
        let output = try await svn(["status", "--xml", "--", svnTargetPath(path)], directory: binding.root)
        let document = try SVNXMLDocument(data: output.data)
        let entry = document.statusEntries.first { relativePath($0.path, root: binding.root) == path }
        guard let entry else { return nil }
        guard entry.item == "conflicted" else { return nil }
        return (entry, output.data)
    }

    func conflictArtifactURL(_ value: String?, root: URL) throws -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let candidate: URL
        if value.hasPrefix("/") { candidate = URL(fileURLWithPath: value) }
        else { candidate = root.appendingPathComponent(value) }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(rootPath + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw VersionControlError.unsupported("SVN 冲突版本文件不在当前工作副本中或不是普通文件。")
        }
        return resolved
    }

    func conflictText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 4 * 1024 * 1024, !data.contains(0), let value = String(data: data, encoding: .utf8) else {
            throw VersionControlError.unsupported("该 SVN 冲突文件不是 4 MiB 以内的 UTF-8 文本，不能在 RepHub 中处理。")
        }
        return value
    }

    func validateConflictText(_ text: String) throws {
        guard !RepositoryConflictTextResolver.containsMarkers(in: text) else {
            throw VersionControlError.invalidData("最终内容仍含冲突标记，请处理完所有冲突块后再保存。")
        }
        guard text.utf8.count <= 4 * 1024 * 1024, !text.contains("\0") else {
            throw VersionControlError.invalidData("最终文本必须是 4 MiB 以内且不含空字符的 UTF-8 内容。")
        }
    }
}

/// SVN 的 XML 版本在不同系统版本间存在标签差异；只提取文档中已声明的冲突文件路径，
/// 不扫描目录或猜测 r 号文件名。
private final class SVNConflictInfoDocument: NSObject, XMLParserDelegate {
    struct Locations { var base: String?; var local: String?; var incoming: String? }
    private(set) var locations = Locations()
    private var currentElement = ""
    private var text = ""

    init(data: Data) throws {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw VersionControlError.invalidData(parser.parserError?.localizedDescription ?? "svn info XML 无法解析。") }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        text = ""
        for (key, value) in attributeDict {
            accept(value, named: key.lowercased())
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        accept(text.trimmingCharacters(in: .whitespacesAndNewlines), named: elementName.lowercased())
        currentElement = ""
        text = ""
    }

    private func accept(_ value: String, named name: String) {
        guard !value.isEmpty, name.contains("-wc") || name.contains("conflict") || name.contains("base") || name.contains("mine") || name.contains("working") || name.contains("incoming") || name.contains("new") else { return }
        // SVN 1.14 XML：prev-base-file / prev-wc-file / cur-base-file。
        // `cur-base-file` 是传入一侧的新 BASE，不能先被泛化的 base 分支吞掉。
        if name.contains("cur-base") || name.contains("current-base") {
            if locations.incoming == nil { locations.incoming = value }
            return
        }
        if name.contains("prev-wc") || name.contains("previous-wc") {
            if locations.local == nil { locations.local = value }
            return
        }
        if name.contains("prev-base") || name.contains("previous-base") {
            if locations.base == nil { locations.base = value }
            return
        }
        if locations.base == nil, name.contains("old") || name.contains("base") || name.contains("original") { locations.base = value; return }
        if locations.local == nil, name.contains("mine") || name.contains("work") || name.contains("local") || name.contains("-wc") { locations.local = value; return }
        if locations.incoming == nil, name.contains("new") || name.contains("incoming") || name.contains("theirs") { locations.incoming = value }
    }
}
