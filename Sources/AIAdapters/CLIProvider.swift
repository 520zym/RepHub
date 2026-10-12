import AICore
import CoreFoundation
import Foundation
import ToolExecution

/// 以受限参数启动已登录的本机 AI CLI。
///
/// 本适配器不会读取或写入 CLI 的认证资料；登录状态完全由用户已安装的工具维护。
/// 每次分析均在新建的空目录中执行，提示词及差异只从标准输入传入。
public struct CLIProvider: AIProvider {
    public let kind: AIConnectionKind
    private let runner: CommandRunner

    public init(kind: AIConnectionKind, runner: CommandRunner = CommandRunner()) {
        self.kind = kind
        self.runner = runner
    }

    public func execute(
        _ request: AIExecutionRequest,
        apiKey: String?,
        progress: @escaping AIProgressHandler
    ) async throws -> String {
        _ = apiKey // CLI 的登录信息由工具自身管理，不能通过参数、环境变量或文件传入。
        try requireMatchingKind(request.connection)
        let launch = try resolveLaunch(for: request.connection)
        let input = Data((request.systemPrompt + "\n\n" + request.userPrompt).utf8)

        // 提示词和差异只能走受控内存管道；不能改为临时文件或命令参数。
        guard input.count <= 2 * 1024 * 1024 else {
            throw AIError.contextTooLarge
        }

        let workDirectory = try makeEmptyWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let collector = CLIOutputCollector(kind: kind, progress: progress)
        await progress(.status("正在通过 \(kind.title) 分析所选差异…"))

        let result = try await runner.run(
            executable: launch.executable,
            arguments: launch.argumentsPrefix + executionArguments(in: workDirectory, connection: request.connection),
            directory: workDirectory,
            timeout: request.connection.timeoutSeconds,
            standardInput: input,
            maximumStandardInputBytes: 2 * 1024 * 1024,
            onOutput: { lines in
                for line in lines where line.stream == .stdout {
                    await collector.accept(line.text)
                }
            }
        )
        guard result.exitCode == 0 else {
            throw AIError.failed(commandFailure(result, executable: launch.displayName))
        }
        return try await collector.finish()
    }

    /// 只读取版本与帮助，不发送提示词、差异或凭据。
    public func check(_ connection: AIConnection) async throws -> String {
        try requireMatchingKind(connection)
        let launch = try resolveLaunch(for: connection)
        let timeout = min(max(connection.timeoutSeconds, 1), 20)
        let workDirectory = try makeEmptyWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let version = try await runner.run(executable: launch.executable, arguments: launch.argumentsPrefix + ["--version"], directory: workDirectory, timeout: timeout)
        guard version.exitCode == 0 else { throw AIError.unavailable(checkFailure(version, executable: launch.displayName)) }
        let help = try await runner.run(executable: launch.executable, arguments: launch.argumentsPrefix + helpArguments, directory: workDirectory, timeout: timeout)
        guard help.exitCode == 0 else { throw AIError.unavailable(checkFailure(help, executable: launch.displayName)) }

        var helpText = help.output + "\n" + help.error
        if kind == .codexCLI {
            // `--ask-for-approval` 是当前 Codex 的顶层参数，exec 子命令帮助不会列出它。
            let globalHelp = try await runner.run(executable: launch.executable, arguments: launch.argumentsPrefix + ["--help"], directory: workDirectory, timeout: timeout)
            guard globalHelp.exitCode == 0 else { throw AIError.unavailable(checkFailure(globalHelp, executable: launch.displayName)) }
            helpText += "\n" + globalHelp.output + "\n" + globalHelp.error
        }
        let missing = requiredHelpFlags.filter { !helpText.contains($0) }
        guard missing.isEmpty else {
            throw AIError.unavailable("\(kind.title) 版本不支持安全执行所需参数：\(missing.joined(separator: "、"))。请升级该 CLI 后重试。")
        }
        let summary = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "已验证 \(kind.title) 可用。" : "已验证 \(kind.title)：\(summary)"
    }

