import Foundation
import Darwin
import VersionControlCore

public struct CommandResult: Sendable {
    public let data: Data
    public let errorData: Data
    public let exitCode: Int32
    public var output: String { String(decoding: data, as: UTF8.self) }
    public var error: String { String(decoding: errorData, as: UTF8.self) }
    public init(data: Data, errorData: Data = Data(), exitCode: Int32) {
        self.data = data; self.errorData = errorData; self.exitCode = exitCode
    }
}

/// 一行由外部工具输出的文本。进度工具常以回车覆盖同一行，因此 `\r` 也会作为分隔符。
public struct CommandOutputLine: Sendable, Equatable {
    public enum Stream: Sendable, Equatable { case stdout, stderr }
    public let stream: Stream
    public let text: String

    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }
}

/// 命令运行时的增量文本输出。只用于用户可见的进度，不应用它判断命令是否成功。
public typealias CommandOutputHandler = @Sendable ([CommandOutputLine]) async -> Void

@discardableResult public func requireSuccess(_ result: CommandResult, tool: String) throws -> CommandResult {
    guard result.exitCode == 0 else {
        let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@]+@"#, with: "$1***@", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)([?&](?:access_token|token|api_key|password)=)[^\s&#]+"#, with: "$1***", options: .regularExpression)
        throw VersionControlError.executionFailed("\(tool)（退出码 \(result.exitCode)）：\(detail.isEmpty ? "操作未完成" : String(detail.prefix(2400)))")
    }
    return result
}

public enum ToolLocator {
    public static func find(_ tool: String) -> String? {
        if tool.contains("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(tool).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Executes argument arrays without a shell. Files, rather than pipes, avoid blocking on large output.
public struct CommandRunner: Sendable {
    private let isolatedHome: URL?

    /// 为测试或受控的沙箱操作提供独立的工具配置目录。
    /// 未指定时保持系统进程环境的既有行为。
    public init(isolatedHome: URL? = nil) {
        self.isolatedHome = isolatedHome?.standardizedFileURL
    }
    /// `opensslConfiguration` 只为本次子进程设置 `OPENSSL_CONF`。
    /// 不提供通用环境变量入口，避免调用方覆盖 HOME、PATH 或动态链接器相关变量。
    public func run(
        executable: String,
        arguments: [String],
        directory: URL? = nil,
        timeout: TimeInterval = 20,
        opensslConfiguration: URL? = nil,
        standardInput: Data? = nil,
        gitIndexFile: URL? = nil,
        onOutput: CommandOutputHandler? = nil
    ) async throws -> CommandResult {
        if let gitIndexFile, !gitIndexFile.isFileURL || gitIndexFile.path.contains("\0") {
            throw VersionControlError.invalidRepository("临时 Git 索引必须是有效的本地文件路径。")
        }
        guard let executablePath = ToolLocator.find(executable) else { throw VersionControlError.toolUnavailable(executable) }
        let control = ProcessControl()
        let relay: CommandOutputRelay?
        let outputTask: Task<Void, Never>?
        if let onOutput {
            var continuation: AsyncStream<[CommandOutputLine]>.Continuation?
            let stream = AsyncStream<[CommandOutputLine]> { continuation = $0 }
            let createdRelay = CommandOutputRelay(continuation: continuation!)
            relay = createdRelay
            outputTask = Task {
                for await lines in stream where !lines.isEmpty {
                    await onOutput(lines)
                }
            }
        } else {
            relay = nil
            outputTask = nil
        }

        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await Task.detached(priority: .userInitiated) {
                    defer { relay?.finish() }
                    return try control.execute(
                    executable: executablePath,
                    arguments: arguments,
                    directory: directory,
                    timeout: timeout,
                    opensslConfiguration: opensslConfiguration,
                    standardInput: standardInput,
                    gitIndexFile: gitIndexFile,
                    isolatedHome: isolatedHome,
                    outputSink: relay?.yield
                    )
                }.value
            } onCancel: { control.cancel() }
            if let outputTask { await outputTask.value }
            return result
        } catch {
            relay?.finish()
            if let outputTask { await outputTask.value }
            throw error
        }
    }
}

/// 将同步的子进程读取循环与异步 UI 回调解耦。执行线程只把小批输出放入
/// `AsyncStream`，不会被 UI 的状态更新或动画阻塞。
private final class CommandOutputRelay: @unchecked Sendable {
    private let continuation: AsyncStream<[CommandOutputLine]>.Continuation

