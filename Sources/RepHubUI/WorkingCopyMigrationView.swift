import SwiftUI
import DesignSystem
import VersionControlCore

/// 当前 SVN 工作副本迁移：预览使用隔离 Git，确认后才把 .git 安装到当前目录并发布。
struct WorkingCopyMigrationView: View {
    @Bindable var model: WorkingCopyMigrationModel
    let palette: AppPalette
    let dismiss: () -> Void
    let completed: (URL) -> Void
    @State private var tab: Tab = .overview
    private enum Tab: Hashable { case overview, files, history }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.24)
            Group {
                if model.stage == .converting || model.stage == .applying { progress }
                else if model.preview != nil { preview }
                else { form }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().opacity(0.24)
            footer
        }
        .frame(minWidth: 760, idealWidth: 930, minHeight: 580, idealHeight: 710)
        .background(palette.background).foregroundStyle(palette.text).interactiveDismissDisabled(model.isBusy)
    }
    private var header: some View { HStack(spacing: 11) {
        Image(systemName: "folder.badge.gearshape").font(.system(size: 17, weight: .medium)).foregroundStyle(palette.accent).frame(width: 33, height: 33).background(palette.selection.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        VStack(alignment: .leading, spacing: 2) { Text("当前工作副本迁移").font(.system(size: 16, weight: .semibold)); Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.secondaryText) }
        Spacer()
        if !model.isBusy { Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true)) }
    }.padding(.horizontal, 22).padding(.vertical, 17).background(palette.surface) }
    private var subtitle: String { switch model.stage { case .form: model.action == .supplement ? "补迁只检查 Git 工作区干净；SVN 本地状态不要求干净" : "首次迁移会检查 SVN 工作副本干净，再在隔离目录准备 Git 预览"; case .planning: "正在核对 SVN 截至版本和 Git 目标"; case .prepared: "迁移计划已生成，可调整作者映射"; case .converting: "正在生成隔离预览，不会修改当前工作副本"; case .preview: "预览已就绪，确认后才写入当前目录并发布"; case .applying: "正在应用 .git 到当前目录并发布"; case .finished: "当前目录已成为 Git 与 SVN 共管工作副本" } }
    private var form: some View { ScrollView { VStack(alignment: .leading, spacing: 17) {
        card("本地 SVN 工作副本", "externaldrive") { HStack(spacing: 10) { Text(model.directory?.path ?? "请选择本地 SVN 工作副本").font(.system(size: 12)).foregroundStyle(model.directory == nil ? palette.secondaryText : palette.text).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 31).background(palette.secondaryText.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous)); Button(model.isInspectingRecord ? "正在识别…" : "选择…", action: model.chooseDirectory).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true)).disabled(model.isBusy) }
            Text("首次迁移会检查 SVN 工作副本干净；补迁仅检查 Git 工作区干净，SVN 可保留由 Git 演进带来的本地差异。迁移过程不会更新或提交 SVN。") .font(.system(size: 11)).foregroundStyle(palette.secondaryText) }
        card("目标 · Git", "point.3.connected.trianglepath.dotted") { VStack(spacing: 10) {
            field("Git 地址") { TextField("https://server/owner/repository.git", text: remoteBinding).textFieldStyle(.plain).textSelection(.enabled).disabled(model.hasExistingRecord) }
            HStack(spacing: 10) { field("分支") { TextField("main", text: branchBinding).textFieldStyle(.plain).disabled(model.hasExistingRecord) }; Picker("方式", selection: modeBinding) { ForEach(MigrationMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }.labelsHidden().frame(width: 180) }
            Picker("迁移动作", selection: actionBinding) { ForEach([WorkingCopyMigrationAction.initial, .supplement], id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                .pickerStyle(.segmented)
            if model.hasExistingRecord { Text("检测到已有迁移记录：补迁将从上次锚点后的连续 SVN 修订开始，不能跳选以避免遗漏。目标与分支由记录锁定。") .font(.system(size: 11)).foregroundStyle(palette.secondaryText) }
        } }
        if let plan = model.plan { planCard(plan) }
    }.padding(22).disabled(model.isBusy) } }
    private func planCard(_ plan: WorkingCopyMigrationPlan) -> some View { card("迁移计划", "checkmark.seal") { VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 18) { metric("动作", plan.action.title); metric("历史", "\(plan.source.revisions.count) 条"); metric("截至版本", plan.source.anchor) }
        if !plan.authors.isEmpty { Divider().opacity(0.3); Text("作者映射").font(.system(size: 12, weight: .medium)); Text("SVN 不提供邮箱；@authors.invalid 是明确占位值，可编辑为实际邮箱。").font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            ForEach(plan.authors.keys.sorted(), id: \.self) { source in let author = plan.authors[source] ?? .init(name: source, email: ""); HStack(spacing: 8) { Text(source).font(.system(size: 11, design: .monospaced)).frame(width: 120, alignment: .leading).lineLimit(1); TextField("名称", text: Binding(get: { author.name }, set: { model.updateAuthor(source, name: $0, email: author.email) })).textFieldStyle(.roundedBorder); TextField("邮箱", text: Binding(get: { author.email }, set: { model.updateAuthor(source, name: author.name, email: $0) })).textFieldStyle(.roundedBorder) } }
        }
    } } }
    private var progress: some View { VStack(alignment: .leading, spacing: 16) { Text(model.stage == .applying ? "正在应用并发布" : "正在准备转换预览").font(.system(size: 15, weight: .semibold)); RepositoryTransferProgressView(progress: model.transferProgress, palette: palette, source: model.directory?.path, destination: model.preservedDirectory?.path, isCancelling: model.isCancelling, cancelTitle: "取消", cancel: model.cancel); Text("隔离目录不是新的工程目录。预览确认前不会覆盖当前工作副本。") .font(.system(size: 11)).foregroundStyle(palette.secondaryText); Spacer() }.padding(22) }
    private var preview: some View { VStack(spacing: 0) { WorkbenchSegmentedPicker(title: "转换预览", selection: $tab, options: [.init(.overview, "概览"), .init(.files, "文件"), .init(.history, "历史")], palette: palette).frame(width: 285).padding(.vertical, 13); Divider().opacity(0.2); switch tab { case .overview: overview; case .files: files; case .history: history } } }
    private var overview: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { if let preview = model.preview { HStack(spacing: 12) { metricCard("本次新增", "\(currentMappings(preview: preview).count) 条"); metricCard("文件核对", "\(preview.files.count) 项"); metricCard("方式", preview.plan.action.title) }; card("来源 → 当前工作副本", "arrow.right.circle") { VStack(spacing: 7) { row("SVN 来源", preview.plan.workingCopy.sourceURL); row("仓库 UUID", preview.plan.workingCopy.repositoryUUID); row("本地 BASE", preview.plan.workingCopy.baseRevision); row("Git 目标", preview.plan.remoteURL); row("目标分支", preview.plan.branch) } }; if let previous = preview.plan.previousRecord { card("已迁移锚点", "arrow.triangle.branch") { VStack(spacing: 7) { row("开始修订", previous.startRevision); row("接管节点", previous.cutoverRevision); row("上次已迁", previous.lastRevision); row("本次截至", preview.plan.source.anchor) } } } else { card("首次接管锚点", "arrow.triangle.branch") { VStack(spacing: 7) { row("开始修订", preview.plan.source.revisions.first?.id ?? "—"); row("本地 BASE", preview.plan.workingCopy.baseRevision); row("接管节点", preview.plan.workingCopy.baseRevision); row("本次截至", preview.plan.source.anchor) } } }; if !preview.warnings.isEmpty { warnings(preview.warnings) }; Text("隔离预览：\(preview.repository.path)").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondaryText).textSelection(.enabled) } }.padding(22) } }
    private var files: some View { HStack(spacing: 0) { VStack(alignment: .leading, spacing: 8) { TextField("筛选文件…", text: $model.fileSearch).textFieldStyle(.roundedBorder); if model.action == .supplement { Text("标记表示本次补迁带来的内容变化；其他 Git 文件保持原样。") .font(.system(size: 10)).foregroundStyle(palette.secondaryText) }; WorkingFileTree(files: filteredFiles, expanded: model.expandedDirectories, selected: model.selectedFilePath, palette: palette, allowsDifferences: model.action == .supplement, toggle: model.toggleDirectory, select: model.loadFile) }.padding(12).frame(minWidth: 250, idealWidth: 320, maxWidth: 380).background(palette.sidebar.opacity(0.5)); Divider().opacity(0.2); fileContent.frame(maxWidth: .infinity, maxHeight: .infinity) } }
    private var fileContent: some View { Group { if let item = model.filePreview { VStack(spacing: 0) { if item.isBinary { Label("二进制文件 · 仅比较摘要", systemImage: "doc.badge.gearshape").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(palette.sidebar.opacity(0.5)) }; HStack(spacing: 0) { column(model.action == .supplement ? "当前 Git" : "SVN 来源", item.sourceText); Divider().opacity(0.2); column("转换结果", item.targetText) } } } else if model.selectedFilePath != nil { ProgressView("正在读取文件预览…") } else { ContentUnavailableView("选择一个文件", systemImage: "doc.text.magnifyingglass", description: Text("查看当前内容和转换结果。")) } } }
    private var history: some View { HStack(spacing: 0) { List(model.preview.map { currentMappings(preview: $0) } ?? [], selection: Binding(get: { model.selectedCommit }, set: { if let value = $0 { model.loadHistoryPatch(value) } })) { item in VStack(alignment: .leading, spacing: 3) { Text(item.source.message).font(.system(size: 12, weight: .medium)).lineLimit(3); Text("\(item.author.name) <\(item.author.email)>").font(.system(size: 10)).foregroundStyle(palette.secondaryText).lineLimit(1); HStack { Text(item.source.id); Text("→"); Text(String(item.targetCommit.prefix(12))); Spacer(); Text(item.source.date.formatted(date: .abbreviated, time: .shortened)) }.font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondaryText) }.padding(.vertical, 3).tag(item.targetCommit) }.listStyle(.sidebar).frame(minWidth: 300, idealWidth: 390, maxWidth: 460).background(palette.sidebar.opacity(0.5)); Divider().opacity(0.2); Group { if let patch = model.historyPatch { WorkingPatchPreview(text: patch.text, palette: palette) } else if model.selectedCommit != nil { ProgressView("正在读取提交差异…") } else { ContentUnavailableView("选择一条提交", systemImage: "clock.arrow.circlepath", description: Text("查看本次新增提交的转换后差异。")) } }.frame(maxWidth: .infinity, maxHeight: .infinity) } }
    private var footer: some View {
        HStack(spacing: 10) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(palette.removed).lineLimit(2).help(error)
            } else if let result = model.result {
                VStack(alignment: .leading, spacing: 2) {
                    Label(result.publication.message, systemImage: result.publication.state == .published ? "checkmark.circle" : "exclamationmark.circle")
                    if result.publication.state != .published {
                        Text("本地 Git 已应用并保留本次目标远端。可在此重试；关闭后可打开当前目录，使用“管理当前仓库”的 Git 推送继续发布。")
                    }
                }.font(.system(size: 11)).foregroundStyle(result.publication.state == .published ? palette.accent : palette.secondaryText).lineLimit(2)
            } else {
                Text(model.preview == nil ? "预览完成前不会向当前目录或目标远端写入内容。" : "确认后会将已核对的 Git 结果应用到当前目录，并发布到目标远端；关闭窗口后需重新生成预览。")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if model.preview == nil, let folder = model.preservedDirectory { Button("查看暂存位置", action: model.revealPreservedDirectory).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet)).help(folder.path) }
            if let result = model.result { Button("打开当前目录") { completed(result.directory) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(model.isBusy) }
            if model.preview != nil { Button(model.result?.publication.state == .published ? "已发布" : (model.result == nil ? "应用到当前目录并发布" : "重试发布"), action: model.applyAndPublish).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(model.isBusy || model.result?.publication.state == .published) }
            else if model.plan != nil { Button("生成转换预览", action: model.preparePreview).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(model.isBusy) }
            else { Button("只读预检", action: model.makePlan).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(model.isBusy) }
        }.padding(.horizontal, 22).padding(.vertical, 14).background(palette.surface)
    }
    private var remoteBinding: Binding<String> { Binding(get: { model.remoteURL }, set: { model.remoteURL = $0; model.invalidatePlan() }) }
    private var branchBinding: Binding<String> { Binding(get: { model.branch }, set: { model.branch = $0; model.invalidatePlan() }) }
    private var modeBinding: Binding<String> { Binding(get: { model.mode.rawValue }, set: { if let mode = MigrationMode(rawValue: $0) { model.mode = mode; model.invalidatePlan() } }) }
    private var actionBinding: Binding<String> { Binding(get: { model.action.rawValue }, set: { if let action = WorkingCopyMigrationAction(rawValue: $0) { model.setAction(action) } }) }
    private var filteredFiles: [MigrationFileComparison] { (model.preview?.files ?? []).filter { model.fileSearch.isEmpty || $0.path.localizedCaseInsensitiveContains(model.fileSearch) } }
    private func currentMappings(preview: WorkingCopyMigrationPreview) -> [MigrationMapping] { let oldCount = preview.plan.previousRecord?.mappings.count ?? 0; return Array(preview.mappings.dropFirst(oldCount)) }
    private func card<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 13) { Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)); content() }.padding(16).background(palette.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous)) }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { HStack(spacing: 10) { Text(title).font(.system(size: 12)).foregroundStyle(palette.secondaryText).frame(width: 64, alignment: .leading); content() }.padding(.horizontal, 10).frame(height: 31).background(palette.secondaryText.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous)) }
    private func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 10)).foregroundStyle(palette.secondaryText); Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func metricCard(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 11)).foregroundStyle(palette.secondaryText); Text(value).font(.system(size: 17, weight: .semibold)) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
    private func row(_ title: String, _ value: String) -> some View { HStack(alignment: .firstTextBaseline, spacing: 12) { Text(title).font(.system(size: 11)).foregroundStyle(palette.secondaryText).frame(width: 60, alignment: .leading); Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
    private func warnings(_ values: [String]) -> some View { VStack(alignment: .leading, spacing: 7) { Label("需要注意", systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold)); ForEach(values, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(palette.secondaryText) } }.padding(13).background(palette.removed.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous)) }
    private func column(_ title: String, _ text: String) -> some View { VStack(spacing: 0) { Text(title).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8).background(palette.sidebar.opacity(0.5)); ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct WorkingFileTree: View {
    private struct Node: Identifiable { let id: String; let path: String; let name: String; let depth: Int; let directory: Bool; let item: MigrationFileComparison? }
    let files: [MigrationFileComparison]; let expanded: Set<String>; let selected: String?; let palette: AppPalette; let allowsDifferences: Bool; let toggle: (String) -> Void; let select: (String) -> Void
    var body: some View { ScrollView { LazyVStack(alignment: .leading, spacing: 1) { ForEach(nodes) { node in row(node) } }.padding(6) }.background(palette.sidebar.opacity(0.24), in: RoundedRectangle(cornerRadius: 7, style: .continuous)) }
    private var nodes: [Node] {
        let items = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let directories = Set(items.values.compactMap { ($0.source?.kind == .directory || $0.target?.kind == .directory) ? $0.path : nil }).union(files.flatMap { parents($0.path) })
        return flatten(parent: "", depth: 0, items: items, directories: directories)
    }
    private func parents(_ path: String) -> [String] { let components = path.split(separator: "/").map(String.init); return components.count < 2 ? [] : (1..<components.count).map { components.prefix($0).joined(separator: "/") } }
    private func flatten(parent: String, depth: Int, items: [String: MigrationFileComparison], directories: Set<String>) -> [Node] {
        let direct = Set((Array(items.keys) + Array(directories)).filter { $0.split(separator: "/").dropLast().joined(separator: "/") == parent })
        return direct.sorted { lhs, rhs in let ld = directories.contains(lhs), rd = directories.contains(rhs); return ld == rd ? lhs.localizedStandardCompare(rhs) == .orderedAscending : ld }.flatMap { path in
            let directory = directories.contains(path); let node = Node(id: path, path: path, name: path.split(separator: "/").last.map(String.init) ?? path, depth: depth, directory: directory, item: items[path])
            return directory && expanded.contains(path) ? [node] + flatten(parent: path, depth: depth + 1, items: items, directories: directories) : [node]
        }
    }
    private func row(_ node: Node) -> some View { HStack(spacing: 4) { if node.directory { Button { toggle(node.path) } label: { Image(systemName: expanded.contains(node.path) ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 13, height: 23) }.buttonStyle(.plain) } else { Color.clear.frame(width: 13, height: 23) }; Button { if !node.directory { select(node.path) } } label: { HStack(spacing: 6) { Image(systemName: node.directory ? "folder" : "doc").foregroundStyle(node.directory ? palette.accent : palette.secondaryText); Text(node.name).lineLimit(1).truncationMode(.middle); Spacer(); if let item = node.item { indicator(item.state) } }.font(.system(size: 11, weight: selected == node.path ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).frame(height: 23) }.buttonStyle(.plain) }.padding(.leading, CGFloat(node.depth) * 15).padding(.trailing, 5).background(selected == node.path ? palette.selection.opacity(0.68) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous)) }
    private func indicator(_ state: MigrationFileComparison.State) -> some View { Group { switch state { case .identical: Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent); case .omittedDirectory: Image(systemName: "minus.circle").foregroundStyle(palette.secondaryText).help("Git 不记录空目录，本地目录会保留。"); case .different: Image(systemName: allowsDifferences ? "arrow.left.arrow.right.circle" : "exclamationmark.circle.fill").foregroundStyle(allowsDifferences ? palette.secondaryText : palette.removed) } }.font(.system(size: 10)) }
}
private struct WorkingPatchPreview: View {
    let palette: AppPalette
    private let lines: [PatchDisplayLine]
    private let lineNumberWidth: CGFloat

