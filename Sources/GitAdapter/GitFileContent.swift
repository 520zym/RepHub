import Foundation
import ToolExecution
import VersionControlCore

/// 从某个已固定的 Git 提交读取树中的普通 blob。
///
/// 这里不使用 `show`：`show` 可以被属性、文本转换或外部差异工具影响；通过
/// `ls-tree` 确认对象类型和大小后再以对象 ID 调用 `cat-file blob`，得到的就是
/// 该提交树记录的原始字节。
extension GitProvider: RepositoryFileContentProvider {
    public func fileContent(
        in binding: RepositoryBinding,
        path: String,
        revision: String,
        pegRevision: String? = nil
    ) async throws -> Data? {
        try ensureGit(binding)
        // Git 的提交对象本身已经固定内容；peg 仅供 SVN 的复制／改名历史追溯，不能替代 revision。
        _ = pegRevision
        let safePath = try validatedHistoricalBlobPath(path)
        let commit = try await validatedHistoricalCommit(revision, in: binding.root)

        let listing = try requireSuccess(
            try await git(
                ["--literal-pathspecs", "ls-tree", "-z", "--full-tree", commit, "--", safePath],
                in: binding.root
            ),
            tool: "git"
        )
        guard let record = listing.data.split(separator: 0, omittingEmptySubsequences: true).first else {
            // 历史节点没有这个路径（包含删除后的节点）是唯一的 nil 情形。
            return nil
        }
        let entry = try historicalBlobEntry(from: Data(record), expectedPath: safePath)

        let objectSize = try requireSuccess(
            try await git(["cat-file", "-s", entry.objectID], in: binding.root),
            tool: "git"
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bytes = Int64(objectSize), bytes >= 0 else {
            throw VersionControlError.invalidData("Git blob 大小格式无效。")
        }
        guard bytes <= Self.maximumHistoricalBlobBytes else {
            throw VersionControlError.unsupported("该历史文件超过 16 MiB，未读取不完整的二进制内容。")
        }

        do {
            let content = try requireSuccess(
                try await git(["cat-file", "blob", entry.objectID], in: binding.root, timeout: 60),
                tool: "git"
            ).data
            guard content.count == Int(bytes) else {
                throw VersionControlError.invalidData("Git blob 读取长度与对象记录不一致。")
            }
            return content
        } catch VersionControlError.outputTooLarge {
            // CommandRunner 与此处共享 16 MiB 上限；仍转换成面向调用方的完整性说明。
            throw VersionControlError.unsupported("该历史文件超过 16 MiB，未读取不完整的二进制内容。")
        }
    }
}

private extension GitProvider {
    static let maximumHistoricalBlobBytes: Int64 = 16 * 1024 * 1024

    struct HistoricalBlobEntry {
        let objectID: String
    }

    func validatedHistoricalCommit(_ revision: String, in directory: URL) async throws -> String {
        // 文件历史条目必须携带不可变对象 ID；不能以 HEAD、分支或 tag 读取而意外落到别的节点。
        guard isGitObjectID(revision) else {
            throw VersionControlError.invalidData("Git 历史节点必须是完整的提交 ID。")
        }
        let result = try await git(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", "\(revision)^{commit}"],
            in: directory
        )
        guard result.exitCode == 0 else {
            if result.exitCode == 1 || result.exitCode == 128 {
                throw VersionControlError.invalidData("Git 历史节点不存在或不是提交。")
            }
            _ = try requireSuccess(result, tool: "git")
            throw VersionControlError.invalidData("无法校验 Git 历史节点。")
        }
        let resolved = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.caseInsensitiveCompare(revision) == .orderedSame else {
            throw VersionControlError.invalidData("Git 历史节点校验不一致。")
        }
        return resolved
    }

    func validatedHistoricalBlobPath(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame || $0.caseInsensitiveCompare(".svn") == .orderedSame }) else {
            throw VersionControlError.invalidData("Git 历史文件路径无效。")
        }
        return path
    }

    func historicalBlobEntry(from record: Data, expectedPath: String) throws -> HistoricalBlobEntry {
        let components = record.split(separator: 9, maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              String(decoding: components[1], as: UTF8.self) == expectedPath else {
            throw VersionControlError.invalidData("Git 树记录与请求路径不一致。")
        }
        let metadata = components[0].split(separator: 32, omittingEmptySubsequences: true)
        guard metadata.count == 3 else {
            throw VersionControlError.invalidData("Git 树记录格式无效。")
        }
        let mode = String(decoding: metadata[0], as: UTF8.self)
        let type = String(decoding: metadata[1], as: UTF8.self)
        let objectID = String(decoding: metadata[2], as: UTF8.self)
        guard type == "blob", isGitObjectID(objectID) else {
            throw VersionControlError.unsupported("历史路径不是可预览的普通文件。")
        }
        guard mode == "100644" || mode == "100755" else {
            if mode == "120000" {
                throw VersionControlError.unsupported("历史路径是符号链接，不能作为文档内容预览。")
            }
            throw VersionControlError.unsupported("历史路径不是可预览的普通文件。")
        }
        return HistoricalBlobEntry(objectID: objectID)
    }
}
