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
            print -- '--skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules --sandbox --ask-for-approval --color --json --safe-mode --no-session-persistence --tools --disallowedTools --permission-prompts --no-chrome --output-format stream-json --input-format --max-turns --verbose'
          fi
          exit 0
        fi
        for forbidden in 'secret diff' '只返回可直接使用'; do
          if [[ "$args" == *"$forbidden"* ]]; then print -u2 'prompt leaked into arguments'; exit 91; fi
        done
        case "\(mode)" in
          codex-success)
            [[ "$args" == *"--model fixture-model"* && "$args" == *"--sandbox read-only"* && "$args" == *"--ask-for-approval never"* && "$args" == *"--ignore-rules"* && "$args" == *"--json"* ]] || { print -u2 'unsafe codex flags'; exit 92; }
            payload=$(cat)
            [[ "$payload" == *"secret diff"* ]] || { print -u2 'stdin missing diff'; exit 93; }
            print -- '{"type":"item.updated","item":{"id":"r","type":"reasoning","text":"不要展示"}}'
            print -- '{"type":"item.updated","item":{"id":"a","type":"agent_message","text":"提交"}}'
            print -- '{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"提交说明"}}'
            print -- '{"type":"turn.completed","status":"completed"}'
            ;;
          claude-success)
            [[ "$args" == *"--model fixture-model"* && "$args" == *"--safe-mode"* && "$args" == *"--tools  --disallowedTools mcp__*"* && "$args" == *"--permission-prompts none"* && "$args" == *"--output-format stream-json"* && "$args" == *"--max-turns 1"* ]] || { print -u2 'unsafe claude flags'; exit 94; }
            payload=$(cat)
            [[ "$payload" == *"secret diff"* ]] || { print -u2 'stdin missing diff'; exit 95; }
            print -- '{"type":"assistant","message":{"content":[{"type":"thinking","text":"不要展示"},{"type":"text","text":"Claude 草稿"}]}}'
            print -- '{"type":"result","subtype":"success","is_error":false,"result":"Claude 最终结果"}'
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
        let codex = bin.appendingPathComponent("codex")
        let node = bin.appendingPathComponent("node")
        try "#!/usr/bin/env node\nthis is deliberately not JavaScript\n".write(to: codex, atomically: true, encoding: .utf8)
        let nodeScript = """
        #!/bin/zsh
        set -eu
        [[ "$1" == *"/bin/codex" ]] || { print -u2 'missing script argument'; exit 98; }
        shift
        args="$*"
        if [[ "$args" == *"--version"* ]]; then print 'node-shim codex 1.0'; exit 0; fi
        if [[ "$args" == *"--help"* ]]; then print -- '--skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules --sandbox --ask-for-approval --color --json'; exit 0; fi
        cat >/dev/null
        print -- '{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"由相邻 Node 启动"}}'
        print -- '{"type":"turn.completed","status":"completed"}'
        """
        try nodeScript.write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        return codex
    }
}

private actor ProgressLog {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func text() -> String { values.joined() }
}
