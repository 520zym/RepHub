import Foundation
import Testing
import ToolExecution

@Suite("命令进程环境")
struct CommandEnvironmentTests {
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

    private func environmentValue(_ name: String, in output: String) -> String? {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }
}
