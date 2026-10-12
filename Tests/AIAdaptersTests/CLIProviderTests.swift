import AICore
import AIAdapters
import Foundation
import XCTest

final class CLIProviderTests: XCTestCase {
    func testCodexUsesSafeArgumentsAndOnlyEmitsAgentText() async throws {
        let script = try makeCLI(mode: "codex-success")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let provider = CLIProvider(kind: .codexCLI)
        let log = ProgressLog()

        let response = try await provider.execute(request(kind: .codexCLI, executable: script.path), apiKey: nil) { event in
            if case let .textDelta(text) = event { await log.append(text) }
        }

        XCTAssertEqual(response, "提交说明")
        let delivered = await log.text()
        XCTAssertEqual(delivered, "提交说明")
    }

    func testClaudeReadsStreamJSONAndRequiresSafeArguments() async throws {
        let script = try makeCLI(mode: "claude-success")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let provider = CLIProvider(kind: .claudeCLI)
        let log = ProgressLog()

        let response = try await provider.execute(request(kind: .claudeCLI, executable: script.path), apiKey: nil) { event in
            if case let .textDelta(text) = event { await log.append(text) }
        }

        XCTAssertEqual(response, "Claude 最终结果")
        let delivered = await log.text()
        XCTAssertEqual(delivered, "Claude 草稿")
    }

    func testCLIUsageUsesProtocolSpecificCacheAccounting() async throws {
        let codex = try makeCLI(mode: "codex-success")
        defer { try? FileManager.default.removeItem(at: codex.deletingLastPathComponent()) }
        let codexUsage = UsageLog()
        _ = try await CLIProvider(kind: .codexCLI).execute(request(kind: .codexCLI, executable: codex.path), apiKey: nil) { event in
            if case .usage(let usage) = event { await codexUsage.append(usage) }
        }
        let codexValue = await codexUsage.last()
        let codexReported = try XCTUnwrap(codexValue)
        XCTAssertEqual(codexReported.inputTokens, 12)
        XCTAssertEqual(codexReported.cachedInputTokens, 5)
        XCTAssertEqual(codexReported.totalTokens, 15)

        let claude = try makeCLI(mode: "claude-success")
        defer { try? FileManager.default.removeItem(at: claude.deletingLastPathComponent()) }
        let claudeUsage = UsageLog()
        _ = try await CLIProvider(kind: .claudeCLI).execute(request(kind: .claudeCLI, executable: claude.path), apiKey: nil) { event in
            if case .usage(let usage) = event { await claudeUsage.append(usage) }
        }
        let claudeValue = await claudeUsage.last()
        let claudeReported = try XCTUnwrap(claudeValue)
        XCTAssertEqual(claudeReported.inputTokens, 10) // 5 + 3 + 2
        XCTAssertEqual(claudeReported.cachedInputTokens, 3)
        XCTAssertEqual(claudeReported.cacheCreationInputTokens, 2)
        XCTAssertEqual(claudeReported.totalTokens, 14)
    }

    func testClaudeCheckAcceptsCurrentSafetyOptions() async throws {
        let script = try makeCLI(mode: "claude-success")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let result = try await CLIProvider(kind: .claudeCLI).check(connection(kind: .claudeCLI, executable: script.path))
        XCTAssertTrue(result.contains("fake-cli"))
    }

