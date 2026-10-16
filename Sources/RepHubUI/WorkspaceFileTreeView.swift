import SwiftUI
import Observation
import DesignSystem
import VersionControlCore

/// 工作区侧栏：默认浏览实际文件，按需展开目录；“变更”保留版本控制适配器提供的完整变更集。
struct WorkspaceFileTreeView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var browser: WorkspaceFileBrowser
    @Binding var selectedChangePaths: Set<String>
    let palette: AppPalette
    let showsBindingPicker: Bool
    @State private var cachedConflictRows: [WorkspaceChangeRow] = []
    @State private var cachedOrdinaryRows: [WorkspaceChangeRow] = []

    init(model: WorkspaceModel, palette: AppPalette, showsBindingPicker: Bool,
         selectedChangePaths: Binding<Set<String>>) {
        self.model = model
        self.browser = model.fileBrowser
        self.palette = palette
        self.showsBindingPicker = showsBindingPicker
        self._selectedChangePaths = selectedChangePaths
    }

    private var changes: [FileChange] {
        (model.snapshot?.changes ?? []).filter { browser.filter.isEmpty || $0.path.localizedCaseInsensitiveContains(browser.filter) }
    }

    private var conflictedChanges: [FileChange] { changes.filter { $0.kind == .conflicted } }
    private var ordinaryChanges: [FileChange] { changes.filter { $0.kind != .conflicted } }
    private var selectableChanges: [FileChange] { (model.snapshot?.changes ?? []).filter { $0.kind != .conflicted } }
    private var selectedChangeCount: Int {
        selectedChangePaths.intersection(Set(selectableChanges.map(\.path))).count
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
                .padding(.horizontal, 18).padding(.bottom, 10)
            if browser.mode == .files, !browser.filter.isEmpty {
                Text("仅搜索已展开并读取的目录")
                    .font(.system(size: 10)).foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 18).padding(.bottom, 7)
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
            if browser.mode == .changes {
                HStack {
                    Text("已选 \(selectedChangeCount) / \(selectableChanges.count)")
                    Spacer(minLength: 0)
                    if !conflictedChanges.isEmpty {
                        Text("\(conflictedChanges.count) 个冲突")
                            .foregroundStyle(palette.removed)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 18)
                .frame(height: 42)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface)
        .onAppear(perform: rebuildChangeRows)
        .onChange(of: changeInputKey) { _, _ in rebuildChangeRows() }
        .onChange(of: model.treeState.workingCollapsed) { _, _ in rebuildChangeRows() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("工作区")
                    .font(.system(size: 24, weight: .semibold))
                Spacer(minLength: 0)
                if browser.mode == .changes {
                    if conflictedChanges.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.accent)
                    }
                    Text("\(model.snapshot?.changes.count ?? 0) 项变更")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
            }
            HStack(spacing: 8) {
                WorkbenchSegmentedPicker(title: "文件范围", selection: $browser.mode,
                                         options: [.init(.changes, "变更"), .init(.files, "全部文件")], palette: palette)
                    .frame(maxWidth: .infinity)
                if browser.mode == .files {
                    Menu {
                        Button("展开已读取的目录", action: browser.expandLoadedDirectories)
                        Button("全部收起", action: browser.collapseAll)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .help("仅展开已读取的目录，不扫描整个工作区")
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
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
        .font(.system(size: 14, weight: .medium)).padding(.horizontal, 16).frame(height: 34)
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
        return HStack(spacing: 7) {
            if entry.isDirectory && !forceLeaf {
                Image(systemName: browser.isExpanded(entry.path) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 9)
            } else { Color.clear.frame(width: 9, height: 1) }
            Image(systemName: entry.isDirectory ? "folder" : fileIcon(entry.name, isLink: entry.isSymbolicLink))
                .foregroundStyle(entry.isDirectory ? palette.accent : palette.secondaryText).frame(width: 16)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 1)
            if browser.isLoading(entry.path) { ProgressView().controlSize(.mini) }
            if let change {
                if change.kind != .conflicted { selectionControl(for: change) }
                changeBadge(change)
            }
        }
        .font(.system(size: 14))
        .padding(.leading, 12 + CGFloat(min(row.depth, 5)) * 14).padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(Rectangle())
        .background(entry.path == model.selectedPath ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            if entry.isDirectory {
                browser.toggleDirectory(entry)
            } else if let change {
                model.selectChange(change)
            } else if !entry.isDirectory {
                model.selectWorkspaceFile(path: entry.path)
            }
        }
        .help(entry.path)
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
        }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).frame(height: 34)
        if !conflictedChanges.isEmpty {
            changeGroupHeader(title: "冲突", count: conflictedChanges.count, systemImage: "exclamationmark.triangle.fill", tint: palette.removed)
            changeRows(cachedConflictRows)
        }
        if !ordinaryChanges.isEmpty {
            changeGroupHeader(title: conflictedChanges.isEmpty ? "变更" : "其他变更", count: ordinaryChanges.count,
                              systemImage: "doc.text", tint: palette.secondaryText)
            changeRows(cachedOrdinaryRows)
        }
        if changes.isEmpty && !model.isLoading {
            Text(browser.filter.isEmpty ? "工作区没有变更" : "没有匹配的文件")
                .font(.system(size: 12)).foregroundStyle(palette.secondaryText).padding(16)
        }
    }

    private func changeGroupHeader(title: String, count: Int, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 16)
            Text(title).fontWeight(.semibold)
            Text("\(count)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint).padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(0.11), in: Capsule())
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private func changeRows(_ rows: [WorkspaceChangeRow]) -> some View {
        ForEach(rows) { row in
            HStack(spacing: 7) {
                if row.isDirectory {
                    Image(systemName: model.treeState.workingCollapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 9)
                } else { Color.clear.frame(width: 9, height: 1) }
                Image(systemName: row.isDirectory ? "folder" : fileIcon(row.title, isLink: false))
                    .foregroundStyle(row.isDirectory ? palette.accent : palette.secondaryText).frame(width: 16)
                Text(row.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 1)
                if let change = row.change {
                    if change.kind != .conflicted { selectionControl(for: change) }
                    changeBadge(change)
                }
            }
            .font(.system(size: 14)).padding(.leading, 12 + CGFloat(min(row.depth, 5)) * 14).padding(.trailing, 12)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
            .background(row.change.map { $0.path == model.selectedPath } == true ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                if row.isDirectory {
                    if model.treeState.workingCollapsed.contains(row.id) { model.treeState.workingCollapsed.remove(row.id) }
                    else { model.treeState.workingCollapsed.insert(row.id) }
                } else if let change = row.change { model.selectChange(change) }
            }
            .help(row.id).accessibilityLabel(row.change?.path ?? row.id)
            .contextMenu { changeContextMenu(for: row) }
        }
    }

    @ViewBuilder private func changeContextMenu(for row: WorkspaceChangeRow) -> some View {
        if row.isDirectory, let change = row.change {
            Button("查看变更", systemImage: "rectangle.and.text.magnifyingglass") { model.selectChange(change) }
            if change.kind == .untracked { Button("添加忽略规则…", systemImage: "eye.slash") { model.showIgnoreRule(path: change.path) } }
        } else if let change = row.change {
            Button("查看文件历史", systemImage: "clock.arrow.circlepath") { model.showFileHistory(path: change.path) }
            fileTools(path: change.path, change: change)
        }
    }

    private func rebuildChangeRows() {
        cachedConflictRows = makeChangeRows(from: conflictedChanges, prefix: "conflicts/")
        cachedOrdinaryRows = makeChangeRows(from: ordinaryChanges, prefix: "changes/")
    }

    private func makeChangeRows(from files: [FileChange], prefix rowPrefix: String) -> [WorkspaceChangeRow] {
        var result: [WorkspaceChangeRow] = []
        func collect(_ files: [FileChange], prefix: String, depth: Int) {
            let groups = Dictionary(grouping: files) { file in String(file.path.dropFirst(prefix.count).split(separator: "/").first ?? "") }
            for name in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                guard let members = groups[name] else { continue }
                let fullPath = prefix + name
                let directoryChange = members.first(where: { $0.path == fullPath })
                let descendants = members.filter { $0.path != fullPath }
                if descendants.isEmpty, let directoryChange {
                    result.append(.init(id: rowPrefix + fullPath, title: name, depth: depth, change: directoryChange, isDirectory: false))
                } else {
                    let rowID = rowPrefix + fullPath
                    result.append(.init(id: rowID, title: name, depth: depth, change: directoryChange, isDirectory: true))
                    if !model.treeState.workingCollapsed.contains(rowID) { collect(descendants, prefix: fullPath + "/", depth: depth + 1) }
                }
            }
        }
        collect(files, prefix: "", depth: 1)
        return result
    }

    @ViewBuilder private func changeBadge(_ change: FileChange) -> some View {
        Text(change.kind == .conflicted ? "C" : change.kind.symbol)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(change.kind == .deleted || change.kind == .conflicted ? palette.removed : palette.accent)
            .frame(minWidth: 11, alignment: .trailing)
    }

    private func selectionControl(for change: FileChange) -> some View {
        Button {
            if selectedChangePaths.contains(change.path) { selectedChangePaths.remove(change.path) }
            else { selectedChangePaths.insert(change.path) }
        } label: {
            Image(systemName: selectedChangePaths.contains(change.path) ? "checkmark.square.fill" : "square")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selectedChangePaths.contains(change.path) ? palette.accent : palette.secondaryText.opacity(0.7))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selectedChangePaths.contains(change.path) ? "从本次提交中移除" : "加入本次提交")
        .accessibilityLabel("\(change.path)，\(selectedChangePaths.contains(change.path) ? "已选择提交" : "未选择提交")")
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
