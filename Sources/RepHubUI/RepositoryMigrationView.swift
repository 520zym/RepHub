import SwiftUI
import DesignSystem
import VersionControlCore

/// SVN → Git 迁移窗口。预览完成前不会调用远端发布。
struct RepositoryMigrationView: View {
    @Bindable var model: RepositoryMigrationModel
    let palette: AppPalette
    let dismiss: () -> Void
    let openResult: (URL) -> Void
    @State private var previewTab: PreviewTab = .overview

    private enum PreviewTab: Hashable { case overview, files, history }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            Group {
                if model.stage == .converting || model.stage == .publishing { progressContent }
                else if model.preview != nil { previewContent }
                else { planningContent }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().opacity(0.25)
            footer
        }
        .frame(minWidth: 760, idealWidth: 930, minHeight: 580, idealHeight: 710)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .interactiveDismissDisabled(model.isBusy)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(palette.accent)
                .frame(width: 33, height: 33).background(palette.selection.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("迁移仓库").font(.system(size: 16, weight: .semibold))
                Text(headerSubtitle).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if !model.isBusy {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .accessibilityLabel("关闭迁移窗口")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 17).background(palette.surface)
    }

    private var headerSubtitle: String {
        switch model.stage {
        case .form: "先进行只读预检，再在独立目录生成可检查的 Git 结果"
        case .planning: "正在读取来源历史与核对目标 Git"
        case .prepared: "迁移计划已生成，可确认作者映射和范围"
        case .converting: "正在生成本地转换结果，原 SVN 仓库不会被修改"
        case .preview: "转换结果已就绪，发布前可查看文件和完整历史"
        case .publishing: "正在明确发布到目标 Git 远端"
        case .published: "目标 Git 已发布；原 SVN 仓库保持不变"
        }
    }

