import AICore
import Foundation
import XCTest

final class AIContractsTests: XCTestCase {
    func testOldConnectionAndSceneDecodeWithoutNewFields() throws {
        let connectionJSON = #"{"id":"41510000-0000-0000-0000-000000000001","name":"旧连接","kind":"openAICompatible","baseURL":"https://example.invalid/v1","model":"old-model","executablePath":"","timeoutSeconds":120}"#
        let sceneJSON = #"{"id":"41510000-0000-0000-0000-000000000002","name":"旧场景","kind":"codeReview","prompt":"审查"}"#
        let connection = try JSONDecoder().decode(AIConnection.self, from: Data(connectionJSON.utf8))
        let scene = try JSONDecoder().decode(AIScene.self, from: Data(sceneJSON.utf8))
        XCTAssertNil(connection.preset)
        XCTAssertNil(connection.modelCatalog)
        XCTAssertNil(scene.modelOverride)
    }

    func testUsageTotalExcludesAlreadyIncludedCacheAndReasoning() {
        let usage = AITokenUsage(inputTokens: 100, outputTokens: 50,
                                 cachedInputTokens: 80, cacheCreationInputTokens: 10, reasoningTokens: 30)
        XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertNil(AITokenUsage(inputTokens: 100).totalTokens)
        XCTAssertFalse(AITokenUsage().hasReportedTokens)
        XCTAssertTrue(AITokenUsage(inputTokens: 0).hasReportedTokens)
        XCTAssertNil(AITokenUsage(inputTokens: -1, outputTokens: -1).totalTokens)
        XCTAssertNil(AITokenUsage(inputTokens: Int.max, outputTokens: 1).totalTokens)
    }

    func testProviderPresetsRoundTripWithDiscoveredModels() throws {
        for preset in AIProviderPreset.allCases {
            let connection = AIConnection(name: preset.title, baseURL: preset.baseURL,
                                          model: preset.defaultModel, preset: preset,
                                          modelCatalog: .init(models: preset.fallbackModels, source: .officialPreset))
            let decoded = try JSONDecoder().decode(AIConnection.self, from: JSONEncoder().encode(connection))
            XCTAssertEqual(decoded, connection)
        }
    }
}
