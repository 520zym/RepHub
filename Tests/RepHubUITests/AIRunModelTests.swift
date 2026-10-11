import AICore
import AIApplication
@testable import RepHubUI
import XCTest

@MainActor
final class AIRunModelTests: XCTestCase {
    func testEmptyConnectionShowsConfigurationExplanation() {
        let model = makeModel(provider: FixtureProvider())
        model.prepare(kind: .codeReview, sourceLabel: "工作区", paths: ["A.swift"]) { paths in
            makeContext(paths)
        }

        model.run()

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.errorMessage, "尚未配置 AI 连接。请先在设置中添加模型 API 或本机 CLI。")
    }

    func testRunSendsOnlySelectedFiles() async throws {
        let log = FixtureLog()
        let provider = FixtureProvider(log: log)
        let model = makeModel(provider: provider, withConnection: true)
        model.prepare(kind: .codeReview, sourceLabel: "工作区", paths: ["A.swift", "B.swift"]) { paths in
            makeContext(paths)
        }
        model.setSelectedPaths(["B.swift"])

        model.run()
        try await waitUntil { !model.isBusy }

        let lastPaths = await log.lastPaths()
        XCTAssertEqual(lastPaths, ["B.swift"])
        XCTAssertEqual(model.output, "审查完成")
        XCTAssertFalse(model.isStale)
    }

    func testCancellationDiscardsLateResponse() async throws {
        let gate = ResponseGate()
        let provider = FixtureProvider(waitForGate: gate)
        let model = makeModel(provider: provider, withConnection: true)
        model.prepare(kind: .codeReview, sourceLabel: "工作区", paths: ["A.swift"]) { paths in makeContext(paths) }
        model.run()
        await gate.waitUntilStarted()

        model.cancel()
        await gate.release()
        for _ in 0..<8 { await Task.yield() }

        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.output.isEmpty)
        XCTAssertEqual(model.progress, "已取消")
    }

    func testResultBecomesStaleWhenSnapshotChangesAndApplyDoesNotOverwrite() async throws {
        let version = SnapshotVersion()
        let model = makeModel(provider: FixtureProvider(), withConnection: true)
        model.prepare(kind: .commitMessage, sourceLabel: "提交", paths: ["A.swift"], selectedPaths: ["A.swift"]) { paths in
            let value = await version.value()
            return makeContext(paths, identity: value)
        }
        model.run()
        try await waitUntil { !model.isBusy }
        XCTAssertFalse(model.isStale)

        await version.advance()
        let applied = expectation(description: "旧结果不能填入")
        applied.isInverted = true
        model.apply { _ in applied.fulfill() }
        await fulfillment(of: [applied], timeout: 0.15)

        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.progress, "差异已变化，未填入旧结果。")
    }

    func testChangingScenePromptWithSameIDKeepsOldResultStale() async throws {
        let model = makeModel(provider: FixtureProvider(), withConnection: true)
        model.prepare(kind: .codeReview, sourceLabel: "工作区", paths: ["A.swift"]) { paths in makeContext(paths) }
        model.run()
        try await waitUntil { !model.isBusy }
        let original = try XCTUnwrap(model.selectedScene)
        var changed = original
        changed.prompt += "\n新增规则。"
        try model.settings.saveScene(changed)

        model.revalidate()
        for _ in 0..<20 where !model.isStale { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.progress, "场景、连接或文件范围已变化，请重新运行。")
    }

    private func makeModel(provider: FixtureProvider, withConnection: Bool = false) -> AIRunModel {
        let defaults = UserDefaults(suiteName: "AIRunModelTests.\(UUID().uuidString)")!
        let settings = AISettingsStore(secrets: EmptySecrets(), defaults: defaults)
        if withConnection {
            try! settings.saveConnection(AIConnection(name: "测试模型", kind: .openAICompatible,
                                                      baseURL: "http://localhost:11434", model: "fixture"))
        }
        return AIRunModel(settings: settings, service: AIService(providers: [provider], secrets: EmptySecrets()))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "等待 AI 运行状态超时")
    }
}

private struct EmptySecrets: AISecretStore {
    func read(for connectionID: UUID) throws -> String? { nil }
    func save(_ secret: String, for connectionID: UUID) throws {}
    func delete(for connectionID: UUID) throws {}
}

private struct FixtureProvider: AIProvider {
    let kind: AIConnectionKind = .openAICompatible
    let log: FixtureLog?
    let waitForGate: ResponseGate?

    init(log: FixtureLog? = nil, waitForGate: ResponseGate? = nil) {
        self.log = log; self.waitForGate = waitForGate
    }

    func execute(_ request: AIExecutionRequest, apiKey: String?, progress: @escaping AIProgressHandler) async throws -> String {
        await log?.record(request.context.files.map(\.path))
        await progress(.textDelta("流式片段"))
        if let waitForGate {
            await waitForGate.started()
            await waitForGate.wait()
        }
        try Task.checkCancellation()
        return "审查完成"
    }

    func check(_ connection: AIConnection) async throws -> String { "可用" }
}

private actor FixtureLog {
    private var paths: [String] = []
    func record(_ paths: [String]) { self.paths = paths }
    func lastPaths() -> [String] { paths }
}

private actor ResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func started() {
        didStart = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SnapshotVersion {
    private var current = "one"
    func value() -> String { current }
    func advance() { current = "two" }
}

private func makeContext(_ paths: Set<String>, identity: String = "one") -> AIContext {
    AIContext(sourceLabel: "测试", basis: "工作区", files: paths.sorted().map { AIInputFile(path: $0, patch: "diff -- \($0)") }, identity: identity)
}
