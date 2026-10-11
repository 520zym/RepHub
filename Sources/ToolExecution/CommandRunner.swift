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
        opensslConfiguration: URL? = nil
    ) async throws -> CommandResult {
        guard let executablePath = ToolLocator.find(executable) else { throw VersionControlError.toolUnavailable(executable) }
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try control.execute(
                    executable: executablePath,
                    arguments: arguments,
                    directory: directory,
                    timeout: timeout,
                    opensslConfiguration: opensslConfiguration,
                    isolatedHome: isolatedHome
                )
            }.value
        } onCancel: { control.cancel() }
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
        isolatedHome: URL?
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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments; task.currentDirectoryURL = directory
        task.standardInput = FileHandle.nullDevice; task.standardOutput = out; task.standardError = err
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
        task.environment = env
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = task
        do { try task.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        let deadline = ProcessInfo.processInfo.systemUptime + max(timeout, 0.05)
        var failure: (any Error)?
        while task.isRunning {
            if isCancelled { failure = CancellationError() }
            else if ProcessInfo.processInfo.systemUptime >= deadline { failure = VersionControlError.timedOut(URL(fileURLWithPath: executable).lastPathComponent) }
            else if fileSize(outURL) + fileSize(errURL) > outputLimit { failure = VersionControlError.outputTooLarge }
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
        lock.lock(); process = nil; lock.unlock()
        if let failure { throw failure }
        if isCancelled { throw CancellationError() }
        guard fileSize(outURL) + fileSize(errURL) <= outputLimit else { throw VersionControlError.outputTooLarge }
        return CommandResult(data: try Data(contentsOf: outURL), errorData: try Data(contentsOf: errURL), exitCode: task.terminationStatus)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }
}
