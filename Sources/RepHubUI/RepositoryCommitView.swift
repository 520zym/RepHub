import SwiftUI
import DesignSystem
import RepositoryApplication
import VersionControlCore

/// 真实提交前的确认窗口。目标和文件始终按绑定分开，避免把 Git 与 SVN 的语义混在一起。
struct RepositoryCommitView: View {
    @Bindable var model: RepositoryCommitModel
    let palette: AppPalette
    let appearance: AppearanceStore
    let workspace: Workspace?
    let dismiss: () -> Void
    let committed: @MainActor @Sendable (WorkspaceCommitResult) -> Void
    let viewHistory: (String, String) -> Void
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var showsAI = false
    @State private var aiBindingID: String?
    @State private var aiSelectedPaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            switch model.phase {
            case .preparing:
                ProgressView("正在读取各版本控制来源的可提交文件…")
                    .frame(width: 760, height: 390)
            case .idle:
                ContentUnavailableView("无法准备提交", systemImage: "exclamationmark.bubble", description: Text(model.errorMessage ?? "请关闭后重新打开提交窗口。"))
                    .frame(width: 760, height: 390)
            case .ready:
                preparationContent
            case .committing:
                progressContent
            case .finished:
                resultContent
            }
        }
        .frame(width: 760)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .interactiveDismissDisabled(model.isBusy)
        .sheet(isPresented: $showsAI) {
            if let ai = model.ai {
                AIRunView(model: ai, palette: palette,
                          codePalette: appearance.codePalette(for: appearance.preferredColorScheme ?? systemColorScheme), dismiss: { showsAI = false }, apply: { text in
                    guard let id = aiBindingID, model.phase == .ready,
                          model.enabledBindingIDs.contains(id), model.selectedFiles(for: id) == aiSelectedPaths else {
                        ai.markStale()
                        return
                    }
                    model.setMessage(text, for: id)
                    showsAI = false
                })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 31, height: 31)
                .background(palette.selection.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.phase == .finished ? "提交结果" : "提交代码")
                    .font(.system(size: 15, weight: .semibold))
                Text(headerDetail).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if !model.isBusy {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .accessibilityLabel("关闭提交窗口")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(palette.surface)
    }

    private var headerDetail: String {
        switch model.phase {
        case .preparing: "正在检查工作副本和提交限制"
        case .ready: "Git 提交当前工作区所选文件；SVN 会直接提交到服务器"
        case .committing: "按 Git、SVN 的顺序提交；结果不明或取消时会停止后续目标"
        case .finished: "每个目标均保留了实际结果，不会自动重试"
        case .idle: "准备提交"
        }
    }

    private var preparationContent: some View {
        VStack(spacing: 0) {
            if model.preparations.count > 1 {
                WorkbenchSegmentedPicker(
                    title: "提交目标",
                    selection: Binding(get: { model.selectedBindingID }, set: { model.selectBinding($0) }),
                    options: model.preparations.map { .init(Optional($0.binding.id), title(for: $0)) },
                    palette: palette
                )
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 10)
            }
            if let preparation = model.selectedPreparation {
                HStack(alignment: .top, spacing: 14) {
                    fileSelection(preparation)
                        .frame(width: 320, alignment: .topLeading)
                    preview(preparation)
                }
                .padding(.horizontal, 22).padding(.bottom, 14)
            } else {
                ContentUnavailableView("没有可提交的版本控制来源", systemImage: "checkmark.circle")
                    .frame(height: 300)
            }
            Divider().opacity(0.28)
            footer
        }
        .frame(height: 540, alignment: .top)
    }

    private func title(for preparation: RepositoryCommitPreparation) -> String {
        let name = Set(model.preparations.map { $0.binding.root }).count > 1
            ? preparation.binding.displayLabel
            : (preparation.binding.providerID == .svn ? "SVN" : preparation.binding.providerName)
        return "\(name) \(preparation.files.count)"
    }

    private func fileSelection(_ preparation: RepositoryCommitPreparation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("可提交路径").font(.system(size: 13, weight: .semibold))
                    Text("\(model.selectedFiles(for: preparation.binding.id).count) / \(preparation.files.filter { $0.restriction == nil }.count) 已选择")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Toggle("启用", isOn: Binding(get: { model.enabledBindingIDs.contains(preparation.binding.id) }, set: { model.setBindingEnabled($0, for: preparation) }))
                    .toggleStyle(.checkbox).font(.system(size: 11)).fixedSize()
                    .disabled(preparation.blockingReason != nil)
                Menu {
                    Button("全选可提交文件") { model.selectAll(in: preparation) }
                    Button("清空选择") { model.clearSelection(in: preparation) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).help("全选或清空")
            }
            if !preparation.notice.isEmpty {
                Text(preparation.notice).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.sidebar.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let reason = preparation.blockingReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(palette.removed)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.removed.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            ScrollView {
                CommitFileTree(files: preparation.files, selected: model.selectedFiles(for: preparation.binding.id), palette: palette,
                               toggle: { model.toggleFile($0, in: preparation) }, preview: { model.selectFileForPreview($0, in: preparation) })
                    .padding(.vertical, 2)
            }
            .background(palette.sidebar.opacity(0.33), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .disabled(!model.enabledBindingIDs.contains(preparation.binding.id) || preparation.blockingReason != nil)
        }
    }

    private func preview(_ preparation: RepositoryCommitPreparation) -> some View {
        let codePalette = appearance.codePalette(for: appearance.preferredColorScheme ?? systemColorScheme)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedFile?.change.path ?? "选择一个文件预览差异")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(preparation.binding.providerID == .svn ? "SVN · 将直接写入服务器" : "Git · 当前工作区版本")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                if model.patch?.isTruncated == true { Text("内容已截断").font(.system(size: 10)).foregroundStyle(palette.secondaryText) }
            }
            Group {
                if let patch = model.patch, !patch.text.isEmpty {
                    HighlightedPatchPreview(text: patch.text, path: model.selectedFile?.change.path, palette: codePalette)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else if model.isLoadingPreview {
                    ProgressView("正在读取差异…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.previewError {
                    ContentUnavailableView("无法读取差异", systemImage: "exclamationmark.bubble", description: Text(error))
                } else if model.selectedFile != nil {
                    ContentUnavailableView("没有文本差异", systemImage: "doc.text", description: Text("该文件没有可显示的文本差异，或属于二进制内容。"))
                } else {
                    ContentUnavailableView("选择一个文件", systemImage: "doc.text.magnifyingglass", description: Text("提交前会读取该文件的实际差异。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let preparation = model.selectedPreparation {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(preparation.binding.providerID == .svn ? "SVN" : preparation.binding.providerName) 提交说明")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondaryText)
                        Spacer()
                        Button {
                            aiBindingID = preparation.binding.id
                            aiSelectedPaths = model.selectedFiles(for: preparation.binding.id)
                            model.prepareAI()
                            showsAI = true
                        } label: { Label("AI 生成", systemImage: "sparkles") }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(palette.accent)
                        .disabled(model.ai == nil || !model.enabledBindingIDs.contains(preparation.binding.id)
                                  || model.selectedFiles(for: preparation.binding.id).isEmpty || preparation.blockingReason != nil)
                    }
                    TextField("提交说明…", text: Binding(get: { model.message(for: preparation.binding.id) }, set: { model.setMessage($0, for: preparation.binding.id) }), axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(2...4).padding(.horizontal, 10).padding(.vertical, 5).frame(minHeight: 42, maxHeight: 70)
                        .background(palette.sidebar.opacity(0.48), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .disabled(!model.enabledBindingIDs.contains(preparation.binding.id) || preparation.blockingReason != nil)
                }
            }
            Spacer()
            Button("取消", action: dismiss).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
            Button(commitTitle) {
                guard let workspace else { return }
                model.commit(in: workspace, completed: committed)
            }
            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
            .disabled(!model.canCommit || workspace == nil)
            .help(model.canCommit ? "提交所选目标和文件" : "请至少选择一个文件，并填写每个已选目标的提交说明")
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
        .background(palette.surface)
    }

    private var commitTitle: String {
        let summaries = model.selectedTargets.map { target in
            let name = target.binding.providerID == .svn ? "SVN 服务器" : "Git 本地"
            return "\(name) \(model.selectedFiles(for: target.binding.id).count)"
        }
        return summaries.isEmpty ? "提交" : "提交 " + summaries.joined(separator: " · ")
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let id = model.activeBindingID, let preparation = model.preparations.first(where: { $0.binding.id == id }) {
                Text("正在提交 \(preparation.binding.providerID == .svn ? "SVN" : preparation.binding.providerName)")
                    .font(.system(size: 13, weight: .semibold))
            }
            RepositoryTransferProgressView(progress: model.transferProgress, palette: palette, source: nil, destination: nil,
                                           isCancelling: model.isCancelling, cancelTitle: "取消提交", cancel: model.cancel,
                                           showsFileRecords: false)
            Text("取消不会回滚已经提交成功的目标；完成后会刷新全部工作区状态。")
                .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
        }
        .padding(22).frame(height: 390, alignment: .topLeading)
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(palette.removed)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.removed.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.results, id: \.bindingID) { result in
                        let title = model.preparations.first(where: { $0.binding.id == result.bindingID }).map { $0.binding.displayLabel } ?? result.bindingID
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.outcome == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.outcome == .succeeded ? palette.accent : palette.removed)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(title) · \(result.summary)").font(.system(size: 13, weight: .medium))
                                if let revision = result.revisionID { Text(revision).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.accent) }
                                if !result.details.isEmpty { Text(result.details).font(.system(size: 11)).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer()
                            if result.outcome == .succeeded, let revision = result.revisionID {
                                Button("查看提交") { viewHistory(result.bindingID, revision) }
                                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                            }
                        }
                        .padding(11).background(palette.sidebar.opacity(0.52), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
            HStack {
                Spacer()
                Button("关闭", action: dismiss).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
            }
        }
        .padding(22).frame(height: 390, alignment: .topLeading)
    }
}