    private var helpArguments: [String] {
        switch kind {
        case .codexCLI: ["exec", "--help"]
        case .claudeCLI: ["--help"]
        case .openAICompatible, .openAIResponses, .anthropicMessages: []
        }
    }

    private var requiredHelpFlags: [String] {
        switch kind {
        case .codexCLI:
            ["--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--sandbox", "--ask-for-approval", "--color", "--json"]
        case .claudeCLI:
            ["--safe-mode", "--no-session-persistence", "--tools", "--disallowedTools", "--permission-mode", "--no-chrome", "--output-format", "stream-json", "--input-format", "--verbose"]
        case .openAICompatible, .openAIResponses, .anthropicMessages: []
        }
    }

    private func executionArguments(in directory: URL, connection: AIConnection) -> [String] {
        let model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .codexCLI:
            var arguments = [
                "--ask-for-approval", "never", "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                "-C", directory.path, "--sandbox", "read-only", "--color", "never", "--json", "-"
            ]
            if !model.isEmpty { arguments.insert(contentsOf: ["--model", model], at: 0) }
            return arguments
        case .claudeCLI:
            // 当前 Claude Code 已移除 `--max-turns`；这里禁用全部工具且采用一次性
            // `--print` 调用，因而不会产生工具回合或继续会话。
            var arguments = [
                "--safe-mode", "-p", "--no-session-persistence", "--tools", "", "--disallowedTools", "mcp__*",
                "--permission-mode", "dontAsk", "--no-chrome", "--output-format", "stream-json", "--input-format", "text", "--verbose"
            ]
            if !model.isEmpty { arguments.insert(contentsOf: ["--model", model], at: 0) }
            return arguments
        case .openAICompatible, .openAIResponses, .anthropicMessages:
            return []
        }
    }

    private func requireMatchingKind(_ connection: AIConnection) throws {
        guard kind == .codexCLI || kind == .claudeCLI else {
            throw AIError.invalidConfiguration("CLI 适配器只支持 Codex CLI 或 Claude Code。")
        }
        guard connection.kind == kind else {
            throw AIError.invalidConfiguration("所选连接与 \(kind.title) 适配器不匹配。")
        }
    }

    private func resolveExecutable(for connection: AIConnection) throws -> String {
        if !connection.executablePath.isEmpty {
            let path = URL(fileURLWithPath: connection.executablePath).standardizedFileURL.path
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw AIError.unavailable("找不到可执行的 \(kind.title)：\(path)")
            }
            return path
        }
        let command = kind == .codexCLI ? "codex" : "claude"
        if let found = ToolLocator.find(command) { return found }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let direct = home.appendingPathComponent(".local/bin/\(command)").path
        if FileManager.default.isExecutableFile(atPath: direct) { return direct }

        let miseRoot = home.appendingPathComponent(".local/share/mise/installs/node", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(at: miseRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for node in candidates.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }) {
            let candidate = node.appendingPathComponent("bin/\(command)").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw AIError.unavailable("未找到 \(kind.title)。可在连接设置中填写可执行文件路径，或将它加入 PATH。")
    }

    /// Finder 启动的应用常只有系统 PATH。mise 安装的 Codex 是 `env node` 脚本时，
    /// 不能依赖该 PATH 再次定位 Node；改为显式调用同一 bin 目录的可执行 Node。
    private func resolveLaunch(for connection: AIConnection) throws -> CLILaunch {
        let executable = try resolveExecutable(for: connection)
        let executableURL = URL(fileURLWithPath: executable).standardizedFileURL
        guard kind == .codexCLI else {
            return CLILaunch(executable: executableURL.path, argumentsPrefix: [], displayName: executableURL.lastPathComponent)
        }
        let resolvedURL = executableURL.resolvingSymlinksInPath()
        guard hasEnvNodeShebang(at: resolvedURL) else {
            return CLILaunch(executable: executableURL.path, argumentsPrefix: [], displayName: executableURL.lastPathComponent)
        }
        guard let nodeURL = resolveNode(forScriptAt: resolvedURL, originalExecutable: executableURL) else {
            throw AIError.unavailable("Codex CLI 依赖 Node，但未找到可执行版本。请重新安装 Codex CLI，或在连接设置中指定可用路径。")
        }
        return CLILaunch(executable: nodeURL.path, argumentsPrefix: [resolvedURL.path], displayName: executableURL.lastPathComponent)
    }

    private func resolveNode(forScriptAt scriptURL: URL, originalExecutable: URL) -> URL? {
        let fileManager = FileManager.default
        // npm/mise 的常见布局是 `bin/codex -> ../lib/node_modules/.../codex.js`。
        // 先使用未展开链接所在 bin 的 node，避免展开后误在包目录中寻找。
        let sibling = originalExecutable.deletingLastPathComponent().appendingPathComponent("node")
        if fileManager.isExecutableFile(atPath: sibling.path) { return sibling }

        // 手动指定包内脚本时，仅向上检查有限层级的 `bin/node`；不会扫描用户目录。
        var directory = scriptURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent("bin/node")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        if let node = ToolLocator.find("node") { return URL(fileURLWithPath: node) }
        return nil
    }

    private func hasEnvNodeShebang(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix: Data?
        do { prefix = try handle.read(upToCount: 4 * 1024) }
        catch { return false }
        guard let data = prefix else { return false }
        let firstLine = String(decoding: data.prefix { $0 != 10 && $0 != 13 }, as: UTF8.self)
        let words = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return words.count >= 2 && words[0] == "#!/usr/bin/env" && words[1] == "node"
    }

    private func makeEmptyWorkingDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    private func commandFailure(_ result: CommandResult, executable: String) -> String {
        return "\(executable) 执行失败（退出码 \(result.exitCode)）。请检查 CLI 登录状态、网络和版本后重试。"
    }

    private func checkFailure(_ result: CommandResult, executable: String) -> String {
        return "\(executable) 自检失败（退出码 \(result.exitCode)）。请检查 CLI 是否已安装、可执行且已登录。"
    }
}

