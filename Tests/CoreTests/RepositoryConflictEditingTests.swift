import Testing
import VersionControlCore

@Suite("文本冲突块解析")
struct RepositoryConflictEditingTests {
    @Test("选择一边不会丢失冲突块外的上下文")
    func applyingChoicePreservesContext() {
        let text = "before\n<<<<<<< local\nlocal\n||||||| base\nbase\n=======\nincoming\n>>>>>>> remote\nafter\n"
        let blocks = RepositoryConflictTextResolver.blocks(in: text)
        #expect(blocks.count == 1)
        #expect(blocks[0].base == "base\n")
        #expect(RepositoryConflictTextResolver.applying(.local, to: 0, in: text) == "before\nlocal\nafter\n")
        #expect(RepositoryConflictTextResolver.applying(.incoming, to: 0, in: text) == "before\nincoming\nafter\n")
        #expect(RepositoryConflictTextResolver.applying(.both, to: 0, in: text) == "before\nlocal\nincoming\nafter\n")
    }

    @Test("不完整标记不会覆盖用户原文")
    func leavesIncompleteMarkersUntouched() {
        let text = "header\n<<<<<<< local\nkeep this\n"
        #expect(RepositoryConflictTextResolver.blocks(in: text).isEmpty)
        #expect(RepositoryConflictTextResolver.applying(.local, to: 0, in: text) == text)
    }
}
