import SwiftUI
import DesignSystem
import RepositoryApplication
import VersionControlCore

public struct PartialCommitView: View {
    @Bindable private var model: PartialCommitModel
    private let palette: AppPalette
    private let appearance: AppearanceStore
    private let dismiss: () -> Void
    private let completed: @MainActor (RepositoryCommitResult) -> Void
    private let onBusyChange: ((Bool) -> Void)?
    @State private var collapsedHunks: Set<String> = []

    public init(model: PartialCommitModel, palette: AppPalette, appearance: AppearanceStore,
                dismiss: @escaping () -> Void, completed: @escaping @MainActor (RepositoryCommitResult) -> Void = { _ in },
                onBusyChange: ((Bool) -> Void)? = nil) {
        self.model = model; self.palette = palette; self.appearance = appearance
        self.dismiss = dismiss; self.completed = completed; self.onBusyChange = onBusyChange
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("按块／按行提交").font(.headline)
                    Text("仅 Git；保留其他文件暂存内容，所选代码将作为本地提交，不会推送远端").font(.caption).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Button("关闭", action: dismiss).disabled(model.isBusy)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
            }.padding(18).background(palette.surface)
            content
            Divider().opacity(0.25)
            footer.padding(16)
        }
        .workbenchSheet(minWidth: 900, idealWidth: 1080, minHeight: 620, idealHeight: 740)
        .background(palette.background).foregroundStyle(palette.text)
        .task { model.load() }
        .onChange(of: model.isBusy, initial: true) { _, busy in onBusyChange?(busy) }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading: ProgressView("正在生成可选择的代码块…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed: ContentUnavailableView("无法准备部分提交", systemImage: "exclamationmark.triangle", description: Text(model.errorMessage ?? "请刷新后重试。"))
        case .finished: result
        default:
            HSplitView {
                ScrollView { VStack(alignment: .leading, spacing: 0) { selectionList }.padding(16) }
                    .frame(minWidth: 360, idealWidth: 460)
                ScrollView([.horizontal, .vertical]) { preview.padding(16) }
                    .defaultScrollAnchor(.topLeading).frame(minWidth: 320, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var selectionList: some View {
        if let preparation = model.preparation {
            Text(preparation.notice).font(.caption).foregroundStyle(palette.secondaryText).padding(.bottom, 10)
            ForEach(preparation.files) { file in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(file.path).font(.system(.caption, design: .monospaced)); Spacer()
                    }
                    switch file.mode {
                    case .fileOnly(let reason): Text("\(reason) 请使用普通提交入口。 ").font(.caption2).foregroundStyle(palette.secondaryText)
                    case .lineSelection:
                        ForEach(file.hunks) { hunk in
                            DisclosureGroup(isExpanded: Binding(
                                get: { !collapsedHunks.contains(hunk.id) },
                                set: { if $0 { collapsedHunks.remove(hunk.id) } else { collapsedHunks.insert(hunk.id) } }
                            )) {
                                ScrollView(.horizontal) {
                                    LazyVStack(alignment: .leading, spacing: 3) {
                                        ForEach(hunk.lines) { line in
                                            HStack(spacing: 6) {
                                                if line.selectable {
                                                    Toggle("选择修改行", isOn: Binding(get: { model.isSelected(line, file: file) }, set: { _ in model.toggle(line, file: file) }))
                                                        .toggleStyle(.checkbox).labelsHidden().frame(width: 18)
                                                } else { Color.clear.frame(width: 18) }
                                                Text("\(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ") \(line.text)")
                                                    .font(.system(size: 11, design: .monospaced)).fixedSize()
                                                    .foregroundStyle(line.kind == .addition ? palette.added : line.kind == .deletion ? palette.removed : palette.text)
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }.defaultScrollAnchor(.topLeading)
                            } label: {
                                Toggle(isOn: Binding(
                                    get: { hunk.lines.filter(\.selectable).allSatisfy { model.isSelected($0, file: file) } },
                                    set: { _ in model.toggleHunk(hunk, file: file) }
                                )) { Text(hunk.header).font(.system(size: 11, design: .monospaced)).lineLimit(1) }
                                .toggleStyle(.checkbox).help("选择或取消整个代码块")
                            }
                        }
                    }
                }.padding(10).background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if model.phase == .previewing { ProgressView("正在生成最终补丁预览…").frame(maxWidth: .infinity, minHeight: 220) }
        else if let preview = model.preview { Text(preview.patch.text.isEmpty ? "没有选择可提交的变更。" : preview.patch.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        else { ContentUnavailableView("尚未生成预览", systemImage: "doc.text.magnifyingglass", description: Text("选择代码块后点击“预览最终补丁”。")) }
        if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: model.result?.outcome == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(model.result?.outcome == .succeeded ? palette.added : palette.removed)
            Text(model.result?.summary ?? "部分提交已结束。").font(.headline)
            if let id = model.result?.revisionID { Text(id).font(.system(.caption, design: .monospaced)).foregroundStyle(palette.secondaryText) }
            if let detail = model.result?.details, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(palette.secondaryText).textSelection(.enabled) }
            Spacer()
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            TextField("提交说明", text: $model.message).textFieldStyle(.roundedBorder).disabled(model.phase == .finished)
            Button("预览最终补丁") { model.buildPreview() }.disabled(model.phase != .ready || model.request() == nil)
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
            Button("提交所选代码") { model.commit(completed: completed) }.disabled(model.phase != .ready || model.preview == nil || model.request() == nil || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
        }
    }
}