private struct CommitFileTree: View {
    let files: [RepositoryCommitFile]
    let selected: Set<String>
    let palette: AppPalette
    let toggle: (RepositoryCommitFile) -> Void
    let preview: (RepositoryCommitFile) -> Void

    var body: some View {
        ForEach(CommitTreeNode.make(files: files)) { node in
            CommitTreeRow(node: node, depth: 0, selected: selected, palette: palette, toggle: toggle, preview: preview)
        }
    }
}

private struct CommitTreeNode: Identifiable {
    let id: String
    let name: String
    var file: RepositoryCommitFile?
    var children: [CommitTreeNode]

    static func make(files: [RepositoryCommitFile]) -> [CommitTreeNode] {
        func build(_ prefix: String, _ entries: [RepositoryCommitFile]) -> [CommitTreeNode] {
            let groups = Dictionary(grouping: entries) { file -> String in
                let rest = String(file.change.path.dropFirst(prefix.count))
                return rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? file.change.path
            }
            return groups.keys.sorted().compactMap { component in
                let grouped = groups[component] ?? []
                let exact = grouped.first { $0.change.path == prefix + component }
                let next = prefix + component + "/"
                let descendants = grouped.filter { $0.change.path.hasPrefix(next) }
                return CommitTreeNode(id: prefix + component, name: component, file: exact, children: descendants.isEmpty ? [] : build(next, descendants))
            }
        }
        return build("", files)
    }
}

