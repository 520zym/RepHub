import XCTest
import AICore
@testable import AIApplication

final class AIServiceTests: XCTestCase {
    func testSnapshotIncludesScopeAndContentButDoesNotDiscloseInternalIdentity() {
        let first = AIContext(sourceLabel: "Git", basis: "HEAD → 工作区", files: [.init(path:"a.swift",patch:"+foo")], identity:"/private/repo")
        let changed = AIContext(sourceLabel: "Git", basis: "HEAD → 工作区", files: [.init(path:"a.swift",patch:"+bar")], identity:"/private/repo")
        XCTAssertNotEqual(first.snapshotID, changed.snapshotID)
        let request = AIExecutionRequest(connection: .init(), scene: AIScene.defaults[0], context: first)
        XCTAssertFalse(request.userPrompt.contains("/private/repo"))
        XCTAssertTrue(request.userPrompt.contains("a.swift"))
        XCTAssertTrue(request.systemPrompt.contains("不可信数据"))
    }

    func testRejectsTooLargeContextBeforeCallingProvider() async throws {
        let service = AIService(providers:[EchoProvider()],secrets:TestSecrets())
        let context = AIContext(sourceLabel:"Git",basis:"HEAD",files:[.init(path:"big",patch:String(repeating:"a",count:262145))])
        do { _ = try await service.execute(.init(connection:.init(),scene:AIScene.defaults[0],context:context)) { _ in }; XCTFail("必须拒绝") }
        catch { XCTAssertTrue(error.localizedDescription.contains("256 KB")) }
    }

    func testFailureRedactsCurrentKey() async throws {
        let service = AIService(providers:[EchoProvider()],secrets:TestSecrets())
        let context = AIContext(sourceLabel:"Git",basis:"HEAD",files:[.init(path:"a",patch:"+text")])
        do { _ = try await service.execute(.init(connection:.init(),scene:AIScene.defaults[0],context:context)) { _ in }; XCTFail("必须报错") }
        catch { XCTAssertFalse(error.localizedDescription.contains("synthetic-secret")); XCTAssertTrue(error.localizedDescription.contains("***")) }
    }

    func testNewAPIKindsReadKeyFromSecretStore() async throws {
        let provider = KeyCapturingProvider(kind: .anthropicMessages)
        let service = AIService(providers: [provider], secrets: TestSecrets())
        let connection = AIConnection(name: "Claude", kind: .anthropicMessages, baseURL: "https://api.example/v1", model: "claude", timeoutSeconds: 10)
        let context = AIContext(sourceLabel: "Git", basis: "HEAD", files: [.init(path: "a", patch: "+text")])
        let result = try await service.execute(.init(connection: connection, scene: AIScene.defaults[0], context: context)) { _ in }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(provider.key, "synthetic-secret")
    }

    @MainActor
    func testSceneModelOverrideIsPassedToProviderAndReportedUsageIsRecordedOnce() async throws {
        let provider = RequestCapturingProvider()
        let suite = "RepHub.AIUsageStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let usageStore = AIUsageStore(defaults: defaults)
        let service = AIService(providers: [provider], secrets: TestSecrets(), usageStore: usageStore)
        let connection = AIConnection(name: "预设连接", baseURL: "https://api.example/v1", model: "connection-model", timeoutSeconds: 10)
        let scene = AIScene(name: "审查", kind: .codeReview, prompt: "审查", connectionID: connection.id, modelOverride: "scene-model")
        let context = AIContext(sourceLabel: "Git", basis: "HEAD", files: [.init(path: "a", patch: "+text")])

        _ = try await service.execute(.init(connection: connection, scene: scene, context: context)) { _ in }

        XCTAssertEqual(provider.model, "scene-model")
        let records = usageStore.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].model, "reported-model")
        XCTAssertEqual(records[0].usage?.inputTokens, 8)
        XCTAssertEqual(records[0].usage?.totalTokens, 12)
        XCTAssertEqual(records[0].outcome.rawValue, AIUsageOutcome.succeeded.rawValue)
    }

    func testDiscoverModelsUsesDraftKeyAndRedactsItOnFailure() async throws {
        let catalogProvider = CatalogProvider()
        let service = AIService(providers: [EchoProvider()], secrets: TestSecrets(), modelCatalogProvider: catalogProvider)
        let connection = AIConnection(name: "草稿", baseURL: "https://api.example/v1", model: "old")
        let catalog = try await service.discoverModels(for: connection, apiKey: "draft-key")
        XCTAssertEqual(catalog.models.map(\.id), ["one"])
        XCTAssertEqual(catalogProvider.key, "draft-key")

        let failing = AIService(providers: [EchoProvider()], secrets: TestSecrets(), modelCatalogProvider: FailingCatalogProvider())
        do {
            _ = try await failing.discoverModels(for: connection, apiKey: " draft-key ")
            XCTFail("应当失败")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("draft-key"))
            XCTAssertTrue(error.localizedDescription.contains("***"))
        }
    }

    @MainActor
    func testModelOnlyUsageDoesNotBecomeZeroTokenUsage() async throws {
        let suite = "RepHub.AIUsageUnknownTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let usageStore = AIUsageStore(defaults: defaults)
        let service = AIService(providers: [ModelOnlyUsageProvider()], secrets: TestSecrets(), usageStore: usageStore)
        let connection = AIConnection(name: "模型", baseURL: "https://api.example/v1", model: "configured", timeoutSeconds: 10)
        let context = AIContext(sourceLabel: "Git", basis: "HEAD", files: [.init(path: "a", patch: "+text")])

        _ = try await service.execute(.init(connection: connection, scene: AIScene.defaults[0], context: context)) { _ in }

        let records = usageStore.records
        XCTAssertNil(records.single?.usage)
        XCTAssertEqual(records.single?.model, "actual-model")
    }

    @MainActor
    func testFailureAndCancellationWithReportedUsageAreRecordedOnce() async throws {
        let suite = "RepHub.AIUsageOutcomeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let usageStore = AIUsageStore(defaults: defaults)
        let connection = AIConnection(name: "模型", baseURL: "https://api.example/v1", model: "configured", timeoutSeconds: 10)
        let context = AIContext(sourceLabel: "Git", basis: "HEAD", files: [.init(path: "a", patch: "+text")])
        let request = AIExecutionRequest(connection: connection, scene: AIScene.defaults[0], context: context)

        let failing = AIService(providers: [UsageOutcomeProvider(outcome: .failed)], secrets: TestSecrets(), usageStore: usageStore)
        do {
            _ = try await failing.execute(request) { _ in }
            XCTFail("应当失败")
        } catch { XCTAssertFalse(error is CancellationError) }

        let cancelling = AIService(providers: [UsageOutcomeProvider(outcome: .cancelled)], secrets: TestSecrets(), usageStore: usageStore)
        do {
            _ = try await cancelling.execute(request) { _ in }
            XCTFail("应当取消")
        } catch { XCTAssertTrue(error is CancellationError) }

        XCTAssertEqual(usageStore.records.count, 2)
        XCTAssertTrue(usageStore.records.contains { $0.outcome.rawValue == AIUsageOutcome.failed.rawValue && $0.usage?.totalTokens == 3 })
        XCTAssertTrue(usageStore.records.contains { $0.outcome.rawValue == AIUsageOutcome.cancelled.rawValue && $0.usage?.totalTokens == 3 })
    }
}
private struct TestSecrets: AISecretStore {
    func read(for connectionID: UUID) throws -> String? { "synthetic-secret" }
    func save(_ secret: String, for connectionID: UUID) throws {}
    func delete(for connectionID: UUID) throws {}
}
private struct EchoProvider: AIProvider {
    let kind: AIConnectionKind = .openAICompatible
    func check(_ connection: AIConnection) async throws -> String { "fixture" }
    func execute(_ request: AIExecutionRequest, apiKey: String?, progress: @escaping AIProgressHandler) async throws -> String {
        throw AIError.failed("fixture error \(apiKey ?? "")")
    }
}

