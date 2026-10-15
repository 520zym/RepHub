import Foundation
import VersionControlCore

/// 供 Quick Look 读取的历史文档私有快照。
///
/// 快照只写入本应用创建的临时目录；当预览模型及 Quick Look 的最后一个快照引用释放时，
/// 会删除该目录，不会改动工作副本或其他临时文件。
public final class RepositoryDocumentSnapshot: Sendable {
    /// 保留原扩展名的只读快照文件，供系统 Quick Look 选择相应预览器。
    public let fileURL: URL

    private let directoryURL: URL

    init(fileURL: URL, directoryURL: URL) {
        self.fileURL = fileURL
        self.directoryURL = directoryURL
    }

    deinit {
        // 目录由本类型以 UUID 创建且从不接收外部路径，故只清理自己的快照目录。
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

public extension RepositoryService {
    /// 从指定历史节点读取常见办公文档，写入私有快照后交给系统 Quick Look。
    /// 绝不回退、检出或写入当前工作副本。
    func documentPreview(in binding: RepositoryBinding, path: String,
                         revision: String, pegRevision: String? = nil) async throws -> WorkspaceFilePreview {
        try validateDocumentPreviewPath(path)
        let revision = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else {
            throw VersionControlError.invalidRepository("请选择需要查看的历史节点。")
        }
        guard let documentKind = WorkspaceDocumentPreviewKind(path: path) else {
            throw VersionControlError.unsupported("当前文件类型不能使用系统文档预览。")
        }
        guard let provider = try provider(for: binding) as? any RepositoryFileContentProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持读取历史文件内容。")
        }

        try Task.checkCancellation()
        let content: Data?
        do {
            content = try await provider.fileContent(in: binding, path: path, revision: revision,
                                                     pegRevision: pegRevision)
        } catch is CancellationError {
            throw CancellationError()
        } catch VersionControlError.outputTooLarge {
            return Self.limitedDocumentPreview(kind: documentKind, revision: revision)
        }
        guard let data = content else {
            return WorkspaceFilePreview(
                text: nil,
                message: "该节点中不存在文件（可能已删除）。",
                isTruncated: false,
                documentKind: documentKind,
                revisionID: revision
            )
        }
        try Task.checkCancellation()
        guard data.count <= Self.documentPreviewFileSizeLimit else {
            return Self.limitedDocumentPreview(kind: documentKind, revision: revision)
        }

        let snapshot = try makeDocumentSnapshot(data: data, originalPath: path)
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.fileURL.path)
        let identity = WorkspaceSystemPreviewIdentity(
            modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0,
            fileSize: data.count
        )
        return WorkspaceFilePreview(
            text: nil,
            message: "二进制文档无法显示内容差异，正在显示该历史节点的实际内容。",
            isTruncated: false,
            systemPreviewURL: snapshot.fileURL,
            documentKind: documentKind,
            systemPreviewIdentity: identity,
            documentSnapshot: snapshot,
            revisionID: revision
        )
    }
}

private extension RepositoryService {
    static let documentPreviewFileSizeLimit = 16 * 1_024 * 1_024

    static func limitedDocumentPreview(kind: WorkspaceDocumentPreviewKind,
                                       revision: String) -> WorkspaceFilePreview {
        WorkspaceFilePreview(
            text: nil,
            message: "历史文档超过 16 MiB 预览限制，未生成系统预览。",
            isTruncated: false,
            documentKind: kind,
            revisionID: revision
        )
    }

    func validateDocumentPreviewPath(_ path: String) throws {
        try validateRelativeFilePath(path)
        guard !path.contains("\\") else {
            throw VersionControlError.invalidRepository("文件路径必须位于当前工作副本内。")
        }
    }

    func makeDocumentSnapshot(data: Data, originalPath: String) throws -> RepositoryDocumentSnapshot {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("RepHub-HistoryDocument-\(UUID().uuidString)", isDirectory: true)
        let ext = (originalPath as NSString).pathExtension.lowercased()
        let fileURL = directory.appendingPathComponent("history.\(ext)", isDirectory: false)
        var directoryCreated = false
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            directoryCreated = true
            guard fileManager.createFile(atPath: fileURL.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
                throw VersionControlError.executionFailed("无法创建历史文档预览快照。")
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            return RepositoryDocumentSnapshot(fileURL: fileURL, directoryURL: directory)
        } catch {
            if directoryCreated { try? fileManager.removeItem(at: directory) }
            throw error
        }
    }
}