private struct CLILaunch: Sendable {
    let executable: String
    let argumentsPrefix: [String]
    let displayName: String
}

private actor CLIOutputCollector {
    private let kind: AIConnectionKind
    private let progress: AIProgressHandler
    private var terminalSeen = false
    private var terminalFailure: String?
    private var finalText = ""
    private var textByItemID: [String: String] = [:]
    private var orderedItemIDs: [String] = []

    init(kind: AIConnectionKind, progress: @escaping AIProgressHandler) {
        self.kind = kind
        self.progress = progress
    }

    func accept(_ line: String) async {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let event = object["type"] as? String else { return }
        switch kind {
        case .codexCLI: await acceptCodex(event: event, object: object)
        case .claudeCLI: await acceptClaude(event: event, object: object)
        case .openAICompatible, .openAIResponses, .anthropicMessages: break
        }
    }

    func finish() throws -> String {
        if let terminalFailure { throw AIError.failed(terminalFailure) }
        guard terminalSeen else { throw AIError.failed("CLI 未返回完整的最终结果。") }
        let result = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AIError.emptyOutput }
        return result
    }

    private func acceptCodex(event: String, object: [String: Any]) async {
        if event == "turn.failed" || event == "error" {
            terminalFailure = "Codex CLI 未完成本次分析。"
            return
        }
        if event == "turn.completed" {
            if let usage = tokenUsage(in: object, protocol: .codex) { await progress(.usage(usage)) }
            if let status = object["status"] as? String, !["completed", "success"].contains(status.lowercased()) {
                terminalFailure = "Codex CLI 分析未成功完成（\(status)）。"
            } else {
                terminalSeen = true
            }
            return
        }
        guard event == "item.updated" || event == "item.completed",
              let item = object["item"] as? [String: Any],
              (item["type"] as? String) == "agent_message",
              let text = item["text"] as? String else { return }
        let id = (item["id"] as? String) ?? "agent-message-\(orderedItemIDs.count)"
        await updateItem(id: id, text: text)
    }

    private func acceptClaude(event: String, object: [String: Any]) async {
        if event == "result" {
            if let usage = tokenUsage(in: object, protocol: .claude) { await progress(.usage(usage)) }
            if (object["is_error"] as? Bool) != false || (object["subtype"] as? String) != "success" {
                terminalFailure = "Claude Code 未成功完成本次分析。"
            } else if let result = object["result"] as? String {
                finalText = result
                terminalSeen = true
            } else {
                terminalFailure = "Claude Code 未返回最终文本。"
            }
            return
        }
        guard event == "assistant",
              let message = object["message"] as? [String: Any],
              let contents = message["content"] as? [[String: Any]] else { return }
        for (index, content) in contents.enumerated() where (content["type"] as? String) == "text" {
            if let text = content["text"] as? String {
                await updateItem(id: "claude-assistant-\(index)", text: text)
            }
        }
    }

    private func updateItem(id: String, text: String) async {
        let previous = textByItemID[id] ?? ""
        if textByItemID[id] == nil { orderedItemIDs.append(id) }
        textByItemID[id] = text
        if text.hasPrefix(previous) {
            let delta = String(text.dropFirst(previous.count))
            if !delta.isEmpty { await progress(.textDelta(delta)) }
        } else if previous.isEmpty, !text.isEmpty {
            await progress(.textDelta(text))
        }
        if let last = orderedItemIDs.last, let value = textByItemID[last] { finalText = value }
    }

    /// CLI 事件格式会随版本演进；只接受明确给出的计数，字段缺失时不估算。
    private enum CLIUsageProtocol { case codex, claude }

    private func tokenUsage(in object: [String: Any], protocol kind: CLIUsageProtocol) -> AITokenUsage? {
        let source = (object["usage"] as? [String: Any]) ?? (object["token_usage"] as? [String: Any])
        guard let source else { return nil }
        func integer(_ names: [String]) -> Int? {
            for name in names {
                if let value = strictUnsignedInteger(source[name]) { return value }
            }
            return nil
        }
        let directInput = integer(["input_tokens", "prompt_tokens"])
        let cacheRead: Int?
        let cacheCreation: Int?
        let cachedInput: Int?
        switch kind {
        case .codex:
            // Codex terminal 事件使用 cached_input_tokens；它已包含在 input_tokens 中。
            cacheRead = nil
            cacheCreation = nil
            cachedInput = integer(["cached_input_tokens"])
        case .claude:
            // Claude 的 input_tokens 不含两类缓存 token，和 Anthropic Messages API 的口径一致。
            cacheRead = integer(["cache_read_input_tokens"])
            cacheCreation = integer(["cache_creation_input_tokens"])
            cachedInput = cacheRead
        }
        let input: Int?
        switch kind {
        case .codex:
            input = directInput
        case .claude:
            // Claude 的 input_tokens 是基数；只有缓存字段时不能冒充完整输入。
            input = directInput.flatMap { safelyAdd([$0, cacheRead, cacheCreation]) }
        }
        let usage = AITokenUsage(inputTokens: input, outputTokens: integer(["output_tokens", "completion_tokens"]),
                                 totalTokens: integer(["total_tokens"]), cachedInputTokens: cachedInput,
                                 cacheCreationInputTokens: cacheCreation, reasoningTokens: integer(["reasoning_tokens"]),
                                 model: object["model"] as? String)
        return usage.hasReportedTokens ? usage : nil
    }

    /// JSON 里的 token 只能是非负整数。拒绝 Bool、浮点、负数及溢出值，绝不使用 intValue 截断。
    private func strictUnsignedInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let encoding = String(cString: number.objCType)
        guard ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(encoding) else { return nil }
        let text = number.stringValue
        guard let value = UInt64(text), value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }

    private func safelyAdd(_ values: [Int?]) -> Int? {
        let existing = values.compactMap { $0 }
        guard !existing.isEmpty else { return nil }
        return existing.reduce(into: Optional(0)) { partial, value in
            guard let existing = partial else { return }
            let result = existing.addingReportingOverflow(value)
            partial = result.overflow ? nil : result.partialValue
        }
    }
}