    private var planningContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceCard
                targetCard
                if let plan = model.plan { planCard(plan) }
                if !model.warnings.isEmpty { warningList(model.warnings) }
            }
            .padding(22)
            .disabled(model.isBusy)
        }
    }

    private var sourceCard: some View {
        card(title: "来源 · SVN", icon: "externaldrive") {
            VStack(alignment: .leading, spacing: 11) {
                field("SVN 地址") {
                    TextField("https://server/svn/repository", text: sourceURLBinding)
                        .textFieldStyle(.plain).textSelection(.enabled)
                }
                DisclosureGroup("需要认证") {
                    HStack(spacing: 9) {
                        TextField("用户名", text: usernameBinding).textFieldStyle(.plain)
                        SecureField("密码（仅本次会话）", text: passwordBinding).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(palette.secondaryText.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .font(.system(size: 12, weight: .medium)).tint(palette.accent)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("迁移范围").font(.system(size: 12, weight: .medium))
                        Text(model.selectedSourceURL ?? "浏览后可选择仓库中的子目录")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondaryText)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    Button(model.isBrowsing ? "正在浏览…" : "浏览 SVN 目录") { model.browseRoot() }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true)).disabled(model.isBusy)
                }
                if let root = model.rootListingURL, let listing = model.listings[root] {
                    MigrationDirectoryTree(listing: listing, listings: model.listings, expanded: model.expandedURLs,
                                           selected: model.selectedSourceURL, palette: palette,
                                           toggleRoot: model.toggleRoot, toggle: model.toggleDirectory, select: model.selectDirectory)
                        .frame(height: 172).background(palette.sidebar.opacity(0.48), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private var targetCard: some View {
        card(title: "目标 · Git", icon: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 10) {
                field("Git 地址") {
                    TextField("https://server/owner/new-repository.git", text: targetURLBinding)
                        .textFieldStyle(.plain).textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    field("分支") { TextField("main", text: branchBinding).textFieldStyle(.plain) }
                    Picker("迁移方式", selection: modeBinding) {
                        ForEach(MigrationMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().frame(width: 190)
                }
                HStack(spacing: 9) {
                    Text(model.destinationParent?.path ?? "请选择本地结果父目录")
                        .font(.system(size: 12)).foregroundStyle(model.destinationParent == nil ? palette.secondaryText : palette.text)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).frame(height: 30).background(palette.secondaryText.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Button("选择…", action: model.chooseDestinationParent).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                }
                field("新文件夹") {
                    TextField("migrated-repository", text: directoryNameBinding).textFieldStyle(.plain)
                }
                if let destination = model.destination {
                    Text("将生成到：\(destination.path)").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondaryText)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
        }
    }

    private func planCard(_ plan: MigrationPlan) -> some View {
        card(title: "只读迁移计划", icon: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    planMetric("历史提交", value: "\(plan.source.revisions.count) 条")
                    planMetric("来源锚点", value: plan.source.anchor)
                    planMetric("方式", value: plan.source.mode.title)
                }
                if !plan.authors.isEmpty {
                    Divider().opacity(0.32)
                    Text("作者映射").font(.system(size: 12, weight: .medium))
                    Text("SVN 提交记录不提供邮箱；@authors.invalid 为明确占位值，可改为实际邮箱后再转换。")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    ForEach(plan.authors.keys.sorted(), id: \.self) { source in
                        let author = plan.authors[source] ?? .init(name: source, email: "")
                        HStack(spacing: 8) {
                            Text(source).font(.system(size: 11, design: .monospaced)).frame(width: 125, alignment: .leading).lineLimit(1).truncationMode(.middle)
                            TextField("名称", text: Binding(get: { author.name }, set: { model.updateAuthor(source, name: $0, email: author.email) })).textFieldStyle(.roundedBorder)
                            TextField("邮箱", text: Binding(get: { author.email }, set: { model.updateAuthor(source, name: author.name, email: $0) })).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
        }
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.stage == .publishing ? "正在发布" : "正在转换") .font(.system(size: 15, weight: .semibold))
            RepositoryTransferProgressView(progress: model.transferProgress, palette: palette,
                                           source: model.selectedSourceURL ?? model.sourceURL, destination: model.destination?.path,
                                           isCancelling: model.isCancelling, cancelTitle: "取消", cancel: model.cancel)
            Text(model.stage == .publishing ? "发布只会在你确认预览后的这一步执行。" : "取消会保留已经生成的隔离结果，以便继续转换或检查。")
                .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            Spacer()
        }.padding(22)
    }

    private var previewContent: some View {
        VStack(spacing: 0) {
            WorkbenchSegmentedPicker(title: "转换预览", selection: $previewTab,
                                     options: [.init(.overview, "概览"), .init(.files, "文件"), .init(.history, "历史")], palette: palette)
                .frame(width: 285).padding(.vertical, 13)
            if let result = model.publication {
                Label(result.message, systemImage: result.state == .published ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 12)).textSelection(.enabled)
                    .foregroundStyle(result.state == .published ? palette.accent : palette.removed)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(palette.sidebar).padding(.horizontal, 22).padding(.bottom, 10)
            }
            Divider().opacity(0.2)
            switch previewTab {
            case .overview: overview
            case .files: filePreviewContent
            case .history: historyPreviewContent
            }
        }
    }

    private var overview: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if let preview = model.preview {
                HStack(spacing: 12) {
                    previewMetric("迁移历史", "\(preview.mappings.count) / \(preview.plan.source.revisions.count)")
                    previewMetric("文件核对", "\(preview.files.count) 项")
                    previewMetric("可发布", preview.canPublish ? "是" : "需处理")
                }
                card(title: "来源 → 目标确认", icon: "arrow.right.circle") {
                    VStack(spacing: 7) {
                        overviewRow("SVN 来源", preview.plan.source.location.url)
                        overviewRow("来源锚点", preview.plan.source.anchor)
                        overviewRow("Git 目标", preview.plan.remoteURL)
                        overviewRow("目标分支", preview.plan.branch)
                        overviewRow("转换方式", preview.plan.source.mode.title)
                    }
                }
                Text("本地结果：\(preview.repository.path)").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                if !model.warnings.isEmpty { warningList(model.warnings) }
                card(title: "提交对应关系", icon: "arrow.left.arrow.right") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preview.mappings.suffix(20)) { mapping in
                            HStack { Text(mapping.source.id).font(.system(size: 11, design: .monospaced)).frame(width: 90, alignment: .leading); Image(systemName: "arrow.right").font(.caption).foregroundStyle(palette.secondaryText); Text(String(mapping.targetCommit.prefix(12))).font(.system(size: 11, design: .monospaced)); Text(mapping.source.message).font(.system(size: 11)).lineLimit(1).truncationMode(.tail) }
                        }
                        if preview.mappings.count > 20 { Text("完整列表在“历史”中查看。").font(.system(size: 11)).foregroundStyle(palette.secondaryText) }
                    }
                }
            }
        }.padding(22) }
    }

    private var filePreviewContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("筛选文件…", text: $model.fileSearch).textFieldStyle(.roundedBorder)
                MigrationFileTree(files: filteredFiles, expanded: model.expandedFileDirectories, selected: model.selectedFilePath, palette: palette,
                                  toggle: model.toggleFileDirectory, select: model.loadFile)
            }.padding(12).frame(minWidth: 200, idealWidth: 240, maxWidth: 280).background(palette.sidebar.opacity(0.5))
            Divider().opacity(0.2)
            fileTextComparison.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var fileTextComparison: some View {
        Group {
            if let item = model.filePreview {
                if item.isBinary {
                    VStack(spacing: 0) {
                        Label("二进制文件 · 仅比较摘要", systemImage: "doc.badge.gearshape")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(palette.sidebar.opacity(0.52))
                        HStack(spacing: 0) {
                            previewColumn("SVN 来源摘要", text: item.sourceText)
                            Divider().opacity(0.2)
                            previewColumn("Git 结果摘要", text: item.targetText)
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        previewColumn("SVN 来源", text: item.sourceText)
                        Divider().opacity(0.2)
                        previewColumn("Git 结果", text: item.targetText)
                    }
                    .overlay(alignment: .topTrailing) { if item.isTruncated { Text("内容已截断").font(.caption2).foregroundStyle(palette.secondaryText).padding(8) } }
                }
            } else if let path = model.selectedFilePath {
                ProgressView("正在读取 \(path)…")
            } else { ContentUnavailableView("选择一个文件", systemImage: "doc.text.magnifyingglass", description: Text("查看来源和转换结果的文本。")) }
        }
    }

    private var historyPreviewContent: some View {
        HStack(spacing: 0) {
            List(model.preview?.mappings ?? [], selection: Binding(get: { model.selectedCommit }, set: { if let value = $0 { model.loadHistoryPatch(commit: value) } })) { mapping in
                VStack(alignment: .leading, spacing: 3) {
                    Text(mapping.source.message).font(.system(size: 12, weight: .medium)).lineLimit(3)
                    Text("\(mapping.author.name) <\(mapping.author.email)>").font(.system(size: 10)).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
                    HStack { Text(mapping.source.id); Text("→"); Text(String(mapping.targetCommit.prefix(12))); Spacer(); Text(mapping.source.date.formatted(date: .abbreviated, time: .shortened)) }
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondaryText)
                }.padding(.vertical, 3).tag(mapping.targetCommit)
            }.listStyle(.sidebar).frame(minWidth: 300, idealWidth: 390, maxWidth: 460).background(palette.sidebar.opacity(0.5))
            Divider().opacity(0.2)
            Group {
                if let mapping = selectedMapping {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mapping.source.message).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                            Text("\(mapping.author.name) <\(mapping.author.email)> · \(mapping.source.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.sidebar.opacity(0.42))
                        if let patch = model.historyPatch { MigrationPatchPreview(text: patch.text, palette: palette) }
                        else { ProgressView("正在读取提交差异…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                } else { ContentUnavailableView("选择一条提交", systemImage: "clock.arrow.circlepath", description: Text("查看转换后的提交差异。")) }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(palette.removed).lineLimit(2).help(error) }
            else { Text(model.stage == .published ? "已确认发布，可打开本地结果继续工作。" : (model.preview == nil ? "预检和转换不会写入目标远端。" : "请检查预览后再发布；发布会写入目标 Git 远端。")).font(.system(size: 11)).foregroundStyle(palette.secondaryText) }
            Spacer()
            if model.isBusy && model.stage != .converting && model.stage != .publishing {
                Button(model.isCancelling ? "正在取消…" : "取消操作", action: model.cancel)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                    .disabled(model.isCancelling)
            }
            if model.preview == nil, let folder = model.preservedDirectory {
                Button("查看保留位置") { model.revealPreservedDirectory() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet)).help(folder.path)
            }
            if let preview = model.preview {
                Button("返回调整", action: model.returnToPlan)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(model.isBusy)
                Button("保留并关闭", action: dismiss).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet)).help("本地转换结果不会被删除。").disabled(model.isBusy)
                Button("打开结果") { openResult(preview.repository) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(model.isBusy)
                Button(model.stage == .published ? "已发布" : "发布到 Git") { model.publish() }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(!preview.canPublish || model.isBusy || model.stage == .published)
            } else if model.plan != nil {
                Button("生成转换预览", action: model.preparePreview).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(model.isBusy)
            } else {
                Button("继续已有迁移…", action: model.resumeExistingMigration)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(model.isBusy)
                Button("开始只读预检", action: model.makePlan).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(model.isBusy)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14).background(palette.surface)
    }

    private var filteredFiles: [MigrationFileComparison] { (model.preview?.files ?? []).filter { model.fileSearch.isEmpty || $0.path.localizedCaseInsensitiveContains(model.fileSearch) } }
    private var selectedMapping: MigrationMapping? { model.preview?.mappings.first { $0.targetCommit == model.selectedCommit } }
    private var sourceURLBinding: Binding<String> { Binding(get: { model.sourceURL }, set: { model.sourceURL = $0; model.sourceURLChanged() }) }
    private var usernameBinding: Binding<String> { Binding(get: { model.username }, set: { model.username = $0; model.invalidatePlan() }) }
    private var passwordBinding: Binding<String> { Binding(get: { model.password }, set: { model.password = $0; model.invalidatePlan() }) }
    private var targetURLBinding: Binding<String> { Binding(get: { model.targetURL }, set: { model.targetURL = $0; model.invalidatePlan() }) }
    private var branchBinding: Binding<String> { Binding(get: { model.branch }, set: { model.branch = $0; model.invalidatePlan() }) }
    private var directoryNameBinding: Binding<String> { Binding(get: { model.directoryName }, set: { model.directoryName = $0; model.invalidatePlan() }) }
    private var modeBinding: Binding<String> {
        Binding(get: { model.mode.rawValue }, set: { raw in
            if let value = MigrationMode(rawValue: raw) { model.mode = value; model.invalidatePlan() }
        })
    }
    private func card<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 13) { Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)); content() }.padding(16).background(palette.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous)) }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { HStack(spacing: 10) { Text(title).font(.system(size: 12)).foregroundStyle(palette.secondaryText).frame(width: 64, alignment: .leading); content() }.padding(.horizontal, 10).frame(height: 31).background(palette.secondaryText.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous)) }
    private func planMetric(_ title: String, value: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 10)).foregroundStyle(palette.secondaryText); Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func previewMetric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 11)).foregroundStyle(palette.secondaryText); Text(value).font(.system(size: 17, weight: .semibold)) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
    private func overviewRow(_ title: String, _ value: String) -> some View { HStack(alignment: .firstTextBaseline, spacing: 12) { Text(title).font(.system(size: 11)).foregroundStyle(palette.secondaryText).frame(width: 58, alignment: .leading); Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
    private func warningList(_ values: [String]) -> some View { VStack(alignment: .leading, spacing: 7) { Label("需要注意", systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold)); ForEach(values, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(palette.secondaryText) } }.padding(13).background(palette.removed.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous)) }
    private func stateMark(_ state: MigrationFileComparison.State) -> some View { Image(systemName: state == .identical ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(state == .identical ? palette.accent : palette.removed).font(.system(size: 11)) }
    private func previewColumn(_ title: String, text: String) -> some View { VStack(spacing: 0) { Text(title).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8).background(palette.sidebar.opacity(0.5)); ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct MigrationDirectoryTree: View {
    private struct Node: Identifiable { let id: String; let name: String; let url: String; let depth: Int; let root: Bool }
    let listing: RemoteDirectoryListing; let listings: [String: RemoteDirectoryListing]; let expanded: Set<String>; let selected: String?; let palette: AppPalette
    let toggleRoot: () -> Void; let toggle: (RemoteDirectoryEntry) -> Void; let select: (String) -> Void
    var body: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 1) { ForEach(nodes) { node in row(node) } }.padding(6) }
    }
    private var nodes: [Node] {
        let root = Node(id: listing.url, name: "仓库根目录", url: listing.url, depth: 0, root: true)
        return [root] + (expanded.contains(listing.url) ? flattened(listing.entries, depth: 1) : [])
    }
    private func flattened(_ entries: [RemoteDirectoryEntry], depth: Int) -> [Node] {
        entries.filter(\.isDirectory).flatMap { entry in
            let node = Node(id: entry.url, name: entry.name, url: entry.url, depth: depth, root: false)
            guard expanded.contains(entry.url), let child = listings[entry.url] else { return [node] }
            return [node] + flattened(child.entries, depth: depth + 1)
        }
    }
    private func row(_ node: Node) -> some View {
        let isExpanded = expanded.contains(node.url)
        return HStack(spacing: 3) {
            Button { if node.root { toggleRoot() } else { toggle(.init(name: node.name, url: node.url, isDirectory: true)) } } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 14, height: 22)
            }.buttonStyle(.plain)
            Button { select(node.url) } label: {
                Label(node.name, systemImage: "folder").font(.system(size: 11, weight: selected == node.url ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).frame(height: 22)
            }.buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(node.depth) * 15).padding(.trailing, 5)
        .background(selected == node.url ? palette.selection.opacity(0.68) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct MigrationFileTree: View {
    private struct Node: Identifiable { let id: String; let path: String; let name: String; let depth: Int; let directory: Bool; let comparison: MigrationFileComparison? }
    let files: [MigrationFileComparison]; let expanded: Set<String>; let selected: String?; let palette: AppPalette
    let toggle: (String) -> Void; let select: (String) -> Void
    var body: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 1) { ForEach(nodes) { node in row(node) } }.padding(6) }
            .background(palette.sidebar.opacity(0.24), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    private var nodes: [Node] {
        let normalized = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let allDirectories = Set(normalized.values.compactMap { item -> String? in
            if item.target?.kind == .directory || item.source?.kind == .directory { return item.path }
            return nil
        }).union(files.flatMap { item in parents(of: item.path) })
        return flatten(parent: "", depth: 0, source: normalized, directories: allDirectories)
    }
    private func parents(of path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init); guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
    }
    private func flatten(parent: String, depth: Int, source: [String: MigrationFileComparison], directories: Set<String>) -> [Node] {
        let direct = (Array(source.keys) + Array(directories)).filter { path in
            let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
            return parentPath == parent
        }
        let unique = Array(Set(direct)).sorted { lhs, rhs in
            let ld = directories.contains(lhs), rd = directories.contains(rhs)
            return ld == rd ? lhs.localizedStandardCompare(rhs) == .orderedAscending : ld
        }
        return unique.flatMap { path in
            let directory = directories.contains(path)
            let node = Node(id: path, path: path, name: path.split(separator: "/").last.map(String.init) ?? path, depth: depth, directory: directory, comparison: source[path])
            return directory && expanded.contains(path) ? [node] + flatten(parent: path, depth: depth + 1, source: source, directories: directories) : [node]
        }
    }
    private func row(_ node: Node) -> some View {
        HStack(spacing: 4) {
            if node.directory {
                Button { toggle(node.path) } label: { Image(systemName: expanded.contains(node.path) ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 13, height: 23) }.buttonStyle(.plain)
            } else { Color.clear.frame(width: 13, height: 23) }
            Button { if !node.directory { select(node.path) } } label: {
                HStack(spacing: 6) { Image(systemName: node.directory ? "folder" : "doc").foregroundStyle(node.directory ? palette.accent : palette.secondaryText); Text(node.name).lineLimit(1).truncationMode(.middle); Spacer(); if let item = node.comparison { stateMark(item.state) } }
                    .font(.system(size: 11, weight: selected == node.path ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).frame(height: 23)
            }.buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(node.depth) * 15).padding(.trailing, 5)
        .background(selected == node.path ? palette.selection.opacity(0.68) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    private func stateMark(_ state: MigrationFileComparison.State) -> some View { Image(systemName: state == .identical ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(state == .identical ? palette.accent : palette.removed).font(.system(size: 10)) }
}

private struct MigrationPatchPreview: View {
    let text: String; let palette: AppPalette
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                    let line = String(raw)
                    Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 1.5)
                        .background(color(for: line))
                }
            }.padding(.vertical, 12)
        }
    }
    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return palette.accent.opacity(0.14) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return palette.removed.opacity(0.14) }
        if line.hasPrefix("@@") { return palette.selection.opacity(0.55) }
        return .clear
    }
}
