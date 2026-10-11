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

    @Test("显式提高上限后可完整传递大标准输入并发送 EOF")
    func passesLargeInputWhenExplicitlyEnabled() async throws {
        let input = Data((0..<(256 * 1024)).map { UInt8($0 & 0xff) })
        let result = try await CommandRunner().run(
            executable: "/bin/cat",
            arguments: [],
            timeout: 2,
            standardInput: input,
            maximumStandardInputBytes: 2 * 1024 * 1024
        )

        #expect(result.exitCode == 0)
        #expect(result.data == input)
    }

    @Test("标准输入上限不得超过受控的 2 MiB")
    func rejectsMaximumInputLimitAboveAbsoluteCap() async {
        do {
            _ = try await CommandRunner().run(
                executable: "/bin/cat",
                arguments: [],
                standardInput: Data(),
                maximumStandardInputBytes: 2 * 1024 * 1024 + 1
            )
            Issue.record("应拒绝超过 2 MiB 的输入上限")
        } catch let error as VersionControlError {
            guard case .executionFailed(let detail) = error else {
                Issue.record("应为受控输入错误，实际为：\(error)")
                return
            }
            #expect(detail.contains("2 MiB"))
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
            standardInput: Data(repeating: 0x61, count: 256 * 1024),
            maximumStandardInputBytes: 2 * 1024 * 1024
        )
        #expect(result.exitCode == 0)
    }

    @Test("不读取标准输入的子进程仍会按超时终止")
    func doesNotHangWhenChildNeverReadsInput() async {
        do {
            _ = try await CommandRunner().run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: 0.1,
                standardInput: Data(repeating: 0x61, count: 256 * 1024),
                maximumStandardInputBytes: 2 * 1024 * 1024
            )
            Issue.record("应在超时后终止不读取输入的子进程")
        } catch let error as VersionControlError {
            guard case .timedOut = error else {
                Issue.record("应为超时，实际为：\(error)")
                return
            }
        } catch {
            Issue.record("应为 VersionControlError，实际为：\(error)")
        }
    }

    @Test("不读取标准输入的子进程可被取消")
    func cancelsWhenChildNeverReadsInput() async throws {
        let task = Task {
            try await CommandRunner().run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: 5,
                standardInput: Data(repeating: 0x61, count: 256 * 1024),
                maximumStandardInputBytes: 2 * 1024 * 1024
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("取消后不应返回命令结果")
        } catch is CancellationError {
            // 预期：取消会终止子进程并关闭尚未写完的内存管道。
        } catch {
            Issue.record("应为 CancellationError，实际为：\(error)")
        }
    }
}
