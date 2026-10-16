import Testing
@testable import RepHubUI

struct RevisionMessageTests {
    @Test
    func groupsHeadingsParagraphsAndListsWithoutDiscardingText() {
        let blocks = RevisionMessageParser.blocks(in: "修复范围：\n新增 **校验**，保留 `task_id`。\n- 第一项\n* 第二项\n\n1. 准备\n2) 完成")

        #expect(blocks.map(\.kind) == [.heading, .paragraph, .unorderedList, .orderedList])
        #expect(blocks[0].content == "修复范围：")
        #expect(blocks[1].content == "新增 **校验**，保留 `task_id`。")
        #expect(blocks[2].content == "- 第一项\n* 第二项")
        #expect(blocks[3].content == "1. 准备\n2) 完成")
        #expect(blocks[3].listItems.map(\.marker) == ["1.", "2)"])
    }

    @Test
    func keepsColonPathsAndKeyValuesAsOrdinaryText() {
        let message = "/srv/app: keep\nconfig: enabled\nhttp://example.test/a:80\n业务说明："
        let blocks = RevisionMessageParser.blocks(in: message)

        #expect(blocks.count == 2)
        #expect(blocks[0].kind == .paragraph)
        #expect(blocks[0].content == "/srv/app: keep\nconfig: enabled\nhttp://example.test/a:80")
        #expect(blocks[1].kind == .heading)
        #expect(blocks[1].content == "业务说明：")
    }

    @Test
    func readsClosedAndOpenEndedCodeFences() {
        let blocks = RevisionMessageParser.blocks(in: "前言\n```java\nvar value = 1;\n```\n\n```sql\nselect 1")

        #expect(blocks.count == 3)
        #expect(blocks[1].kind == .code(language: "java", isOpenEnded: false))
        #expect(blocks[1].content == "var value = 1;")
        #expect(blocks[2].kind == .code(language: "sql", isOpenEnded: true))
        #expect(blocks[2].content == "select 1")
    }

    @Test
    func ordinaryInlineBackticksAndDashesStayInParagraphs() {
        let message = "使用 `git log --oneline` 检查。\n-- 不是清单\n-无空格也不是清单"
        let blocks = RevisionMessageParser.blocks(in: message)

        #expect(blocks == [RevisionMessageBlock(id: 0, kind: .paragraph, content: message)])
    }

    @Test
    func keepsNonSequentialOrderedMarkersAndIndentedContinuation() {
        let blocks = RevisionMessageParser.blocks(in: "3. 首项\n   续行保留缩进\n8) 后续项")

        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .orderedList)
        #expect(blocks[0].listItems.map(\.marker) == ["3.", "8)"])
        #expect(blocks[0].listItems[0].content == "首项\n   续行保留缩进")
        #expect(blocks[0].content == "3. 首项\n   续行保留缩进\n8) 后续项")
    }

    @Test
    func inlineCodeAndBoldKeepTheirOwnPresentationTokens() {
        let tokens = RevisionMessageInlineParser.tokens(in: "使用 `git status`，并 **确认提交**。未闭合 `标记")

        #expect(tokens == [.text("使用 "), .code("git status"), .text("，并 "), .bold("确认提交"), .text("。未闭合 `标记")])
    }
}