    func testCodexEnvNodeScriptUsesSiblingNodeWithoutPATHLookup() async throws {
        let cli = try makeEnvNodeCodex()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent().deletingLastPathComponent()) }
        let provider = CLIProvider(kind: .codexCLI)
        let connection = self.connection(kind: .codexCLI, executable: cli.path)

        let check = try await provider.check(connection)
        XCTAssertTrue(check.contains("node-shim"))
        let response = try await provider.execute(request(connection: connection), apiKey: nil) { _ in }
        XCTAssertEqual(response, "由相邻 Node 启动")
    }

    func testLocalCodexCheckWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPHUB_VERIFY_LOCAL_CODEX"] == "1" else {
            throw XCTSkip("仅在明确请求时验证本机 Codex 版本与帮助，不发送代码。")
        }
        let result = try await CLIProvider(kind: .codexCLI).check(AIConnection(name: "本机 Codex", kind: .codexCLI, timeoutSeconds: 15))
        XCTAssertFalse(result.isEmpty)
    }

    func testLocalClaudeCheckWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPHUB_VERIFY_LOCAL_CLAUDE"] == "1" else {
            throw XCTSkip("仅在明确请求时验证本机 Claude 版本与帮助，不发送代码。")
        }
        let result = try await CLIProvider(kind: .claudeCLI).check(AIConnection(name: "本机 Claude", kind: .claudeCLI, timeoutSeconds: 15))
        XCTAssertFalse(result.isEmpty)
    }

    func testCheckRejectsCLIWithoutRequiredSafetyFlag() async throws {
        let script = try makeCLI(mode: "help-missing")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let provider = CLIProvider(kind: .codexCLI)
        do {
            _ = try await provider.check(connection(kind: .codexCLI, executable: script.path))
            XCTFail("缺少安全参数时不可继续")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("请升级"))
            XCTAssertTrue(error.localizedDescription.contains("--ignore-rules"))
        }
    }

    func testNonzeroExitIsNeverPartialSuccess() async throws {
        let script = try makeCLI(mode: "nonzero")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let provider = CLIProvider(kind: .codexCLI)
        do {
            _ = try await provider.execute(request(kind: .codexCLI, executable: script.path), apiKey: nil) { _ in }
            XCTFail("非零退出不能返回部分文本")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("退出码 19"))
        }
    }

    func testMissingTerminalEventIsFailure() async throws {
        let script = try makeCLI(mode: "missing-final")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let provider = CLIProvider(kind: .codexCLI)
        do {
            _ = try await provider.execute(request(kind: .codexCLI, executable: script.path), apiKey: nil) { _ in }
            XCTFail("没有最终事件时不能接受部分输出")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("完整的最终结果"))
        }
    }

    func testTimeoutAndCancellationStopFakeCLI() async throws {
        let script = try makeCLI(mode: "sleep")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let provider = CLIProvider(kind: .codexCLI)
        var timedOut = connection(kind: .codexCLI, executable: script.path)
        timedOut.timeoutSeconds = 0.1
        do {
            _ = try await provider.execute(request(connection: timedOut), apiKey: nil) { _ in }
            XCTFail("超时必须终止 CLI")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }

        let cancellationRequest = request(kind: .codexCLI, executable: script.path)
        let task = Task { try await provider.execute(cancellationRequest, apiKey: nil) { _ in } }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消必须终止 CLI")
        } catch is CancellationError { }
    }

    private func request(kind: AIConnectionKind, executable: String) -> AIExecutionRequest {
        request(connection: connection(kind: kind, executable: executable))
    }

    private func request(connection: AIConnection) -> AIExecutionRequest {
        let context = AIContext(sourceLabel: "Git", basis: "HEAD → 工作区", files: [
            .init(path: "Example.swift", patch: "+secret diff")
        ])
        return AIExecutionRequest(connection: connection, scene: AIScene.defaults[0], context: context)
    }

    private func connection(kind: AIConnectionKind, executable: String) -> AIConnection {
        AIConnection(name: "测试 CLI", kind: kind, model: "fixture-model", executablePath: executable, timeoutSeconds: 2)
    }

    private func makeCLI(mode: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-cli")
        let source = """
        #!/bin/zsh
        set -eu
        args="$*"
        if [[ "$args" == *"--version"* ]]; then print 'fake-cli 1.0'; exit 0; fi
        if [[ "$args" == *"--help"* ]]; then
          if [[ "\(mode)" == "help-missing" ]]; then
            print -- '--skip-git-repo-check --ephemeral --ignore-user-config --sandbox --ask-for-approval --color --json'
          else
            print -- '--skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules --sandbox --ask-for-approval --color --json --safe-mode --no-session-persistence --tools --disallowedTools --permission-mode --no-chrome --output-format stream-json --input-format --verbose'
          fi
          exit 0
        fi
        for forbidden in 'secret diff' '只返回可直接使用'; do
          if [[ "$args" == *"$forbidden"* ]]; then print -u2 'prompt leaked into arguments'; exit 91; fi
        done
        case "\(mode)" in
          codex-success)
            for required in '--model fixture-model' '--sandbox read-only' '--ask-for-approval never' '--ignore-rules' '--json'; do
              [[ "$args" == *"$required"* ]] || { print -u2 'unsafe codex flags'; exit 92; }
            done
            payload=$(cat)
            [[ "$payload" == *"secret diff"* ]] || { print -u2 'stdin missing diff'; exit 93; }
            print -- '{"type":"item.updated","item":{"id":"r","type":"reasoning","text":"不要展示"}}'
            print -- '{"type":"item.updated","item":{"id":"a","type":"agent_message","text":"提交"}}'
            print -- '{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"提交说明"}}'
            print -- '{"type":"turn.completed","status":"completed","usage":{"input_tokens":12,"output_tokens":3,"cached_input_tokens":5}}'
            ;;
          claude-success)
            [[ "$args" == *"--model fixture-model"* && "$args" == *"--safe-mode"* && "$args" == *"--tools  --disallowedTools mcp__*"* && "$args" == *"--permission-mode dontAsk"* && "$args" == *"--output-format stream-json"* ]] || { print -u2 'unsafe claude flags'; exit 94; }
            payload=$(cat)
            [[ "$payload" == *"secret diff"* ]] || { print -u2 'stdin missing diff'; exit 95; }
            print -- '{"type":"assistant","message":{"content":[{"type":"thinking","text":"不要展示"},{"type":"text","text":"Claude 草稿"}]}}'
            print -- '{"type":"result","subtype":"success","is_error":false,"result":"Claude 最终结果","usage":{"input_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2,"output_tokens":4}}'
            ;;
          nonzero)
            print -- '{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"不能当成功"}}'
            print -u2 'expected failure'; exit 19
            ;;
          missing-final)
            print -- '{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"不完整"}}'
            ;;
          sleep) cat >/dev/null; sleep 5 ;;
        esac
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func makeEnvNodeCodex() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-node-cli-tests-\(UUID().uuidString)", isDirectory: true)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let packageBin = directory.appendingPathComponent("lib/node_modules/@openai/codex/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: packageBin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        let scriptTarget = packageBin.appendingPathComponent("codex.js")
        let node = bin.appendingPathComponent("node")
        try "#!/usr/bin/env node\nthis is deliberately not JavaScript\n".write(to: scriptTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: codex.path, withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
        let nodeScript = """
        #!/bin/zsh
        set -eu
        [[ "$1" == *"/lib/node_modules/@openai/codex/bin/codex.js" ]] || { print -u2 'missing resolved script argument'; exit 98; }
        shift
        args="$*"
        if [[ "$args" == *"--version"* ]]; then print 'node-shim codex 1.0'; exit 0; fi
        if [[ "$args" == *"--help"* ]]; then print -- '--skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules --sandbox --ask-for-approval --color --json'; exit 0; fi
        cat >/dev/null
        print -- '{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"由相邻 Node 启动"}}'
        print -- '{"type":"turn.completed","status":"completed"}'
        """
        try nodeScript.write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptTarget.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        return codex
    }
}

private actor ProgressLog {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func text() -> String { values.joined() }
}

private actor UsageLog {
    private var values: [AITokenUsage] = []
    func append(_ usage: AITokenUsage) { values.append(usage) }
    func last() -> AITokenUsage? { values.last }
}
