import Foundation
import Testing
import ToolExecution

@Suite("命令进程环境")
struct CommandEnvironmentTests {
    @Test("Git 临时索引仅注入指定命令，不污染后续运行")
    func isolatesExplicitGitIndex() async throws {
        let runner = CommandRunner()
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-index-\(UUID().uuidString)")
        let scoped = try await runner.run(executable: "/usr/bin/env", arguments: [], gitIndexFile: index)
        #expect(environmentValue("GIT_INDEX_FILE", in: scoped.output) == index.standardizedFileURL.path)
        let normal = try await runner.run(executable: "/usr/bin/env", arguments: [])
        #expect(environmentValue("GIT_INDEX_FILE", in: normal.output) == nil)
    }

    @Test("OpenSSL 配置仅在明确指定的子进程中注入")
    func injectsOnlyExplicitOpenSSLConfiguration() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepHub-CommandEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = folder.appendingPathComponent("openssl.cnf")
        try Data("# test\n".utf8).write(to: configuration)

        let runner = CommandRunner()
        let defaultEnvironment = try await runner.run(executable: "/usr/bin/env", arguments: [])
        #expect(environmentValue("OPENSSL_CONF", in: defaultEnvironment.output) == nil)
        #expect(!defaultEnvironment.output.contains("DYLD_"))

        let configuredEnvironment = try await runner.run(
            executable: "/usr/bin/env",
            arguments: [],
            opensslConfiguration: configuration
        )
        #expect(environmentValue("OPENSSL_CONF", in: configuredEnvironment.output) == configuration.standardizedFileURL.path)
        #expect(!configuredEnvironment.output.contains("DYLD_"))
    }

    @Test("隔离运行器只为测试子进程替换工具配置目录")
    func isolatesHomeAndGitConfiguration() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepHub-UpdateFixture-Environment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let result = try await CommandRunner(isolatedHome: home).run(executable: "/usr/bin/env", arguments: [])
        #expect(environmentValue("HOME", in: result.output) == home.standardizedFileURL.path)
        #expect(environmentValue("XDG_CONFIG_HOME", in: result.output) == home.appendingPathComponent(".config").path)
        #expect(environmentValue("GIT_CONFIG_NOSYSTEM", in: result.output) == "1")
        #expect(environmentValue("GIT_CONFIG_GLOBAL", in: result.output) == home.appendingPathComponent(".gitconfig").path)
        #expect(environmentValue("GIT_TERMINAL_PROMPT", in: result.output) == "0")
        #expect(environmentValue("SSH_AUTH_SOCK", in: result.output) == nil)
        #expect(environmentValue("SSH_AGENT_PID", in: result.output) == nil)
        #expect(environmentValue("http_proxy", in: result.output) == nil)
        #expect(environmentValue("https_proxy", in: result.output) == nil)
        #expect(environmentValue("HTTP_PROXY", in: result.output) == nil)
        #expect(environmentValue("HTTPS_PROXY", in: result.output) == nil)
        #expect(environmentValue("all_proxy", in: result.output) == nil)
        #expect(environmentValue("no_proxy", in: result.output) == nil)
        #expect(environmentValue("ALL_PROXY", in: result.output) == nil)
        #expect(environmentValue("NO_PROXY", in: result.output) == nil)
    }

    private func environmentValue(_ name: String, in output: String) -> String? {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }
}
