import Foundation
import Testing
import ToolExecution

@Suite("命令实时输出")
struct CommandOutputTests {
    @Test("进程退出前会交付输出")
    func deliversOutputBeforeProcessExits() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = folder.appendingPathComponent("continue")
        let script = "printf 'ready\\n'; while [ ! -f \"$1\" ]; do sleep 0.01; done; printf 'done\\n'"
        let recorder = OutputRecorder()

        let result = try await CommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", script, "rephub-test", gate.path],
            timeout: 2,
            onOutput: { lines in
                await recorder.append(lines)
                if lines.contains(where: { $0.text == "ready" }) {
                    FileManager.default.createFile(atPath: gate.path, contents: Data())
                }
            }
        )

        #expect(result.exitCode == 0)
        let lines = await recorder.lines
        #expect(lines.map(\.text) == ["ready", "done"])
    }

    @Test("保留 UTF8 分段、CRLF、stderr 与无尾换行")
    func parsesIncrementalStreamsWithoutMutatingText() async throws {
        let recorder = OutputRecorder()
        let script = "printf '\\344\\270'; sleep 0.04; printf '\\255\\346\\226\\207\\r\\n'; printf ' warning  \\r\\n' >&2; printf 'a\\rb'; sleep 0.04; printf '\\nc\\n'; printf 'tail'"
        let result = try await CommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            timeout: 2,
            onOutput: { await recorder.append($0) }
        )

        #expect(result.exitCode == 0)
        let lines = await recorder.lines
        #expect(lines.filter { $0.stream == .stdout }.map(\.text) == ["中文", "a", "b", "c", "tail"])
        #expect(lines.filter { $0.stream == .stderr }.map(\.text) == [" warning  "])
    }

    @Test("超长 UTF8 行在已有短行后不会丢字节")
    func preservesLongUTF8LineAfterEarlierOutput() async throws {
        let recorder = OutputRecorder()
        let repetitions = 100_000
        let program = "BEGIN { printf \"short\\n\"; system(\"sleep 0.08\"); for (i = 0; i < \(repetitions); i++) printf \"中文\"; printf \"\\n\" }"
        let result = try await CommandRunner().run(
            executable: "/usr/bin/awk",
            arguments: [program],
            timeout: 3,
            onOutput: { await recorder.append($0) }
        )

        #expect(result.exitCode == 0)
        let lines = await recorder.lines
        let output = lines.filter { $0.stream == .stdout }.map(\.text)
        #expect(output.first == "short")
        #expect(output.dropFirst().joined() == String(repeating: "中文", count: repetitions))
        #expect(!output.dropFirst().joined().contains("\u{FFFD}"))
    }

    @Test("取消传输后会结束并交付已完成的输出")
    func cancellationEndsOutputStream() async throws {
        let recorder = OutputRecorder()
        let task = Task {
            try await CommandRunner().run(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'started\\n'; sleep 5"],
                timeout: 8,
                onOutput: { await recorder.append($0) }
            )
        }
        await recorder.waitFor(text: "started")
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("应取消运行中的命令")
        } catch is CancellationError { }

        let lines = await recorder.lines
        #expect(lines.contains(CommandOutputLine(stream: .stdout, text: "started")))
    }

    private func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepHub-CommandOutputTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private actor OutputRecorder {
    private(set) var lines: [CommandOutputLine] = []
    private var waiters: [(text: String, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ received: [CommandOutputLine]) {
        lines.append(contentsOf: received)
        let receivedText = Set(received.map(\.text))
        var remaining: [(text: String, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if receivedText.contains(waiter.text) { waiter.continuation.resume() }
            else { remaining.append(waiter) }
        }
        waiters = remaining
    }

    func waitFor(text: String) async {
        guard !lines.contains(where: { $0.text == text }) else { return }
        await withCheckedContinuation { continuation in
            waiters.append((text, continuation))
        }
    }
}
