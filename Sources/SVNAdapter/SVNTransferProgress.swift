import Foundation
import VersionControlCore

/// 把 `svn checkout` / `svn update` 的英文状态行转换为界面可直接展示的记录。
///
/// Subversion 并不会报告可靠的逐文件下载百分比；状态行是工具报告的路径动作，
/// 不保证取消后该文件仍然保留。因此不把它们解释成已完成文件清单或逐文件下载百分比。
enum SVNTransferProgressParser {
    struct Entry: Sendable {
        let record: RepositoryProgressRecord
        let change: FileChange
    }

    static func entry(from line: String, root: URL) -> Entry? {
        let bytes = Array(line.utf8)
        // `svn update` / `checkout` 固定为前四个状态列、一个空格和路径。
        // 仅接受真实状态行，过滤 "Updating..."、"Checked out revision..." 等摘要。
        guard bytes.count > 5, bytes[4] == 0x20 else { return nil }
        let content = bytes[0]
        let properties = bytes[1]
        let treeConflict = bytes[3]
        let recognized: Set<UInt8> = [0x20, 0x41, 0x44, 0x55, 0x43, 0x47, 0x45, 0x52]
        guard recognized.contains(content), recognized.contains(properties),
              treeConflict == 0x20 || treeConflict == 0x43,
              content != 0x20 || properties != 0x20 || treeConflict != 0x20 else {
            return nil
        }

        let rawPath = String(decoding: bytes.dropFirst(5), as: UTF8.self)
        let path = relativePath(rawPath, root: root)
        guard !path.isEmpty else { return nil }

        let (message, kind) = describe(content: content, properties: properties, treeConflict: treeConflict)
        return Entry(
            record: RepositoryProgressRecord(kind: .file, message: message, path: path),
            change: FileChange(path: path, kind: kind)
        )
    }

    static func detail(forCount count: Int) -> String {
        "已收到 \(count) 条文件状态记录"
    }

    private static func describe(content: UInt8, properties: UInt8, treeConflict: UInt8) -> (String, FileChangeKind) {
        if content == 0x43 || properties == 0x43 || treeConflict == 0x43 { return ("发现冲突", .conflicted) }
        if content == 0x44 { return ("删除", .deleted) }
        if content == 0x41 { return ("添加", .added) }
        if content == 0x52 { return ("替换", .renamed) }
        if content == 0x47 { return ("合并", .modified) }
        if content == 0x45 { return ("已存在", .modified) }
        if content == 0x55 || properties == 0x55 { return ("更新", .modified) }
        return ("处理", .modified)
    }

    private static func relativePath(_ path: String, root: URL) -> String {
        let normalizedPath: String
        if path.hasPrefix("./") {
            normalizedPath = String(path.dropFirst(2))
        } else {
            normalizedPath = path
        }
        guard normalizedPath.hasPrefix("/") else { return normalizedPath }

        let rootPath = root.standardizedFileURL.path
        let absolute = URL(fileURLWithPath: normalizedPath).standardizedFileURL.path
        guard absolute == rootPath || absolute.hasPrefix(rootPath + "/") else { return normalizedPath }
        return String(absolute.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// 将命令输出以小批次交给 UI，避免大仓库每一行都触发一次主线程刷新。
actor SVNTransferProgressReporter {
    private let root: URL
    private let progress: RepositoryOperationProgressHandler
    private let operationName: String
    private var recordCount = 0
    private var pending: [RepositoryProgressRecord] = []

    init(root: URL, operationName: String, progress: @escaping RepositoryOperationProgressHandler) {
        self.root = root.standardizedFileURL
        self.operationName = operationName
        self.progress = progress
    }

    func receive(lines: [String]) async {
        for line in lines {
            guard let entry = SVNTransferProgressParser.entry(from: line, root: root) else { continue }
            recordCount += 1
            pending.append(entry.record)
            if pending.count >= 12 { await flush() }
        }
        // CommandRunner 已按短时间片聚合输出；不要为了继续凑批次而让小型检出一直没有可见反馈。
        await flush()
    }

    func finish() async {
        await flush()
    }

    private func flush() async {
        guard !pending.isEmpty else { return }
        let records = pending
        pending.removeAll(keepingCapacity: true)
        await progress(RepositoryOperationProgress(
            operationName,
            detail: SVNTransferProgressParser.detail(forCount: recordCount),
            records: records
        ))
    }
}