    init(continuation: AsyncStream<[CommandOutputLine]>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ lines: [CommandOutputLine]) {
        guard !lines.isEmpty else { return }
        continuation.yield(lines)
    }

    func finish() {
        continuation.finish()
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private let outputLimit: UInt64 = 16 * 1024 * 1024

    func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func execute(
        executable: String,
        arguments: [String],
        directory: URL?,
        timeout: TimeInterval,
        opensslConfiguration: URL?,
        standardInput: Data?,
        gitIndexFile: URL?,
        isolatedHome: URL?,
        outputSink: (@Sendable ([CommandOutputLine]) -> Void)?
    ) throws -> CommandResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let outURL = folder.appendingPathComponent("stdout"), errURL = folder.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VersionControlError.executionFailed("无法建立临时读取缓冲区。")
        }
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        // 没有用户可见的回调时，不创建额外文件句柄或解析行；普通 status/diff 命令保持原开销。
        let outputReader = outputSink == nil ? nil : try StreamingOutputReader(url: outURL, stream: .stdout)
        let errorReader = outputSink == nil ? nil : try StreamingOutputReader(url: errURL, stream: .stderr)
        defer { outputReader?.close(); errorReader?.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments; task.currentDirectoryURL = directory
        // 凭据等敏感输入只通过内存管道交给子进程；不进入参数、环境变量或临时文件。
        // 数据在启动前写入并关闭写端，既保证子进程能收到 EOF，也避开启动后写入的 SIGPIPE 竞争。
        let inputPipe = try standardInput.map(StandardInputPipe.init)
        task.standardInput = inputPipe?.readHandle ?? FileHandle.nullDevice
        task.standardOutput = out; task.standardError = err
        let inherited = ProcessInfo.processInfo.environment
        let allowedKeys = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "SSH_AUTH_SOCK", "SSH_AGENT_PID", "LANG", "http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
        var env = inherited.filter { allowedKeys.contains($0.key) }
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "en_US.UTF-8"
        if let isolatedHome {
            let home = isolatedHome.standardizedFileURL.path
            // 隔离测试不应复用用户的 SSH Agent 或代理网络路径。
            ["SSH_AUTH_SOCK", "SSH_AGENT_PID", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
             "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].forEach { env.removeValue(forKey: $0) }
            env["HOME"] = home
            env["XDG_CONFIG_HOME"] = isolatedHome.appendingPathComponent(".config", isDirectory: true).path
            env["GIT_CONFIG_NOSYSTEM"] = "1"
            env["GIT_CONFIG_GLOBAL"] = isolatedHome.appendingPathComponent(".gitconfig").path
            env["GIT_ASKPASS"] = "/usr/bin/false"
            env["SSH_ASKPASS"] = "/usr/bin/false"
        }
        if let opensslConfiguration {
            env["OPENSSL_CONF"] = opensslConfiguration.standardizedFileURL.path
        }
        // 仅为调用方明确创建的临时索引设置，不继承用户环境中的任意 GIT_* 覆盖。
        if let gitIndexFile { env["GIT_INDEX_FILE"] = gitIndexFile.standardizedFileURL.path }
        task.environment = env
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = task
        do { try task.run() } catch { process = nil; lock.unlock(); throw error }
        // 子进程已继承读端；关闭父进程副本，避免它影响 EOF 语义。
        try? inputPipe?.readHandle.close()
        lock.unlock()
        // 启动后的任何退出路径（包括末尾读取失败）都不能留下已结束进程的引用。
        defer {
            lock.lock()
            process = nil
            lock.unlock()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(timeout, 0.05)
        var failure: (any Error)?
        var pendingOutput: [CommandOutputLine] = []
        var lastOutputDelivery = ProcessInfo.processInfo.systemUptime

        func outputExceedsLimit() -> Bool {
            fileSize(outURL) + fileSize(errURL) > outputLimit
        }

        /// 返回当前快照下两个读取器是否都已读到末尾。运行中每轮最多读 256 KiB；
        /// 进程退出后会循环调用到末尾，避免遗漏最后一批输出。
        func readOutput(forceDelivery: Bool = false, respectCancellation: Bool = true) throws -> Bool {
            guard let outputReader, let errorReader else { return true }
            if respectCancellation, isCancelled { throw CancellationError() }
            if outputExceedsLimit() { throw VersionControlError.outputTooLarge }
            let output = try outputReader.readAvailable(maximumBytes: 128 * 1024)
            let error = try errorReader.readAvailable(maximumBytes: 128 * 1024)
            pendingOutput.append(contentsOf: output.lines)
            pendingOutput.append(contentsOf: error.lines)
            if outputExceedsLimit() { throw VersionControlError.outputTooLarge }
            let now = ProcessInfo.processInfo.systemUptime
            guard !pendingOutput.isEmpty,
                  forceDelivery || now - lastOutputDelivery >= 0.1 else {
                return !output.mayHaveMore && !error.mayHaveMore
            }
            outputSink?(pendingOutput)
            pendingOutput.removeAll(keepingCapacity: true)
            lastOutputDelivery = now
            return !output.mayHaveMore && !error.mayHaveMore
        }

        while task.isRunning {
            do {
                _ = try readOutput()
            } catch {
                // 即使读取临时输出失败，也要先终止并等待已启动的子进程，不能遗留后台传输。
                failure = error
            }
            if failure == nil {
                if isCancelled { failure = CancellationError() }
                else if ProcessInfo.processInfo.systemUptime >= deadline { failure = VersionControlError.timedOut(URL(fileURLWithPath: executable).lastPathComponent) }
                else if outputExceedsLimit() { failure = VersionControlError.outputTooLarge }
            }
            if failure != nil {
                if task.isRunning { task.terminate() }
                let grace = ProcessInfo.processInfo.systemUptime + 0.25
                while task.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        task.waitUntilExit()
        // 即便因取消而结束，也先读取已经写入的末尾，随后再把取消结果交给上层。
        do {
            var outputDrained = false
            while !outputDrained {
                outputDrained = try readOutput(forceDelivery: true, respectCancellation: false)
            }
            if let outputReader, let errorReader {
                pendingOutput.append(contentsOf: outputReader.finish())
                pendingOutput.append(contentsOf: errorReader.finish())
                if !pendingOutput.isEmpty { outputSink?(pendingOutput) }
            }
        } catch {
            // 例如取消后的临时文件读取异常不能覆盖已确定的取消/超时原因。
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
        if isCancelled { throw CancellationError() }
        guard fileSize(outURL) + fileSize(errURL) <= outputLimit else { throw VersionControlError.outputTooLarge }
        return CommandResult(data: try Data(contentsOf: outURL), errorData: try Data(contentsOf: errURL), exitCode: task.terminationStatus)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }

}

/// 从持续写入的临时文件增量读取，不重新加载历史内容。
private struct IncrementalOutputRead {
    let lines: [CommandOutputLine]
    /// 本次读取刚好用尽预算，下一轮仍可能有尚未读取的字节。
    let mayHaveMore: Bool
}

private final class StreamingOutputReader {
    private let handle: FileHandle
    private let stream: CommandOutputLine.Stream
    private var parser = CommandOutputLineParser()

    init(url: URL, stream: CommandOutputLine.Stream) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.stream = stream
    }

    func readAvailable(maximumBytes: Int) throws -> IncrementalOutputRead {
        var remaining = max(1, maximumBytes)
        var lines: [CommandOutputLine] = []
        while remaining > 0 {
            let requested = min(64 * 1024, remaining)
            guard let data = try handle.read(upToCount: requested), !data.isEmpty else {
                return IncrementalOutputRead(lines: lines, mayHaveMore: false)
            }
            lines.append(contentsOf: parser.append(data, stream: stream))
            remaining -= data.count
            if data.count < requested {
                return IncrementalOutputRead(lines: lines, mayHaveMore: false)
            }
        }
        return IncrementalOutputRead(lines: lines, mayHaveMore: true)
    }

    func finish() -> [CommandOutputLine] {
        parser.finish(stream: stream)
    }

    func close() {
        try? handle.close()
    }
}

/// 保留没有行尾的字节，以免 UTF-8 字符恰好被两次文件读取截断。
private struct CommandOutputLineParser {
    private static let maximumBufferedLine = 256 * 1024
    private var bytes = Data()
    private var skipsLeadingLineFeed = false

    mutating func append(_ data: Data, stream: CommandOutputLine.Stream) -> [CommandOutputLine] {
        var incoming = data
        if skipsLeadingLineFeed {
            if incoming.first == 10 { incoming.removeFirst() }
            skipsLeadingLineFeed = false
        }
        bytes.append(incoming)
        var lines: [CommandOutputLine] = []
        while let delimiter = nextDelimiter() {
            let textBytes = Data(bytes[..<delimiter])
            let delimiterByte = bytes[delimiter]
            bytes.removeSubrange(...delimiter)
            if delimiterByte == 13 {
                if bytes.first == 10 { bytes.removeFirst() }
                // 只有回车确实位于此次读取的末尾，下一次数据才需要吞掉可选的 LF。
                else if bytes.isEmpty { skipsLeadingLineFeed = true }
            }
            if !textBytes.isEmpty {
                lines.append(CommandOutputLine(stream: stream, text: String(decoding: textBytes, as: UTF8.self)))
            }
        }
        while bytes.count > Self.maximumBufferedLine {
            let boundary = safeBoundary(near: Self.maximumBufferedLine)
            let segment = Data(bytes.prefix(boundary))
            bytes.removeFirst(boundary)
            if !segment.isEmpty {
                lines.append(CommandOutputLine(stream: stream, text: String(decoding: segment, as: UTF8.self)))
            }
        }
        return lines
    }

    mutating func finish(stream: CommandOutputLine.Stream) -> [CommandOutputLine] {
        defer { bytes.removeAll(keepingCapacity: false); skipsLeadingLineFeed = false }
        guard !bytes.isEmpty else { return [] }
        return [CommandOutputLine(stream: stream, text: String(decoding: bytes, as: UTF8.self))]
    }

    private func nextDelimiter() -> Data.Index? {
        let lineFeed = bytes.firstIndex(of: 10)
        let carriageReturn = bytes.firstIndex(of: 13)
        switch (lineFeed, carriageReturn) {
        case let (.some(lhs), .some(rhs)): return min(lhs, rhs)
        case let (.some(index), .none), let (.none, .some(index)): return index
        case (.none, .none): return nil
        }
    }

    /// 选择 UTF-8 起始字节前的位置，避免把常见多字节字符的尾字节交给下一段。
    private func safeBoundary(near requested: Int) -> Int {
        var boundary = min(requested, bytes.count)
        while boundary > 0, boundary < bytes.count,
              (bytes[bytes.index(bytes.startIndex, offsetBy: boundary)] & 0b1100_0000) == 0b1000_0000 {
            boundary -= 1
        }
        return boundary == 0 ? min(requested, bytes.count) : boundary
    }
}

/// 仅供一次子进程启动使用的标准输入管道。
///
/// 写端在创建时已写完并关闭，因此不会把敏感内容保存到文件，也不会在子进程提前退出时
/// 发生启动后的写入竞争。限制为 4 KiB，并额外以系统报告的 `PIPE_BUF` 作为上限。
private struct StandardInputPipe {
    private static let maximumInputSize = 4 * 1024
    let readHandle: FileHandle

    init(_ data: Data) throws {
        guard data.count <= Self.maximumInputSize else {
            throw VersionControlError.executionFailed("标准输入超过 4 KiB 安全上限。")
        }

        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw VersionControlError.executionFailed("无法建立受控标准输入通道。")
        }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        var shouldCloseRead = true
        var shouldCloseWrite = true
        defer {
            if shouldCloseRead { Darwin.close(readDescriptor) }
        }
        defer {
            if shouldCloseWrite { Darwin.close(writeDescriptor) }
        }

        let pipeBufferSize = fpathconf(writeDescriptor, _PC_PIPE_BUF)
        guard pipeBufferSize > 0, data.count <= Int(pipeBufferSize) else {
            throw VersionControlError.executionFailed("标准输入超过当前系统管道的安全写入上限。")
        }

        let written = data.withUnsafeBytes { buffer in
            Darwin.write(writeDescriptor, buffer.baseAddress, buffer.count)
        }
        guard written == data.count else {
            throw VersionControlError.executionFailed("无法写入受控标准输入通道。")
        }
        guard Darwin.close(writeDescriptor) == 0 else {
            throw VersionControlError.executionFailed("无法关闭受控标准输入通道。")
        }
        shouldCloseWrite = false

        self.readHandle = FileHandle(fileDescriptor: readDescriptor, closeOnDealloc: true)
        shouldCloseRead = false
    }
}
