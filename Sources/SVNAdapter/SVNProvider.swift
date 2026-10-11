import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ToolExecution
import VersionControlCore

/// 仅通过 Subversion 命令行读取工作副本；不保存认证信息，也不修改工作副本。
public struct SVNProvider: VersionControlProvider {
    public let runner: CommandRunner
    private let tlsMode: @Sendable (String?) async -> RepositoryTLSMode

    public init(
        runner: CommandRunner = CommandRunner(),
        tlsMode: @escaping @Sendable (String?) async -> RepositoryTLSMode = { _ in .modern }
    ) {
        self.runner = runner
        self.tlsMode = tlsMode
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
                    capabilities: [.status, .diff, .history]
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

    private func svn(_ arguments: [String], directory: URL, remoteURL: String? = nil) async throws -> CommandResult {
        // --non-interactive 防止凭据提示阻塞 UI；不接受或绕过 TLS 证书错误。
        let command = ["--non-interactive", "--no-auth-cache"] + arguments
        let mode = await tlsMode(remoteURL)
        let result: CommandResult
        if mode == .legacyCompatible, usesHTTPS(remoteURL) {
            try await SVNOpenSSLRuntime.shared.requireOpenSSL3(using: runner)
            let runner = runner
            result = try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                try await runner.run(
                    executable: "svn",
                    arguments: command,
                    directory: directory,
                    opensslConfiguration: configuration
                )
            }
        } else {
            result = try await runner.run(executable: "svn", arguments: command, directory: directory)
        }
        return try requireSuccess(result, tool: "svn")
    }

    private func usesHTTPS(_ remoteURL: String?) -> Bool {
        guard let remoteURL, let components = URLComponents(string: remoteURL) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
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
        if entry.treeConflicted || entry.item == "conflicted" { return .conflicted }
        if entry.properties == "conflicted" { return .conflicted }
        if entry.properties == "modified" { return .modified }
        return switch entry.item {
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

    private func unversionedPaths(in binding: RepositoryBinding) async throws -> [String] {
        let result = try await svn(["status", "--xml"], directory: binding.root)
        let document = try SVNXMLDocument(data: result.data)
        return document.statusEntries
            .filter { $0.item == "unversioned" }
            .map { relativePath($0.path, root: binding.root) }
    }
}

private final class SVNXMLDocument: NSObject, XMLParserDelegate {
    struct InfoEntry {
        var url: String?
        var repositoryRoot: String?
        var workingCopyRoot: String?
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
            infoEntry = InfoEntry()
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
