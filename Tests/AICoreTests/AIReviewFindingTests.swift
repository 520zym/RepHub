import AICore
import Testing

struct AIReviewFindingTests {
    @Test
    func onlyNewSideHunkLinesAreAccepted() {
        let context = AIContext(sourceLabel: "测试", basis: "工作区", files: [
            AIInputFile(path: "Sources/App.swift", patch: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            @@ -4,2 +10,3 @@
             let retained = true
            -let removed = true
            +let inserted = true
            +run()
            """)
        ])

        #expect(context.newLineNumbers(for: "Sources/App.swift") == [10, 11, 12])
        #expect(context.validates(AIReviewFinding(severity: .warning, path: "Sources/App.swift", newLine: 11, reason: "x", suggestion: "y")))
        #expect(!context.validates(AIReviewFinding(severity: .warning, path: "Sources/App.swift", newLine: 4, reason: "x", suggestion: "y")))
        #expect(!context.validates(AIReviewFinding(severity: .warning, path: "../secret", newLine: 11, reason: "x", suggestion: "y")))
    }
}
