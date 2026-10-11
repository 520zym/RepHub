import Foundation
import Testing
import ToolExecution
import VersionControlCore

@Suite("命令受控标准输入")
struct CommandInputTests {
    @Test("标准输入通过内存管道原样传递并发送 EOF")
    func passesInputAndEOF() async throws {
        let input = Data("password-only-in-memory\n".utf8)
        let result = try await CommandRunner().run(
            executable: "/bin/cat",
            arguments: [],
            timeout: 1,
            standardInput: input
        )

        #expect(result.exitCode == 0)
        #expect(result.data == input)
    }

    @Test("超过安全上限的标准输入会在启动前被拒绝")
    func rejectsOversizedInput() async {
        do {
            _ = try await CommandRunner().run(
                executable: "/bin/cat",
                arguments: [],
                standardInput: Data(repeating: 0x61, count: 4 * 1024 + 1)
            )
            Issue.record("应拒绝超过上限的输入")
        } catch let error as VersionControlError {
            guard case .executionFailed(let detail) = error else {
                Issue.record("应为受控输入错误，实际为：\(error)")
                return
            }
            #expect(detail.contains("标准输入"))
        } catch {
            Issue.record("应为 VersionControlError，实际为：\(error)")
        }
    }

    @Test("子进程提前退出时不会因标准输入写入挂起")
    func earlyExitDoesNotHang() async throws {
        let result = try await CommandRunner().run(
            executable: "/usr/bin/true",
            arguments: [],
            timeout: 1,
            standardInput: Data(repeating: 0x61, count: 256)
        )
        #expect(result.exitCode == 0)
    }
}
