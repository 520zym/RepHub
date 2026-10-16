import SwiftUI
import DesignSystem
import RepositoryApplication
import VersionControlCore

/// 仅针对文本内容冲突的内置编辑器；保存不会创建提交，用户仍可回到管理面板完成后续操作。
struct ConflictEditorView: View {
    @State private var model: ConflictEditorModel
    let palette: AppPalette
    let appearance: AppearanceStore
    let dismiss: () -> Void
    let completed: @MainActor @Sendable (WorkspaceConflictResolutionResult) -> Void
    let onBusyChange: (@MainActor (Bool) -> Void)?
    @Environment(\.colorScheme) private var systemColorScheme

    init(service: RepositoryService, binding: RepositoryBinding, path: String, workspace: Workspace? = nil,
         palette: AppPalette, appearance: AppearanceStore,
         dismiss: @escaping () -> Void,
         completed: @escaping @MainActor @Sendable (WorkspaceConflictResolutionResult) -> Void,
         onBusyChange: (@MainActor (Bool) -> Void)? = nil) {
        _model = State(initialValue: ConflictEditorModel(service: service, binding: binding, path: path, workspace: workspace))
        self.palette = palette
        self.appearance = appearance
        self.dismiss = dismiss
        self.completed = completed
        self.onBusyChange = onBusyChange
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .workbenchSheet(minWidth: 920, idealWidth: 1120, minHeight: 650, idealHeight: 760)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .interactiveDismissDisabled(model.phase == .saving)
        .task { model.load() }
        .onChange(of: model.isBusy, initial: true) { _, busy in onBusyChange?(busy) }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(palette.removed)
                .frame(width: 31, height: 31)
                .background(palette.removed.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("处理内容冲突").font(.system(size: 15, weight: .semibold))
                Text(model.conflict?.path ?? "正在读取冲突文件…")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                .disabled(model.phase == .saving).accessibilityLabel("关闭冲突编辑器")
        }
        .padding(.horizontal, 22).padding(.vertical, 18).background(palette.surface)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("正在读取基准、本地和传入版本…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed where model.conflict == nil:
            ContentUnavailableView("无法读取冲突", systemImage: "exclamationmark.triangle", description: Text(model.message ?? "请刷新工作区后重试。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            editor
        }
    }

    private var editor: some View {
        VStack(spacing: 12) {
            if let message = model.message, model.phase == .failed {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(palette.removed)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.removed.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            if !model.blocks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.blocks) { block in
                            Menu("冲突块 \(block.id + 1)") {
                                ForEach(RepositoryConflictChoice.allCases) { choice in
                                    Button(choice.title) { model.apply(choice, to: block) }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .font(.system(size: 11, weight: .medium))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("选择后会直接替换对应冲突块；也可以在最终结果中继续编辑。保存会标记该文件已解决，但不会自动提交。")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("核对三份版本并编辑最终结果，处理完所有冲突标记后即可保存。")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                readOnlyPane("基准", text: model.conflict?.base ?? "", tint: palette.secondaryText)
                readOnlyPane("本地", text: model.conflict?.local ?? "", tint: palette.accent)
                readOnlyPane("传入", text: model.conflict?.incoming ?? "", tint: palette.removed)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("最终结果", systemImage: "pencil.line").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("可编辑").font(.system(size: 10)).foregroundStyle(palette.secondaryText)
                }
                NumberedCodeEditor(
                    text: $model.finalText,
                    palette: codePalette,
                    isEditable: model.phase == .ready
                )
                .background(codePalette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .frame(minHeight: 180, idealHeight: 210, maxHeight: .infinity)
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func readOnlyPane(_ title: String, text: String, tint: Color) -> some View {
        ConflictReadOnlyPane(
            title: title,
            text: text,
            language: SyntaxHighlighting.language(for: model.conflict?.path),
            tint: tint,
            palette: codePalette
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.phase == .saving { ProgressView().controlSize(.small); Text("正在保存并复核冲突状态…").font(.system(size: 12)).foregroundStyle(palette.secondaryText) }
            else if let message = model.message, model.phase == .finished { Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(palette.accent) }
            Spacer()
            Button(model.phase == .finished ? "完成" : "取消", action: dismiss)
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet)).disabled(model.phase == .saving)
            if model.phase != .finished {
                Button("保存并标记已解决") { model.save(completed: completed) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(!model.canSave)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 15).background(palette.surface)
    }

    private var codePalette: CodePalette { appearance.codePalette(for: appearance.preferredColorScheme ?? systemColorScheme) }
}

/// 三栏对照复用工作区文件预览：语法着色和固定行号均由 AppKit 文本系统完成，
/// 因此选择复制时只会得到代码本身。
private struct ConflictReadOnlyPane: View {
    let title: String
    let text: String
    let language: SyntaxHighlighting.Language
    let tint: Color
    let palette: CodePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            LocalFilePreviewView(text: text, palette: palette, language: language)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
