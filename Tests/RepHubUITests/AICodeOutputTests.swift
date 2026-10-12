import Testing
@testable import RepHubUI

struct AICodeOutputTests {
    @Test
    func separatesProseAndNamedBacktickFence() {
        let blocks = AICodeOutputParser.blocks(in: "说明\n```java title=example\nclass App {}\n```\n结束")

        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .prose)
        #expect(blocks[0].content == "说明")
        #expect(blocks[1].kind == .code(language: "java", isOpenEnded: false))
        #expect(blocks[1].content == "class App {}")
        #expect(blocks[2].content == "结束")
    }

    @Test
    func matchingTildeFenceClosesOnlyWithSameMarker() {
        let blocks = AICodeOutputParser.blocks(in: "~~~sql\nSELECT 1;\n```\n~~~")

        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .code(language: "sql", isOpenEnded: false))
        #expect(blocks[0].content == "SELECT 1;\n```")
    }

    @Test
    func incompleteStreamingFenceIsSafelyExposedAsCode() {
        let blocks = AICodeOutputParser.blocks(in: "正在生成：\n```swift\nlet answer = 42")

        #expect(blocks.count == 2)
        #expect(blocks[1].kind == .code(language: "swift", isOpenEnded: true))
        #expect(blocks[1].content == "let answer = 42")
    }

    @Test
    func ordinaryBackticksRemainProse() {
        let output = "使用 `git status` 查看状态。\n~~ 不是围栏"
        let blocks = AICodeOutputParser.blocks(in: output)

        #expect(blocks == [AICodeOutputBlock(id: 0, kind: .prose, content: output)])
    }
}
