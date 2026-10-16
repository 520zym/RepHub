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

/// 命令把 stdout 写入受控文件后的结果。内容不会重新读回内存。
public struct CommandFileResult: Sendable {
    public let errorData: Data
    public let exitCode: Int32
    public let standardOutputBytes: UInt64
    public var error: String { String(decoding: errorData, as: UTF8.self) }

    public init(errorData: Data = Data(), exitCode: Int32, standardOutputBytes: UInt64) {
        self.errorData = errorData; self.exitCode = exitCode; self.standardOutputBytes = standardOutputBytes
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

@discardableResult public func requireSuccess(_ result: CommandFileResult, tool: String) throws -> CommandFileResult {
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
        maximumStandardInputBytes: Int = 4 * 1024,
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
                    maximumStandardInputBytes: maximumStandardInputBytes,
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

    /// 将可能很大的 stdout 直接写到新建的私有文件，避免常规 `run` 的内存读取和 16 MiB
    /// 输出上限。调用者必须给出不存在的本地路径和明确的磁盘预算；stderr 仍受常规上限保护。
    public func runWritingStandardOutput(
        executable: String,
        arguments: [String],
        to outputURL: URL,
        maximumStandardOutputBytes: UInt64,
        directory: URL? = nil,
        timeout: TimeInterval = 20,
        opensslConfiguration: URL? = nil,
        standardInput: Data? = nil,
        maximumStandardInputBytes: Int = 4 * 1024,
        gitIndexFile: URL? = nil
    ) async throws -> CommandFileResult {
        if let gitIndexFile, !gitIndexFile.isFileURL || gitIndexFile.path.contains("\0") {
            throw VersionControlError.invalidRepository("临时 Git 索引必须是有效的本地文件路径。")
        }
        guard outputURL.isFileURL, !outputURL.path.contains("\0"), maximumStandardOutputBytes > 0 else {
            throw VersionControlError.invalidRepository("命令流式输出目标或大小上限无效。")
        }
        let output = outputURL.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path),
              FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path),
              (try output.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              (try output.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw VersionControlError.invalidRepository("命令流式输出目标必须位于已存在的非链接目录且不能覆盖文件。")
        }
        guard let executablePath = ToolLocator.find(executable) else { throw VersionControlError.toolUnavailable(executable) }
        let descriptor = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw VersionControlError.invalidRepository("无法以排他方式建立命令流式输出文件。")
        }
        defer { _ = Darwin.close(descriptor) }
        let control = ProcessControl()
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await Task.detached(priority: .userInitiated) {
                    try control.executeFile(
                        executable: executablePath, arguments: arguments, directory: directory,
                        timeout: timeout, opensslConfiguration: opensslConfiguration,
                        standardInput: standardInput, maximumStandardInputBytes: maximumStandardInputBytes,
                        gitIndexFile: gitIndexFile, isolatedHome: isolatedHome, outputSink: nil,
                        standardOutputURL: output, standardOutputFileDescriptor: descriptor,
                        maximumStandardOutputBytes: maximumStandardOutputBytes
                    )
                }.value
            } onCancel: { control.cancel() }
            if result.exitCode != 0 { try? FileManager.default.removeItem(at: output) }
            return CommandFileResult(errorData: result.errorData, exitCode: result.exitCode,
                                     standardOutputBytes: result.standardOutputBytes)
        } catch {
            try? FileManager.default.removeItem(at: output)
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
        maximumStandardInputBytes: Int,
        gitIndexFile: URL?,
        isolatedHome: URL?,
        outputSink: (@Sendable ([CommandOutputLine]) -> Void)?,
        standardOutputURL: URL? = nil,
        standardOutputFileDescriptor: Int32? = nil,
        maximumStandardOutputBytes: UInt64? = nil
    ) throws -> CommandResult {
        let result = try executeFile(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            opensslConfiguration: opensslConfiguration, standardInput: standardInput,
            maximumStandardInputBytes: maximumStandardInputBytes, gitIndexFile: gitIndexFile,
            isolatedHome: isolatedHome, outputSink: outputSink, standardOutputURL: standardOutputURL,
            standardOutputFileDescriptor: standardOutputFileDescriptor,
            maximumStandardOutputBytes: maximumStandardOutputBytes
        )
        return CommandResult(data: result.data, errorData: result.errorData, exitCode: result.exitCode)
    }

    func executeFile(
        executable: String,
        arguments: [String],
        directory: URL?,
        timeout: TimeInterval,
        opensslConfiguration: URL?,
        standardInput: Data?,
        maximumStandardInputBytes: Int,
        gitIndexFile: URL?,
        isolatedHome: URL?,
        outputSink: (@Sendable ([CommandOutputLine]) -> Void)?,
        standardOutputURL: URL?,
        standardOutputFileDescriptor: Int32?,
        maximumStandardOutputBytes: UInt64?
    ) throws -> (data: Data, errorData: Data, exitCode: Int32, standardOutputBytes: UInt64) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let outURL = standardOutputURL ?? folder.appendingPathComponent("stdout")
        let errURL = folder.appendingPathComponent("stderr")
        guard (standardOutputURL != nil || FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])),
              FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VersionControlError.executionFailed("无法建立临时读取缓冲区。")
        }
        guard standardOutputURL == nil || standardOutputFileDescriptor != nil else {
            throw VersionControlError.invalidRepository("命令流式输出文件未安全建立。")
        }
        let out: FileHandle
        if let standardOutputFileDescriptor {
            out = FileHandle(fileDescriptor: standardOutputFileDescriptor, closeOnDealloc: false)
        } else {
            out = try FileHandle(forWritingTo: outURL)
        }
        let errorHandle = try FileHandle(forWritingTo: errURL)
        defer {
            if standardOutputFileDescriptor == nil { try? out.close() }
            try? errorHandle.close()
        }
        // 没有用户可见的回调时，不创建额外文件句柄或解析行；普通 status/diff 命令保持原开销。
        let outputReader = outputSink == nil || standardOutputURL != nil ? nil : try StreamingOutputReader(url: outURL, stream: .stdout)
        let errorReader = outputSink == nil ? nil : try StreamingOutputReader(url: errURL, stream: .stderr)
        defer { outputReader?.close(); errorReader?.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments; task.currentDirectoryURL = directory
        // 凭据、提示词和差异等敏感输入只通过内存管道交给子进程；不进入参数、环境变量或临时文件。
        // 小输入保持原有 4 KiB 限制。大输入必须由调用方显式提高上限，且只会在子进程启动后
        // 以非阻塞方式泵入，避免启动前填满管道而死锁。
        var inputPipe = try standardInput.map { try StandardInputPipe($0, maximumInputSize: maximumStandardInputBytes) }
        task.standardInput = inputPipe?.readHandle ?? FileHandle.nullDevice
        task.standardOutput = out; task.standardError = errorHandle
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
        inputPipe?.closeReadHandle()
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
            if let maximumStandardOutputBytes {
                return fileSize(outURL) > maximumStandardOutputBytes || fileSize(errURL) > outputLimit
            }
            return fileSize(outURL) + fileSize(errURL) > outputLimit
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
                try inputPipe?.pump()
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
        inputPipe?.closeWriteHandle()
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
        guard !outputExceedsLimit() else { throw VersionControlError.outputTooLarge }
        let data = standardOutputURL == nil ? try Data(contentsOf: outURL) : Data()
        return (data: data, errorData: try Data(contentsOf: errURL), exitCode: task.terminationStatus,
                standardOutputBytes: fileSize(outURL))
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
/// 输入只保存在内存中。写端使用非阻塞模式，由等待子进程的循环分批泵入；这样 AI 的较大
/// prompt/diff 不会在启动前写满管道，也不会因子进程提前退出向本进程发送 SIGPIPE。
private struct StandardInputPipe {
    private static let absoluteMaximumInputSize = 2 * 1024 * 1024
    let readHandle: FileHandle
    private var writeDescriptor: Int32
    private let data: Data
    private var nextOffset = 0

    init(_ data: Data, maximumInputSize: Int) throws {
        guard maximumInputSize >= 0, maximumInputSize <= Self.absoluteMaximumInputSize else {
            throw VersionControlError.executionFailed("标准输入上限必须介于 0 与 2 MiB 之间。")
        }
        guard data.count <= maximumInputSize else {
            throw VersionControlError.executionFailed("标准输入超过 \(maximumInputSize / 1024) KiB 安全上限。")
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

        let currentFlags = fcntl(writeDescriptor, F_GETFL)
        guard currentFlags >= 0,
              fcntl(writeDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0,
              fcntl(writeDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw VersionControlError.executionFailed("无法配置受控标准输入通道。")
        }
        self.readHandle = FileHandle(fileDescriptor: readDescriptor, closeOnDealloc: true)
        self.writeDescriptor = writeDescriptor
        self.data = data
        shouldCloseRead = false
        shouldCloseWrite = false
    }

    mutating func closeReadHandle() {
        try? readHandle.close()
    }

    /// 分批写入，直到暂时没有管道容量、全部写完或子进程已关闭读端。
    /// EPIPE 说明子进程不再需要输入，属于正常提前退出路径；关闭写端即可。
    mutating func pump(maximumBytes: Int = 128 * 1024) throws {
        guard writeDescriptor >= 0 else { return }
        var remainingBudget = max(1, maximumBytes)
        while nextOffset < data.count, remainingBudget > 0 {
            let requested = min(64 * 1024, data.count - nextOffset, remainingBudget)
            let written: Int
            do {
                written = try data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                    let result = Darwin.write(writeDescriptor, baseAddress.advanced(by: nextOffset), requested)
                    if result >= 0 { return Int(result) }
                    let error = errno
                    if error == EAGAIN || error == EWOULDBLOCK { return 0 }
                    if error == EPIPE { return -1 }
                    throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
                }
            } catch {
                closeWriteHandle()
                throw VersionControlError.executionFailed("无法写入受控标准输入通道。")
            }
            if written < 0 {
                closeWriteHandle()
                return
            }
            guard written > 0 else { return }
            nextOffset += written
            remainingBudget -= written
        }
        if nextOffset == data.count { closeWriteHandle() }
    }

    mutating func closeWriteHandle() {
        guard writeDescriptor >= 0 else { return }
        Darwin.close(writeDescriptor)
        writeDescriptor = -1
    }
}
