import Foundation
import ToolExecution
import VersionControlCore

extension GitProvider: RepositoryInspectionProvider {
    /// 仅以已提交的对象作为 blame 输入；不会把工作区未提交内容混入追溯结果。
    public func blame(in binding: RepositoryBinding, path: String, reference: String?) async throws -> RepositoryBlame {
        try ensureGit(binding)
        let path = try inspectedPath(path)
        let tracked = try await git(["--literal-pathspecs", "ls-files", "--error-unmatch", "--", path], in: binding.root)
        guard tracked.exitCode == 0 else {
            if tracked.exitCode == 1 {
                throw VersionControlError.invalidRepository("文件未受 Git 管理，无法逐行追溯：\(path)")
            }
            _ = try requireSuccess(tracked, tool: "git")
            throw VersionControlError.invalidRepository("无法确认 Git 文件状态：\(path)")
        }

        let revision = try await inspectedRevision(reference, in: binding.root)
        let result = try await git(
            ["--literal-pathspecs", "blame", "--line-porcelain", "--date=iso-strict", revision, "--", path],
            in: binding.root
        )
        if result.exitCode != 0 {
            throw VersionControlError.executionFailed("无法追溯已提交的 Git 文件 \(path)：\(sanitizedInspectionFailure(result))")
        }
        return RepositoryBlame(path: path, reference: revision, lines: try parseBlame(result.output))
    }

    private func inspectedPath(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw VersionControlError.invalidRepository("逐行追溯需要仓库内的有效文件路径。")
        }
        return path
    }

    private func inspectedRevision(_ requested: String?, in directory: URL) async throws -> String {
        let value = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            let result = try await git(["rev-parse", "--verify", "--end-of-options", "\(value)^{commit}"], in: directory)
            let output = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw VersionControlError.invalidData("Git 未返回可追溯的提交。") }
            return output
        }
        return try await currentHead(in: directory)
    }

    private func parseBlame(_ output: String) throws -> [RepositoryBlameLine] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var result: [RepositoryBlameLine] = []
        while index < lines.count {
            let header = lines[index]
            index += 1
            guard !header.isEmpty else { continue }
            let fields = header.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  fields[0].allSatisfy({ $0.isHexDigit }),
                  let lineNumber = Int(fields[2]) else {
                throw VersionControlError.invalidData("Git blame 输出格式错误。")
            }
            let revisionID = String(fields[0])
            var author = ""
            var authorTime: TimeInterval = 0
            var summary = ""
            var content: String?
            while index < lines.count {
                let field = lines[index]
                index += 1
                if field.hasPrefix("\t") {
                    content = String(field.dropFirst())
                    break
                }
                if field.hasPrefix("author ") { author = String(field.dropFirst("author ".count)) }
                else if field.hasPrefix("author-time ") { authorTime = TimeInterval(field.dropFirst("author-time ".count)) ?? 0 }
                else if field.hasPrefix("summary ") { summary = String(field.dropFirst("summary ".count)) }
            }
            guard let content else { throw VersionControlError.invalidData("Git blame 输出缺少代码行。") }
            let revision = Revision(id: revisionID, author: author, date: Date(timeIntervalSince1970: authorTime), message: summary)
            result.append(RepositoryBlameLine(lineNumber: lineNumber, revision: revision, content: content))
        }
        return result
    }

    private func sanitizedInspectionFailure(_ result: CommandResult) -> String {
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git 退出码 \(result.exitCode)" : text
    }
}