private final class KeyCapturingProvider: AIProvider, @unchecked Sendable {
    let kind: AIConnectionKind
    private let lock = NSLock()
    private var capturedKey: String?
    init(kind: AIConnectionKind) { self.kind = kind }
    var key: String? { lock.withLock { capturedKey } }
    func check(_ connection: AIConnection) async throws -> String { "fixture" }
    func execute(_ request: AIExecutionRequest, apiKey: String?, progress: @escaping AIProgressHandler) async throws -> String {
        lock.withLock { capturedKey = apiKey }; return "ok"
    }
}

private final class RequestCapturingProvider: AIProvider, @unchecked Sendable {
    let kind: AIConnectionKind = .openAICompatible
    private let lock = NSLock()
    private var capturedModel: String?
    var model: String? { lock.withLock { capturedModel } }
    func check(_ connection: AIConnection) async throws -> String { "fixture" }
    func execute(_ request: AIExecutionRequest, apiKey: String?, progress: @escaping AIProgressHandler) async throws -> String {
        lock.withLock { capturedModel = request.connection.model }
        await progress(.usage(.init(inputTokens: 11, outputTokens: 7, model: request.connection.model)))
        await progress(.usage(.init(inputTokens: 8, outputTokens: 4, model: "reported-model")))
        return "ok"
    }
}

private final class CatalogProvider: AIModelCatalogProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedKey: String?
    var key: String? { lock.withLock { capturedKey } }
    func models(for connection: AIConnection, apiKey: String?) async throws -> AIModelCatalog {
        lock.withLock { capturedKey = apiKey }
        return .init(models: [.init(id: "one")], source: .remote)
    }
}

private struct FailingCatalogProvider: AIModelCatalogProvider {
    func models(for connection: AIConnection, apiKey: String?) async throws -> AIModelCatalog {
        throw AIError.failed("失败 \(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
    }
}

private struct ModelOnlyUsageProvider: AIProvider {
    let kind: AIConnectionKind = .openAICompatible
    func check(_ connection: AIConnection) async throws -> String { "fixture" }
    func execute(_ request: AIExecutionRequest, apiKey: String?, progress: @escaping AIProgressHandler) async throws -> String {
        await progress(.usage(.init(model: "actual-model")))
        return "ok"
    }
}

private struct UsageOutcomeProvider: AIProvider {
    let kind: AIConnectionKind = .openAICompatible
    let outcome: AIUsageOutcome
    func check(_ connection: AIConnection) async throws -> String { "fixture" }
    func execute(_ request: AIExecutionRequest, apiKey: String?, progress: @escaping AIProgressHandler) async throws -> String {
        await progress(.usage(.init(inputTokens: 1, outputTokens: 2, model: request.connection.model)))
        switch outcome {
        case .failed: throw AIError.failed("fixture failure")
        case .cancelled: throw CancellationError()
        case .succeeded: return "ok"
        }
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
