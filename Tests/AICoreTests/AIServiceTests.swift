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
