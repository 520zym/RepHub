import Foundation
import ToolExecution
import VersionControlCore

/// 指定 SVN 历史节点的原始文件读取。
///
/// 这里始终先读取工作副本根的 URL，再使用“操作修订 + peg 修订”访问远端节点。这样即使
/// 本地文件已删除、尚未更新，或该文件曾跨目录改名，也不会意外退回工作副本或 HEAD 内容。
extension SVNProvider: RepositoryFileContentProvider {
    public func fileContent(
        in binding: RepositoryBinding,
        path: String,
        revision: String,
        pegRevision: String? = nil
    ) async throws -> Data? {
        let rootInfo = try await svn(["info", "--xml"], directory: binding.root, remoteURL: binding.remoteURL)
        guard let rootURL = try SVNXMLDocument(data: rootInfo.data).infoEntry?.url,
              !rootURL.isEmpty else {
            throw VersionControlError.invalidRepository("SVN 工作副本缺少根 URL，无法读取历史文件内容。")
        }

        let contentRevision = try fixedContentRevision(revision)
        let requestedPeg = pegRevision ?? revision
        let peg = try await resolvedPegRevision(requestedPeg, rootURL: rootURL, binding: binding)
        let target = try historicalFileTarget(rootURL: rootURL, path: path, pegRevision: peg)

        let info: CommandResult
        do {
            info = try await svn(
                ["info", "--xml", "-r", contentRevision, target],
                directory: binding.root,
                remoteURL: rootURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 只有服务端明确说明该节点在指定修订不存在时才用 nil 表示；认证、TLS 和网络错误
            // 必须留给上层展示，不能被伪装成“没有内容”。
            guard isMissingHistoricalNode(error) else { throw error }
            return nil
        }

        guard let entry = try SVNXMLDocument(data: info.data).infoEntry else {
            throw VersionControlError.invalidData("svn info 未返回历史节点信息。")
        }
        guard let kind = entry.kind else {
            throw VersionControlError.invalidData("svn info 未返回历史节点类型。")
        }
        guard kind == "file" else {
            throw VersionControlError.unsupported("只能预览 SVN 普通文件，目录不能显示节点内容。")
        }

        // `svn propget` 在属性不存在时会返回非零退出码，普通文件因此会被误判为失败。
        // `proplist --xml` 则会稳定返回空属性列表，且仍通过同一 TLS/认证会话读取指定节点。
        let properties = try await svn(
            ["proplist", "--xml", "-r", contentRevision, target],
            directory: binding.root,
            remoteURL: rootURL
        )
        guard !hasSVNSpecialProperty(properties.data) else {
            throw VersionControlError.unsupported("SVN 符号链接不能作为普通文件预览。")
        }

        let result = try await svn(
            ["cat", "-r", contentRevision, target],
            directory: binding.root,
            remoteURL: rootURL
        )
        // CommandRunner 的 16 MiB 输出限制保留在底层；这里不会放宽，也不会交付截断数据。
        return result.data
    }

    private func fixedContentRevision(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.hasPrefix("r") || value.hasPrefix("R") ? String(value.dropFirst()) : value
        guard let number = Int(normalized), number >= 0, String(number) == normalized else {
            throw VersionControlError.invalidData("SVN 历史内容必须使用固定的数字修订号：\(raw)")
        }
        return String(number)
    }

    private func resolvedPegRevision(
        _ raw: String,
        rootURL: String,
        binding: RepositoryBinding
    ) async throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.hasPrefix("r") || value.hasPrefix("R") ? String(value.dropFirst()) : value
        if let number = Int(normalized), number >= 0, String(number) == normalized { return String(number) }
        guard normalized.uppercased() == "HEAD" else {
            throw VersionControlError.invalidData("SVN 历史节点必须使用数字修订号或 HEAD：\(raw)")
        }
        let result = try await svn(
            ["info", "--xml", "-r", "HEAD", svnURLWithEmptyPeg(rootURL)],
            directory: binding.root,
            remoteURL: rootURL
        )
        guard let revision = try SVNXMLDocument(data: result.data).infoEntry?.revision,
              let number = Int(revision), number >= 0 else {
            throw VersionControlError.invalidData("无法固定 SVN HEAD 修订号。")
        }
        return String(number)
    }

    private func historicalFileTarget(rootURL: String, path: String, pegRevision: String) throws -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw VersionControlError.invalidData("SVN 历史文件路径无效：\(path)")
        }
        guard var components = URLComponents(string: rootURL) else {
            throw VersionControlError.invalidRepository("SVN 工作副本根 URL 无效。")
        }
        let encodedPath = segments.map(encodeHistoricalPathSegment).joined(separator: "/")
        let rootPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = rootPath.isEmpty ? "/\(encodedPath)" : "/\(rootPath)/\(encodedPath)"
        guard let fileURL = components.url else {
            throw VersionControlError.invalidData("无法构造 SVN 历史文件 URL。")
        }
        return "\(fileURL.absoluteString)@\(pegRevision)"
    }

    private func svnURLWithEmptyPeg(_ value: String) -> String { value + "@" }

    private func encodeHistoricalPathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%@")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func isMissingHistoricalNode(_ error: Error) -> Bool {
        guard case let VersionControlError.executionFailed(detail) = error else { return false }
        if detail.contains("E160013") { return true }
        return detail.contains("W170000") && detail.contains("E200009") && detail.contains("non-existent in revision")
    }

    private func hasSVNSpecialProperty(_ data: Data) -> Bool {
        let xml = String(decoding: data, as: UTF8.self)
        return xml.contains("name=\"svn:special\"") || xml.contains("name='svn:special'")
    }
}
