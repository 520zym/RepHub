import Foundation
import VersionControlCore

public struct WorkspaceFileEntry: Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, isSymbolicLink: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }
}

public struct WorkspaceFilePreview: Sendable {
    public let text: String?
    public let message: String?
    public let isTruncated: Bool

    public init(text: String?, message: String?, isTruncated: Bool) {
        self.text = text
        self.message = message
        self.isTruncated = isTruncated
    }
}

/// 只读、按层展开的工作区文件访问服务。
/// 不运行版本控制工具、不递归枚举目录，也不跟随符号链接。
public actor WorkspaceFileService {
    public static let previewLimit = 1_024 * 1_024

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func children(in root: URL, path: String = "") async throws -> [WorkspaceFileEntry] {
        try Task.checkCancellation()
        let resolved = try resolve(root: root, path: path, allowRoot: true)
        guard !resolved.isSymbolicLink else {
            throw VersionControlError.invalidData("符号链接不能作为目录展开。")
        }
        guard resolved.isDirectory else {
            throw VersionControlError.invalidData("所选路径不是目录。")
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try fileManager.contentsOfDirectory(
            at: resolved.url,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        let prefix = normalizedPath(path)
        return try urls.compactMap { child in
            try Task.checkCancellation()
            let name = child.lastPathComponent
            guard !isVersionControlMetadata(name) else { return nil }
            let values = try child.resourceValues(forKeys: keys)
            let isSymbolicLink = values.isSymbolicLink == true
            let isDirectory = values.isDirectory == true && !isSymbolicLink
            return WorkspaceFileEntry(
                path: prefix.isEmpty ? name : "\(prefix)/\(name)",
                name: name,
                isDirectory: isDirectory,
                isSymbolicLink: isSymbolicLink
            )
        }
        .sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    public func preview(in root: URL, path: String) async throws -> WorkspaceFilePreview {
        try Task.checkCancellation()
        let resolved = try resolve(root: root, path: path, allowRoot: false)
        if resolved.isSymbolicLink {
            return WorkspaceFilePreview(text: nil, message: "符号链接不提供预览。", isTruncated: false)
        }
        if resolved.isDirectory {
            return WorkspaceFilePreview(text: nil, message: "目录不能预览。", isTruncated: false)
        }
        if !resolved.isRegularFile {
            return WorkspaceFilePreview(text: nil, message: "只能预览普通文件。", isTruncated: false)
        }

        let handle = try FileHandle(forReadingFrom: resolved.url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.previewLimit + 1) ?? Data()
        let isTruncated = data.count > Self.previewLimit
        let content = isTruncated ? Data(data.prefix(Self.previewLimit)) : data
        guard !content.contains(0) else {
            return WorkspaceFilePreview(text: nil, message: "该文件包含二进制数据，无法按文本预览。", isTruncated: isTruncated)
        }
        guard let text = decodedUTF8(content, mayEndMidCharacter: isTruncated) else {
            return WorkspaceFilePreview(text: nil, message: "该文件不是 UTF-8 文本，无法预览。", isTruncated: isTruncated)
        }
        return WorkspaceFilePreview(
            text: text,
            message: isTruncated ? "文件超过 1 MiB，仅显示前 1 MiB。" : nil,
            isTruncated: isTruncated
        )
    }

    private func resolve(root: URL, path: String, allowRoot: Bool) throws -> ResolvedPath {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VersionControlError.invalidRepository("工作区根目录不可访问。")
        }
        let normalized = normalizedPath(path)
        guard allowRoot || !normalized.isEmpty else {
            throw VersionControlError.invalidData("请选择需要预览的文件。")
        }
        guard isSafeRelativePath(normalized) else {
            throw VersionControlError.invalidData("文件路径超出工作区范围。")
        }
        let components = normalized.split(separator: "/").map(String.init)
        var candidate = rootURL
        for (index, component) in components.enumerated() {
            candidate = candidate.appendingPathComponent(component, isDirectory: false).standardizedFileURL
            let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true && index < components.count - 1 {
                throw VersionControlError.invalidData("符号链接不能作为目录展开。")
            }
        }
        guard isDescendant(candidate, of: rootURL) else {
            throw VersionControlError.invalidData("文件路径超出工作区范围。")
        }
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        return ResolvedPath(
            url: candidate,
            isDirectory: values.isDirectory == true,
            isSymbolicLink: values.isSymbolicLink == true,
            isRegularFile: values.isRegularFile == true
        )
    }

    private func normalizedPath(_ path: String) -> String {
        path
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        if path.isEmpty { return true }
        if path.hasPrefix("/") || path.contains("\\") || path.utf8.contains(0) { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.path
        let rootPath = root.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func isVersionControlMetadata(_ name: String) -> Bool {
        name == ".git" || name == ".svn"
    }

    private func decodedUTF8(_ data: Data, mayEndMidCharacter: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard mayEndMidCharacter else { return nil }
        for numberOfTrailingBytes in 1...3 where data.count > numberOfTrailingBytes {
            if let text = String(data: Data(data.dropLast(numberOfTrailingBytes)), encoding: .utf8) { return text }
        }
        return nil
    }

    private struct ResolvedPath {
        let url: URL
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let isRegularFile: Bool
    }
}