    init(text: String, palette: AppPalette) {
        self.palette = palette
        let parsedLines = PatchLineParser.parse(text)
        lines = parsedLines
        let digits = parsedLines.reduce(1) { current, line in
            max(current, String(max(line.oldLine ?? 0, line.newLine ?? 0)).count)
        }
        lineNumberWidth = CGFloat(max(3, digits)) * 7 + 10
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    lineNumberLabel("旧")
                    lineNumberLabel("新")
                    Text("内容")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .padding(.leading, 7)
                    Spacer(minLength: 12)
                }
                .frame(height: 23)
                .background(palette.sidebar.opacity(0.5))

                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    HStack(spacing: 0) {
                        lineNumber(line.oldLine)
                        lineNumber(line.newLine)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.leading, 7)
                        Spacer(minLength: 12)
                    }
                    .frame(minHeight: 21, alignment: .leading)
                    .background(color(line.text))
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func lineNumberLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(palette.secondaryText)
            .frame(width: lineNumberWidth, alignment: .trailing)
            .padding(.trailing, 7)
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(palette.secondaryText)
            .frame(width: lineNumberWidth, alignment: .trailing)
            .padding(.trailing, 7)
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return palette.accent.opacity(0.14) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return palette.removed.opacity(0.14) }
        if line.hasPrefix("@@") { return palette.selection.opacity(0.55) }
        return .clear
    }
}
