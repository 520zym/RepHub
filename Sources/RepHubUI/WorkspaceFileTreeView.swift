import SwiftUI
import Observation
import DesignSystem
import VersionControlCore

/// 工作区侧栏：默认浏览实际文件，按需展开目录；“变更”保留版本控制适配器提供的完整变更集。
struct WorkspaceFileTreeView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var browser: WorkspaceFileBrowser
    let palette: AppPalette
    let showsBindingPicker: Bool
    @State private var cachedChangeRows: [WorkspaceChangeRow] = []

    init(model: WorkspaceModel, palette: AppPalette, showsBindingPicker: Bool) {
        self.model = model
        self.browser = model.fileBrowser
        self.palette = palette
        self.showsBindingPicker = showsBindingPicker
    }

    private var changes: [FileChange] {
        (model.snapshot?.changes ?? []).filter { browser.filter.isEmpty || $0.path.localizedCaseInsensitiveContains(browser.filter) }
    }

    private var changesByPath: [String: FileChange] {
        Dictionary((model.snapshot?.changes ?? []).map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private var changeInputKey: String {
        let values = (model.snapshot?.changes ?? []).map { "\($0.path)\u{1F}\($0.kind.rawValue)\u{1F}\($0.isStaged)\u{1F}\($0.isUnstaged)" }
        return values.joined(separator: "\u{1E}") + "\u{1D}" + browser.filter
    }

    var body: some View {
        // 变更索引按当前渲染构建一次，再由全部文件的每一行复用。
        let changeIndex = changesByPath
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsBindingPicker, let bindings = model.workspace?.bindings, bindings.count > 1 { bindingPicker(bindings) }
            WorkbenchSearchField(browser.mode == .files ? "筛选已读取的文件…" : "筛选变更文件…", text: $browser.filter, palette: palette)
                .padding(.horizontal, 10).padding(.bottom, 8)
            if browser.mode == .files, !browser.filter.isEmpty {
                Text("仅搜索已展开并读取的目录")
                    .font(.system(size: 10)).foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if browser.mode == .files { fileTree(changeIndex) } else { changeTree }
                }
                .padding(.horizontal, 6).padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let issue = browser.mode == .files ? browser.issue(in: "") : model.snapshot?.issues.first {
                ErrorStrip(message: issue, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebar)
        .onAppear(perform: rebuildChangeRows)
        .onChange(of: changeInputKey) { _, _ in rebuildChangeRows() }
        .onChange(of: model.treeState.workingCollapsed) { _, _ in rebuildChangeRows() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            WorkbenchSegmentedPicker(title: "文件范围", selection: $browser.mode,
                                     options: [.init(.files, "全部文件"), .init(.changes, "变更")], palette: palette)
                .frame(width: 155)
            Spacer(minLength: 0)
            if browser.mode == .files {
                Menu {
                    Button("展开已读取的目录", action: browser.expandLoadedDirectories)
                    Button("全部收起", action: browser.collapseAll)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .help("仅展开已读取的目录，不扫描整个工作区")
            } else {
                Text("\(model.snapshot?.changes.count ?? 0)")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
        }
        .padding(.horizontal, 12).frame(height: 43)
    }

    private func bindingPicker(_ bindings: [RepositoryBinding]) -> some View {
        RepositorySourcePicker(bindings: bindings, selectedID: model.selectedBindingID,
                               select: model.selectBinding, palette: palette)
            .padding(.horizontal, 10).padding(.bottom, 8)
    }

    @ViewBuilder private func fileTree(_ changeIndex: [String: FileChange]) -> some View {
        if browser.filter.isEmpty {
            rootRow
            if browser.isLoading("") && browser.children(in: "").isEmpty {
                ProgressView().controlSize(.small).padding(16)
            }
            ForEach(browser.visibleRows) { row in
                fileRow(row, changes: changeIndex)
                directoryIssue(for: row)
            }
        } else {
            let rows = matchingLoadedRows()
            if rows.isEmpty && !browser.isLoading("") {
                Text("已读取目录中没有匹配的文件")
                    .font(.system(size: 12)).foregroundStyle(palette.secondaryText).padding(16)
            }
            ForEach(rows) { row in
                fileRow(row, changes: changeIndex, forceLeaf: true)
                directoryIssue(for: row)
            }
        }
    }

    private var rootRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill").foregroundStyle(palette.accent).frame(width: 16)
            Text(model.selectedBinding?.root.lastPathComponent ?? model.workspace?.name ?? "工作区").fontWeight(.medium)
            Spacer(minLength: 0)
            if browser.isLoading("") { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 30)
    }

    private func matchingLoadedRows() -> [WorkspaceFileBrowserRow] {
        let query = browser.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return browser.loadedEntries
            .filter { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
            .map { WorkspaceFileBrowserRow(entry: $0, depth: 1) }
    }

    private func fileRow(_ row: WorkspaceFileBrowserRow, changes: [String: FileChange], forceLeaf: Bool = false) -> some View {
        let entry = row.entry
        let change = changes[entry.path]
        return Button {
            if entry.isDirectory {
                browser.toggleDirectory(entry)
            } else if let change {
                model.selectChange(change)
            } else if !entry.isDirectory {
                model.selectWorkspaceFile(path: entry.path)
            }
        } label: {
            HStack(spacing: 7) {
                if entry.isDirectory && !forceLeaf {
                    Image(systemName: browser.isExpanded(entry.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 9)
                } else { Color.clear.frame(width: 9, height: 1) }
                Image(systemName: entry.isDirectory ? "folder" : fileIcon(entry.name, isLink: entry.isSymbolicLink))
                    .foregroundStyle(entry.isDirectory ? palette.accent : palette.secondaryText).frame(width: 16)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 1)
                if browser.isLoading(entry.path) { ProgressView().controlSize(.mini) }
                if let change { changeBadge(change) }
            }
            .font(.system(size: 12))
            .padding(.leading, 9 + CGFloat(min(row.depth, 5)) * 13).padding(.trailing, 9)
            .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
            .contentShape(Rectangle())
            .background(entry.path == model.selectedPath ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(entry.path)
        .accessibilityLabel(entry.path)
        .contextMenu {
            if entry.isDirectory, let change {
                Button("查看变更", systemImage: "rectangle.and.text.magnifyingglass") { model.selectChange(change) }
                if change.kind == .untracked { Button("添加忽略规则…", systemImage: "eye.slash") { model.showIgnoreRule(path: change.path) } }
            }
            if !entry.isDirectory {
                Button("查看文件历史", systemImage: "clock.arrow.circlepath") { model.showFileHistory(path: entry.path) }
                fileTools(path: entry.path, change: change)
            }
        }
    }

    @ViewBuilder private func fileTools(path: String, change: FileChange?) -> some View {
        if change?.kind != .untracked {
            Button("逐行追溯…", systemImage: "text.line.first.and.arrowtriangle.forward") { model.showBlame(path: path) }
        }
        if change?.kind == .conflicted {
            Button("编辑并解决冲突…", systemImage: "arrow.triangle.merge") { model.showConflictEditor(path: path) }
        } else if change?.kind == .modified && model.selectedBinding?.providerID == .git {
            Button("按块／按行提交…", systemImage: "checklist") { model.showPartialCommit(path: path) }
        }
        if change?.kind == .untracked {
            Button("添加忽略规则…", systemImage: "eye.slash") { model.showIgnoreRule(path: path) }
        }
    }

    @ViewBuilder private func directoryIssue(for row: WorkspaceFileBrowserRow) -> some View {
        if row.entry.isDirectory, let message = browser.issue(in: row.entry.path) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(palette.removed)
                Text(message).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("重试") { browser.retryDirectory(row.entry.path) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .disabled(browser.isLoading(row.entry.path))
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.secondaryText)
            .padding(.leading, 28 + CGFloat(min(row.depth, 5)) * 13)
            .padding(.trailing, 9).padding(.vertical, 4)
            .help(message)
        }
    }

    @ViewBuilder private var changeTree: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            Image(systemName: "folder.fill").foregroundStyle(palette.accent)
            Text(model.selectedBinding?.root.lastPathComponent ?? model.workspace?.name ?? "工作区").fontWeight(.medium)
        }.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 30)
        ForEach(cachedChangeRows) { row in
            Button {
                if row.isDirectory {
                    if model.treeState.workingCollapsed.contains(row.id) { model.treeState.workingCollapsed.remove(row.id) }
                    else { model.treeState.workingCollapsed.insert(row.id) }
                } else if let change = row.change { model.selectChange(change) }
            } label: {
                HStack(spacing: 7) {
                    if row.isDirectory { Image(systemName: model.treeState.workingCollapsed.contains(row.id) ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).frame(width: 9) }
                    else { Color.clear.frame(width: 9, height: 1) }
                    Image(systemName: row.isDirectory ? "folder" : fileIcon(row.title, isLink: false)).foregroundStyle(row.isDirectory ? palette.accent : palette.secondaryText).frame(width: 16)
                    Text(row.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 1)
                    if let change = row.change { changeBadge(change) }
                }
                .font(.system(size: 12)).padding(.leading, 9 + CGFloat(min(row.depth, 5)) * 13).padding(.trailing, 9)
                .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading).contentShape(Rectangle())
                .background(row.change.map { $0.path == model.selectedPath } == true ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).help(row.id).accessibilityLabel(row.change?.path ?? row.id)
            .contextMenu {
                if row.isDirectory, let change = row.change {
                    Button("查看变更", systemImage: "rectangle.and.text.magnifyingglass") { model.selectChange(change) }
                if change.kind == .untracked { Button("添加忽略规则…", systemImage: "eye.slash") { model.showIgnoreRule(path: change.path) } }
                } else if let change = row.change {
                    Button("查看文件历史", systemImage: "clock.arrow.circlepath") { model.showFileHistory(path: change.path) }
                    fileTools(path: change.path, change: change)
                }
            }
        }
        if changes.isEmpty && !model.isLoading {
            Text(browser.filter.isEmpty ? "工作区没有变更" : "没有匹配的文件")
                .font(.system(size: 12)).foregroundStyle(palette.secondaryText).padding(16)
        }
    }

    private func rebuildChangeRows() {
        cachedChangeRows = makeChangeRows()
    }

    private func makeChangeRows() -> [WorkspaceChangeRow] {
        var result: [WorkspaceChangeRow] = []
        func collect(_ files: [FileChange], prefix: String, depth: Int) {
            let groups = Dictionary(grouping: files) { file in String(file.path.dropFirst(prefix.count).split(separator: "/").first ?? "") }
            for name in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                guard let members = groups[name] else { continue }
                let fullPath = prefix + name
                let directoryChange = members.first(where: { $0.path == fullPath })
                let descendants = members.filter { $0.path != fullPath }
                if descendants.isEmpty, let directoryChange {
                    result.append(.init(id: fullPath, title: name, depth: depth, change: directoryChange, isDirectory: false))
                } else {
                    result.append(.init(id: fullPath, title: name, depth: depth, change: directoryChange, isDirectory: true))
                    if !model.treeState.workingCollapsed.contains(fullPath) { collect(descendants, prefix: fullPath + "/", depth: depth + 1) }
                }
            }
        }
        collect(changes, prefix: "", depth: 1)
        return result
    }

    @ViewBuilder private func changeBadge(_ change: FileChange) -> some View {
        Text(change.kind.symbol).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(change.kind == .deleted || change.kind == .conflicted ? palette.removed : palette.accent)
    }

    private func fileIcon(_ name: String, isLink: Bool) -> String {
        if isLink { return "arrowshape.turn.up.right" }
        return switch (name as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "java", "kt", "js", "ts", "py", "go", "rs": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg": "photo"
        case "yml", "yaml", "json", "xml", "toml": "doc.badge.gearshape"
        default: "doc.text"
        }
    }
}

private struct WorkspaceChangeRow: Identifiable {
    let id: String
    let title: String
    let depth: Int
    let change: FileChange?
    let isDirectory: Bool
}
