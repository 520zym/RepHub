import Foundation
import ToolExecution
import VersionControlCore

extension SVNProvider: RepositoryInspectionProvider {
    /// 使用一个明确修订读取 blame 与 cat，避免把本地修改误标为已提交的责任人。
    public func blame(in binding: RepositoryBinding, path: String, reference: String?) async throws -> RepositoryBlame {
        guard binding.providerID == .svn else {
            throw VersionControlError.invalidRepository("该绑定不是 Subversion 工作副本。")
        }
        let path = try inspectedPath(path)
        let requested = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedRevision = normalizedRevision((requested?.isEmpty == false) ? requested! : "BASE")
        let target = svnTargetPath(path)
        let status = try await svn(["status", "--xml", "--", target], directory: binding.root, remoteURL: binding.remoteURL)
        if isUnversionedInspectionPath(status.data) {
            throw VersionControlError.invalidRepository("文件未受 SVN 管理，无法逐行追溯：\(path)")
        }
        let infoResult = try await svn(["info", "--xml", "-r", requestedRevision, "--", target], directory: binding.root, remoteURL: binding.remoteURL)
        guard let info = try SVNXMLDocument(data: infoResult.data).infoEntry,
              let revision = info.revision, UInt64(revision) != nil, let url = info.url else {
            throw VersionControlError.invalidData("SVN 未提供可固定的文件修订。")
        }
        let fixedTarget = url + "@" + revision
        let blame = try await svn(
            ["blame", "--xml", "-r", revision, "--", fixedTarget], directory: binding.root, remoteURL: binding.remoteURL
        )
        let source = try await svn(
            ["cat", "-r", revision, "--", fixedTarget], directory: binding.root, remoteURL: binding.remoteURL
        )
        return RepositoryBlame(path: path, reference: "r\(revision)", lines: try parseBlame(blame.data, source: source.output))
    }

    private func inspectedPath(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw VersionControlError.invalidRepository("逐行追溯需要工作副本内的有效文件路径。")
        }
        return path
    }

    private func isUnversionedInspectionPath(_ data: Data) -> Bool {
        guard let document = try? XMLDocument(data: data, options: []) else { return false }
        return (try? document.nodes(forXPath: "//wc-status[@item='unversioned' or @item='ignored']"))?.isEmpty == false
    }

    private func parseBlame(_ data: Data, source: String) throws -> [RepositoryBlameLine] {
        let document = try XMLDocument(data: data, options: [])
        let entries = try document.nodes(forXPath: "/blame/target/entry")
        let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // `split` 会保留末尾空行；文件恰以换行结束时，那个额外分隔符不对应实际代码行。
        let contents = source.hasSuffix("\n") ? Array(sourceLines.dropLast()) : sourceLines
        var output: [RepositoryBlameLine] = []
        for node in entries {
            guard let element = node as? XMLElement,
                  let rawLine = element.attribute(forName: "line-number")?.stringValue,
                  let lineNumber = Int(rawLine), lineNumber >= 1 else {
                throw VersionControlError.invalidData("SVN blame 输出缺少行号。")
            }
            let commit = element.elements(forName: "commit").first
            let rawRevision = commit?.attribute(forName: "revision")?.stringValue ?? "0"
            let author = commit?.elements(forName: "author").first?.stringValue ?? ""
            let date = parseDate(commit?.elements(forName: "date").first?.stringValue)
            let message = "Subversion r\(rawRevision)"
            let content = lineNumber <= contents.count ? contents[lineNumber - 1] : ""
            output.append(RepositoryBlameLine(
                lineNumber: lineNumber,
                revision: Revision(id: "r\(rawRevision)", author: author, date: date, message: message),
                content: content
            ))
        }
        return output
    }
}
