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
        /// 仅内容列明确表示新增、更新、合并或替换时，才可把本地最终文件大小纳入估算。
        /// 属性更新、删除、冲突和“已存在”都不能代表文件内容的传输字节。
        let observesContentWrite: Bool
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
            change: FileChange(path: path, kind: kind),
            observesContentWrite: [0x41, 0x55, 0x47, 0x52].contains(content)
        )
    }

    static func detail(forCount count: Int, estimatedWrittenBytes: Int64 = 0) -> String {
        let records = "已收到 \(count) 条文件状态记录"
        guard estimatedWrittenBytes > 0 else { return records }
        return "\(records) · 已测得写入 \(ByteCountFormatter.string(fromByteCount: estimatedWrittenBytes, countStyle: .file))（估算）"
    }

    private static func describe(content: UInt8, properties: UInt8, treeConflict: UInt8) -> (String, FileChangeKind) {
        if content == 0x43 || properties == 0x43 || treeConflict == 0x43 { return ("发现冲突", .conflicted) }
        if content == 0x44 { return ("删除", .deleted) }
        // 获取/更新进度面对的是本地工作副本，使用“已写入/已更新”比 SVN 的调度术语“添加/更新”更准确。
        if content == 0x41 { return ("已写入", .added) }
        if content == 0x52 { return ("替换", .renamed) }
        if content == 0x47 { return ("合并", .modified) }
        if content == 0x45 { return ("已存在", .modified) }
        if content == 0x55 || properties == 0x55 { return ("已更新", .modified) }
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
    /// SVN 不会报告网络层字节。这里仅统计已收到状态行且已在目标目录中出现的常规文件大小；
    /// 跳过目录与符号链接，避免递归扫描目录或把链接目标算入传输量。
    private var estimatedWrittenBytes: Int64 = 0
    private var countedPaths: Set<String> = []
    /// 状态行可能先于文件完全落盘；这些路径会在命令退出后再次确认。
    private var unconfirmedPaths: Set<String> = []
    /// 使用单调时钟，系统时间调整不会令速度发生跳变。
    private let startedAtUptime = ProcessInfo.processInfo.systemUptime

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
            if entry.observesContentWrite { observeWrittenFile(at: entry.record.path) }
            if pending.count >= 12 { await flush() }
        }
        // CommandRunner 已按短时间片聚合输出；不要为了继续凑批次而让小型检出一直没有可见反馈。
        await flush()
    }

    func finish() async {
        let newlyConfirmed = confirmPendingWrites()
        if pending.isEmpty, newlyConfirmed {
            await publish(records: [])
        } else {
            await flush()
        }
    }

    private func flush() async {
        guard !pending.isEmpty else { return }
        let records = pending
        pending.removeAll(keepingCapacity: true)
        await publish(records: records)
    }

    private func publish(records: [RepositoryProgressRecord]) async {
        await progress(RepositoryOperationProgress(
            operationName,
            detail: SVNTransferProgressParser.detail(forCount: recordCount, estimatedWrittenBytes: estimatedWrittenBytes),
            records: records,
            transferStatistics: RepositoryTransferStatistics(
                processedBytes: estimatedWrittenBytes,
                elapsed: max(0, ProcessInfo.processInfo.systemUptime - startedAtUptime),
                isEstimated: true
            )
        ))
    }

    private func observeWrittenFile(at relativePath: String?) {
        guard let relativePath, !countedPaths.contains(relativePath) else { return }
        guard let size = observedRegularFileSize(relativePath: relativePath) else {
            unconfirmedPaths.insert(relativePath)
            return
        }
        countedPaths.insert(relativePath)
        unconfirmedPaths.remove(relativePath)
        estimatedWrittenBytes += Int64(size)
    }

    @discardableResult private func confirmPendingWrites() -> Bool {
        var found = false
        for path in unconfirmedPaths {
            guard !countedPaths.contains(path), let size = observedRegularFileSize(relativePath: path) else { continue }
            countedPaths.insert(path)
            estimatedWrittenBytes += Int64(size)
            found = true
        }
        unconfirmedPaths.subtract(countedPaths)
        return found
    }

    /// 不解析目录总量，也不解析/跟随任何符号链接。逐段确认父路径，使 `dir -> /outside`
    /// 形式的链接无法把外部文件计入检出速度。
    private func observedRegularFileSize(relativePath: String) -> Int? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let manager = FileManager.default
        var candidate = root
        guard (try? manager.destinationOfSymbolicLink(atPath: root.path)) == nil else { return nil }
        for component in components {
            candidate.appendPathComponent(String(component), isDirectory: false)
            guard (try? manager.destinationOfSymbolicLink(atPath: candidate.path)) == nil else { return nil }
        }
        guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else { return nil }
        return size
    }
}
