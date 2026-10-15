import AppKit
import Testing
@testable import RepHubUI

struct NumberedCodeEditorSynchronizerTests {
    @Test
    func unchangedModelDuringMarkedTextDoesNotQueueReplacement() {
        var synchronizer = NumberedCodeEditorSynchronizer()
        synchronizer.receivedModelText("初始内容", whileMarked: false)

        // 输入法组合时发生的普通视图刷新仍携带同一个模型值，不能覆盖组合内容。
        synchronizer.receivedModelText("初始内容", whileMarked: true)

        #expect(synchronizer.committedMarkedText() == nil)
    }

    @Test
    func externalModelChangeDuringMarkedTextIsAppliedAfterComposition() {
        var synchronizer = NumberedCodeEditorSynchronizer()
        synchronizer.receivedModelText("本地输入前", whileMarked: false)
        synchronizer.receivedModelText("采用传入版本", whileMarked: true)

        #expect(synchronizer.committedMarkedText() == "采用传入版本")
        #expect(synchronizer.committedMarkedText() == nil)
    }

    @Test @MainActor
    func nativeEditorRecordsAndUndoesMultilineInsertion() {
        let textView = NumberedCodeEditor.makeTextView(delegate: nil)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        textView.frame = host.bounds
        host.addSubview(textView)
        window.makeFirstResponder(textView)
        textView.undoManager?.removeAllActions()

        textView.insertText("第一行\n第二行", replacementRange: NSRange(location: 0, length: 0))

        #expect(textView.string == "第一行\n第二行")
        #expect(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        #expect(textView.string.isEmpty)
    }
}
