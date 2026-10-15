import AppKit
import QuickLookUI
import SwiftUI
import RepositoryApplication

/// 将已由 `WorkspaceFileService` 验证的工作副本文档交给 macOS Quick Look。
///
/// RepHub 不自行解析 PDF 或 Office 二进制，也不会对历史版本伪造本地文件预览；
/// Quick Look 是否支持具体格式取决于当前 macOS 的预览组件。
@MainActor
struct DocumentPreviewView: NSViewRepresentable {
    let url: URL
    let kind: WorkspaceDocumentPreviewKind
    let identity: WorkspaceSystemPreviewIdentity

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.install(in: container)
        context.coordinator.update(url: url, identity: identity)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.update(url: url, identity: identity)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        // `QLPreviewView` 默认 `shouldCloseWithWindow == true`，并且 SwiftUI 销毁子视图时
        // 会自行停用它。此处调用 `close()` 会与 AppKit 的停用流程重叠，导致 QL 内部断言崩溃。
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private var displayed: PreviewItemIdentity?
        private weak var previewView: QLPreviewView?

        func install(in container: NSView) {
            guard previewView == nil else { return }
            guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
                let label = NSTextField(labelWithString: "当前 macOS 无法创建系统文档预览。")
                label.textColor = .secondaryLabelColor
                label.alignment = .center
                label.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(label)
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
                return
            }
            preview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                preview.topAnchor.constraint(equalTo: container.topAnchor),
                preview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            previewView = preview
        }

        func update(url: URL, identity: WorkspaceSystemPreviewIdentity) {
            guard let view = previewView else { return }
            let next = PreviewItemIdentity(url: url, content: identity)
            guard displayed != next else { return }
            let refreshesCurrentURL = displayed?.url == url
            displayed = next
            // NSURL 已遵循 QLPreviewItem；URL 来自应用层的普通文件边界校验。
            view.previewItem = url as NSURL
            if refreshesCurrentURL { view.refreshPreviewItem() }
        }

        func detach() {
            // 不触碰 previewItem 或调用 close：宿主视图仍在销毁它，Quick Look 会自行释放资源。
            previewView = nil
            displayed = nil
        }

        private struct PreviewItemIdentity: Equatable {
            let url: URL
            let content: WorkspaceSystemPreviewIdentity
        }
    }
}

extension WorkspaceDocumentPreviewKind {
    var localizedPreviewTitle: String {
        switch self {
        case .pdf: return "PDF 预览"
        case .word: return "Word 文档预览"
        case .presentation: return "演示文稿预览"
        case .spreadsheet: return "电子表格预览"
        }
    }
}