private struct CommitTreeRow: View {
    let node: CommitTreeNode
    let depth: Int
    let selected: Set<String>
    let palette: AppPalette
    let toggle: (RepositoryCommitFile) -> Void
    let preview: (RepositoryCommitFile) -> Void
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if node.children.isEmpty { Color.clear.frame(width: 13) }
                else { Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 13) }.buttonStyle(.plain) }
                if let file = node.file {
                    Toggle("", isOn: Binding(get: { selected.contains(file.id) }, set: { _ in toggle(file) }))
                        .toggleStyle(.checkbox).labelsHidden().disabled(file.restriction != nil)
                    Button { preview(file) } label: {
                        if file.isDirectory {
                            Image(systemName: "folder").foregroundStyle(palette.accent).font(.system(size: 12))
                        }
                        Text(file.change.kind.symbol).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(file.restriction == nil ? palette.accent : palette.secondaryText)
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                    .help(file.restriction ?? (file.isDirectory ? "\(file.change.path) · 仅提交目录自身，子项须单独选择" : file.change.path))
                    if file.restriction != nil { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(palette.secondaryText) }
                } else {
                    Image(systemName: "folder").foregroundStyle(palette.accent).font(.system(size: 12))
                    Text(node.name).lineLimit(1)
                }
            }
            .font(.system(size: 12)).padding(.leading, CGFloat(depth) * 14).padding(.horizontal, 7).padding(.vertical, 3)
            if expanded { ForEach(node.children) { child in CommitTreeRow(node: child, depth: depth + 1, selected: selected, palette: palette, toggle: toggle, preview: preview) } }
        }
    }
}
