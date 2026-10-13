import SwiftUI
import DesignSystem
import RepositoryApplication
import VersionControlCore

struct RepositoryShelfView: View {
    @Bindable var model: RepositoryShelfModel
    let palette: AppPalette
    let appearance: AppearanceStore
    let dismiss: () -> Void
    let completed: () -> Void
    var onBusyChange: ((Bool) -> Void)? = nil
    @State private var deleteTarget: RepositoryShelfRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.18)
            HSplitView {
                createPane.frame(minWidth: 350, idealWidth: 410)
                recordsPane.frame(minWidth: 360, idealWidth: 480)
            }
            Divider().opacity(0.18)
            footer
        }
        .frame(minWidth: 790, minHeight: 510)
        .background(palette.surface)
        .task { await model.loadThenPrepare() }
        .onChange(of: model.isBusy, initial: true) { _, busy in onBusyChange?(busy) }
        .alert("删除搁置？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { item in
            Button("删除", role: .destructive) { model.delete(item); deleteTarget = nil }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { item in Text("“\(item.name)”删除后无法恢复。请先确认已成功恢复并核对内容。") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox").foregroundStyle(palette.accent).font(.system(size: 18, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text("搁置未完成改动").font(.system(size: 15, weight: .semibold))
                Text(model.binding.displayLabel).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer(); Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28) }.buttonStyle(.plain).disabled(model.isBusy)
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var createPane: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            Text("创建搁置").font(.system(size: 13, weight: .semibold))
            TextField("搁置名称", text: $model.name).textFieldStyle(.roundedBorder).disabled(model.isBusy)
            Toggle("包含未跟踪文件", isOn: $model.includeUntracked).disabled(model.isBusy).onChange(of: model.includeUntracked) { _, _ in model.prepare() }
            Picker("保存方式", selection: $model.mode) {
                ForEach(RepositoryShelfMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup).disabled(model.isBusy)
            Text(modeHint).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            Divider().opacity(0.2)
            HStack { Text("范围预览").font(.system(size: 12, weight: .semibold)); Spacer(); Button("刷新", action: model.prepare).buttonStyle(.plain).font(.system(size: 11)).disabled(model.isBusy) }
            if let preview = model.preview {
                if !preview.warnings.isEmpty { ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(palette.secondaryText) } }
                if preview.files.isEmpty { empty("没有可搁置的改动", "文件修改后可在这里预览。") }
                else { fileList(preview.files) }
            } else if model.isBusy { ProgressView("正在读取工作区…") }
            else { empty("尚未读取预览", "点击刷新检查当前工作区。") }
        }.padding(18) }
        .background(palette.sidebar.opacity(0.48))
    }

    private var recordsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已保存的搁置").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).padding(.top, 17)
            if model.records.isEmpty { empty("暂无搁置", "已保存的改动会保留在这里，恢复后也不会自动删除。").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { List(model.records) { record in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(record.name).font(.system(size: 12, weight: .medium)); Spacer(); Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(palette.secondaryText) }
                    Text(record.files.isEmpty ? (record.providerID == .git ? "Git stash；恢复时会重新读取文件范围。" : "本地 SVN 文本快照") : "\(record.files.count) 个文件").font(.system(size: 10)).foregroundStyle(palette.secondaryText)
                    HStack { Button("恢复") { model.restore(record) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(model.isBusy); Button("删除", role: .destructive) { deleteTarget = record }.buttonStyle(.borderless).font(.system(size: 11)).disabled(model.isBusy); Spacer() }
                }.padding(.vertical, 5)
            }.listStyle(.plain) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(palette.removed).lineLimit(2) }
            else if let message = model.message { Label(message, systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(palette.accent).lineLimit(2) }
            else { Text("恢复不会自动删除搁置；确认内容无误后再删除。选择“保存并清理”会清理整个预览范围。").font(.system(size: 11)).foregroundStyle(palette.secondaryText) }
            Spacer()
            Button("关闭", action: dismiss).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(model.isBusy)
            Button(model.mode == .saveOnly ? "保存快照" : "保存并清理", action: model.save).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(model.isBusy || model.preview?.files.isEmpty != false)
        }.padding(.horizontal, 18).padding(.vertical, 13)
    }

    private var modeHint: String { model.mode == .saveOnly ? "保存后仍保留当前工作区改动；Git 会验证并恢复原始状态，SVN 仅写入本地快照。" : "保存成功后清理预览范围。Git 使用 stash；SVN 对受管文本执行 revert，并删除已快照的未跟踪普通文件。" }
    private func fileList(_ files: [RepositoryShelfFile]) -> some View { LazyVStack(alignment: .leading, spacing: 3) { ForEach(files) { file in HStack(spacing: 7) { Image(systemName: file.kind == .untracked ? "doc.badge.plus" : "doc.text").foregroundStyle(file.kind == .untracked ? palette.accent : palette.secondaryText); Text(file.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle); Spacer(); Text(file.kind == .untracked ? "未跟踪" : "已修改").font(.system(size: 10)).foregroundStyle(palette.secondaryText) }.padding(.vertical, 3) } } }
    private func empty(_ title: String, _ description: String) -> some View { ContentUnavailableView(title, systemImage: "archivebox", description: Text(description)).foregroundStyle(palette.secondaryText) }
}
