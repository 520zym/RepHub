import Observation
import SwiftUI
import DesignSystem
import RepositoryApplication
import VersionControlCore

/// 提交历史的三栏工作台。分支筛选只改变读取参考，不执行检出或切换工作副本。
struct HistoryWorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    let showAsMainView: Bool
    @State private var branchSearch = ""
    @State private var revisionSearch = ""

    var body: some View {
        let palette = appearance.palette(for: appearance.preferredColorScheme ?? systemColorScheme)
        Group {
            if supportsBranches {
                SoftHorizontalSplit(initialWidth: showAsMainView ? 220 : 190,
                    range: showAsMainView ? 210...230 : 180...200,
                    flexibleMinimum: showAsMainView ? 770 : 580) {
                    HistoryBranchSidebar(
                        snapshot: model.snapshot,
                        selectedReference: model.historyReference,
                        search: $branchSearch,
                        palette: palette,
                        isCompact: !showAsMainView,
                        treeState: model.treeState,
                        selectReference: model.selectHistoryReference
                    )
                } trailing: {
                    historyContent(palette: palette)
                }
            } else {
                historyContent(palette: palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
        .onAppear {
            if showAsMainView { model.setHistoryVisible(true) }
        }
    }

    private var supportsGraph: Bool {
        !isFileHistory && model.selectedBinding?.capabilities.contains(.commitGraph) == true
    }

    private var supportsBranches: Bool {
        !isFileHistory && model.selectedBinding?.capabilities.contains(.branches) == true
    }

    @ViewBuilder
    private func historyContent(palette: AppPalette) -> some View {
        if showAsMainView {
            GeometryReader { proxy in
                let availableHeight = max(0, proxy.size.height - 6)
                VStack(spacing: 6) {
                    SoftHorizontalSplit(fixedSide: .trailing, initialWidth: 286, range: 270...310, flexibleMinimum: 500) {
                        revisionTable(palette: palette)
                    } trailing: {
                        HistoryRevisionInspector(model: model, palette: palette, isCompact: false)
                    }
                    .frame(height: availableHeight * 0.56)
                    DiffView(model: model, appearance: appearance)
                        .frame(height: availableHeight * 0.44)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .background(palette.background)
            }
        } else {
            SoftHorizontalSplit(fixedSide: .trailing, initialWidth: 270, range: 260...300, flexibleMinimum: 320) {
                revisionTable(palette: palette)
            } trailing: {
                HistoryRevisionInspector(model: model, palette: palette, isCompact: true)
            }
        }
    }

    private var bindingSelection: Binding<String?> {
        Binding(
            get: { model.selectedBindingID },
            set: { identifier in
                guard let identifier,
                      let binding = model.workspace?.bindings.first(where: { $0.id == identifier }) else { return }
                model.selectBinding(binding)
            }
        )
    }

    private var filteredRevisions: [Revision] {
        let query = revisionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let revisions = model.historyRevisions
        guard !query.isEmpty else { return revisions }
        return revisions.filter {
            $0.subject.lowercased().contains(query)
                || $0.author.lowercased().contains(query)
                || $0.id.lowercased().contains(query)
                || $0.references.joined(separator: " ").lowercased().contains(query)
        }
    }

    private func revisionTable(palette: AppPalette) -> some View {
        HistoryRevisionTable(
            revisions: filteredRevisions,
            supportsGraph: supportsGraph,
            supportsBranches: supportsBranches,
            fileHistoryPath: model.historyFilePath,
            fileHistoryReference: model.historyFileReference,
            usesGitIdentifiers: model.selectedBinding?.providerID == .git,
            syncStatus: model.historySyncStatus,
            issues: (model.workspace?.issues ?? []) + model.historyIssues,
            bindings: model.workspace?.bindings ?? [],
            selectedBindingID: bindingSelection,
            selectedRevisionID: Binding(
                get: { model.selectedRevisionID },
                set: { id in model.selectRevision(filteredRevisions.first(where: { $0.id == id })) }
            ),
            search: $revisionSearch,
            selectedReference: model.historyReference,
            references: model.snapshot?.branches ?? [],
            selectReference: model.selectHistoryReference,
            chooseFileHistory: model.chooseFileHistory,
            clearFileHistory: model.clearFileHistory,
            drawsGraphConnections: !isFileHistory && revisionSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            palette: palette
        )
    }

    private var isFileHistory: Bool { model.historyFilePath != nil }
}

private struct HistoryBranchSidebar: View {
    let snapshot: BindingSnapshot?
    let selectedReference: String?
    @Binding var search: String
    let palette: AppPalette
    let isCompact: Bool
    @Bindable var treeState: WorkspaceTreeState
    let selectReference: (String?) -> Void
    @State private var localTree: [PathTreeNode<BranchReference>] = []
    @State private var remoteTree: [PathTreeNode<BranchReference>] = []
    @State private var tagTree: [PathTreeNode<BranchReference>] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("分支").font(.system(size: 13, weight: .semibold))
                Spacer()
                TreeExpansionControls(directoryIDs: directoryIDs, collapsed: $treeState.branchCollapsed, palette: palette)
            }
            .padding(.horizontal, 14).frame(height: 39)
            WorkbenchSearchField("搜索分支或标签…", text: $search, palette: palette)
                .padding(.horizontal, 10).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    referenceButton(title: "所有分支", icon: "point.3.connected.trianglepath.dotted", reference: nil)
                    referenceSection("本地", roots: localTree, icon: "arrow.triangle.branch")
                    referenceSection("远端", roots: remoteTree, icon: "network")
                    referenceSection("标签", roots: tagTree, icon: "tag")
                }
                .padding(10)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: isCompact ? 180 : 210, idealWidth: isCompact ? 190 : 220, maxWidth: isCompact ? 200 : 230, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebar)
        .accessibilityElement(children: .contain)
        .task(id: branchSignature) { rebuildTrees() }
    }

    @ViewBuilder
    private func referenceSection(_ title: String, roots: [PathTreeNode<BranchReference>], icon: String) -> some View {
        if containsMatch(roots) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
                BranchTreeRows(roots: roots, search: search, selectedReference: selectedReference, collapsed: $treeState.branchCollapsed, palette: palette, selectReference: selectReference)
            }
        }
    }

    private var directoryIDs: [String] {
        localTree.flatMap(\.directoryIDs) + remoteTree.flatMap(\.directoryIDs) + tagTree.flatMap(\.directoryIDs)
    }

    private var branchSignature: String {
        (snapshot?.branches ?? []).map { "\($0.kind.rawValue):\($0.name):\($0.revisionID)" }.joined(separator: "\u{1F}")
    }

    private func rebuildTrees() {
        let branches = snapshot?.branches ?? []
        localTree = makeTree(branches, kind: .local)
        remoteTree = makeTree(branches, kind: .remote)
        tagTree = makeTree(branches, kind: .tag)
    }

    private func makeTree(_ branches: [BranchReference], kind: BranchReference.Kind) -> [PathTreeNode<BranchReference>] {
        PathTree.make(branches.filter { $0.kind == kind }.map {
            PathTreeElement(id: $0.id, path: $0.name, payload: $0)
        }, namespace: "branch/\(kind.rawValue)")
    }

    private func containsMatch(_ roots: [PathTreeNode<BranchReference>]) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return !roots.isEmpty }
        return roots.contains { node in
            (node.payload?.name.localizedCaseInsensitiveContains(query) == true) || containsMatch(node.children)
        }
    }

    private func referenceButton(title: String, icon: String, reference: String?) -> some View {
        Button {
            selectReference(reference)
        } label: {
            Label(title, systemImage: icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(selectedReference == reference ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(reference == nil ? "显示已加载的全部提交" : "仅按该引用重新读取历史，不会切换工作副本")
    }

}

private struct BranchTreeRows: View {
    let roots: [PathTreeNode<BranchReference>]
    let search: String
    let selectedReference: String?
    @Binding var collapsed: Set<String>
    let palette: AppPalette
    let selectReference: (String?) -> Void

    var body: some View {
        ForEach(roots) { node in
            BranchTreeNodeView(
                node: node,
                depth: 0,
                search: search,
                selectedReference: selectedReference,
                collapsed: $collapsed,
                palette: palette,
                selectReference: selectReference
            )
        }
    }
}

private struct BranchTreeNodeView: View {
    let node: PathTreeNode<BranchReference>
    let depth: Int
    let search: String
    let selectedReference: String?
    @Binding var collapsed: Set<String>
    let palette: AppPalette
    let selectReference: (String?) -> Void

    var body: some View {
        if isVisible(node) {
            Button {
                if node.isDirectory {
                    toggle(node.id)
                } else if let reference = node.payload {
                    selectReference(reference.name)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: node.isDirectory ? (isExpanded(node) ? "chevron.down" : "chevron.right") : "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 11)
                    if node.isDirectory {
                        Image(systemName: "folder").foregroundStyle(palette.accent).frame(width: 14)
                    }
                    Text(node.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let reference = node.payload, reference.isCurrent {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.accent)
                    }
                }
                .font(.system(size: 12))
                .padding(.leading, 8 + CGFloat(depth) * 12).padding(.trailing, 7)
                .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                .background(isSelected(node) ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(node.payload?.name ?? node.title)
            .accessibilityLabel(node.payload?.name ?? node.id)
            if node.isDirectory, isExpanded(node) {
                ForEach(node.children) { child in
                    BranchTreeNodeView(
                        node: child,
                        depth: depth + 1,
                        search: search,
                        selectedReference: selectedReference,
                        collapsed: $collapsed,
                        palette: palette,
                        selectReference: selectReference
                    )
                }
            }
        }
    }

    private func isSelected(_ node: PathTreeNode<BranchReference>) -> Bool {
        node.payload?.name == selectedReference
    }

    private func isVisible(_ node: PathTreeNode<BranchReference>) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return node.payload?.name.localizedCaseInsensitiveContains(query) == true || node.children.contains(where: isVisible)
    }

    private func isExpanded(_ node: PathTreeNode<BranchReference>) -> Bool {
        !collapsed.contains(node.id) || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

private struct HistoryRevisionTable: View {
    let revisions: [Revision]
    let supportsGraph: Bool
    let supportsBranches: Bool
    let fileHistoryPath: String?
    let fileHistoryReference: String?
    let usesGitIdentifiers: Bool
    let syncStatus: RepositorySyncStatus?
    let issues: [String]
    let bindings: [RepositoryBinding]
    @Binding var selectedBindingID: String?
    @Binding var selectedRevisionID: String?
    @Binding var search: String
    let selectedReference: String?
    let references: [BranchReference]
    let selectReference: (String?) -> Void
    let chooseFileHistory: () -> Void
    let clearFileHistory: () -> Void
    let drawsGraphConnections: Bool
    let palette: AppPalette

    var body: some View {
        GeometryReader { proxy in
            let showDate = proxy.size.width >= 610
            let showAuthor = proxy.size.width >= 500
            let showHash = proxy.size.width >= 405
            let graphRows = supportsGraph ? GitGraphLayout.rows(for: revisions) : []
            let graphWidth = supportsGraph ? max(26, CGFloat(graphRows.map(\.laneCount).max() ?? 1) * 11 + 3) : 0
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    bindingSource
                    WorkbenchSearchField("搜索提交、作者、版本号…", text: $search, palette: palette)
                    if supportsBranches {
                        Menu {
                            Button("所有分支") { selectReference(nil) }
                            if !references.isEmpty { Divider() }
                            ForEach(references) { reference in
                                Button(reference.name) { selectReference(reference.name) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.branch")
                                Text(selectedReference ?? "所有分支").lineLimit(1).truncationMode(.middle)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selectedReference == nil ? palette.secondaryText : palette.accent)
                            .padding(.horizontal, 8).frame(height: 30)
                            .background(selectedReference == nil ? .clear : palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.visible)
                        .frame(width: 132)
                        .help("筛选历史范围，不会切换工作副本分支")
                    }
                    Button(action: chooseFileHistory) {
                        Label("文件历史", systemImage: "doc.text.magnifyingglass").labelStyle(.iconOnly)
                    }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                    .accessibilityLabel("选择文件查看历史")
                    .help("选择当前工作区中的一个文件，查看其提交历史")
                }
                .padding(.horizontal, 14).frame(height: 48).background(palette.surface)
                if let fileHistoryPath {
                    fileHistoryScope(path: fileHistoryPath, reference: fileHistoryReference)
                }
                if let syncStatus {
                    syncSummary(syncStatus)
                }
                tableHeader(graphWidth: graphWidth, showAuthor: showAuthor, showDate: showDate, showHash: showHash)
                    .background(palette.secondaryText.opacity(0.045))
                if revisions.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: issues.isEmpty ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                            .font(.title3)
                        Text(issues.isEmpty ? "暂无提交记录" : "提交历史暂时不可用")
                            .font(.callout.weight(.medium))
                        if !issues.isEmpty {
                            Text("可在右侧展开查看读取原因")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedRevisionID) {
                        ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                            HStack(spacing: 8) {
                                if supportsGraph { HistoryGraphCell(row: graphRows[index], accent: palette.accent, width: graphWidth, drawsConnections: drawsGraphConnections) }
                                HStack(spacing: 6) {
                                    Text(revision.subject).lineLimit(1).layoutPriority(2)
                                    if let state = syncStatus?.states[revision.id], state != .synchronized {
                                        RevisionSyncBadge(state: state, palette: palette)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if showAuthor { Text(revision.author).lineLimit(1).frame(width: 92, alignment: .leading) }
                                if showDate { Text(revision.date.formatted(date: .numeric, time: .shortened)).lineLimit(1).frame(width: 126, alignment: .leading) }
                                if showHash { Text(revision.shortID).font(.system(.caption, design: .monospaced)).foregroundStyle(palette.secondaryText).frame(width: 70, alignment: .leading) }
                            }
                            .font(.callout)
                            .tag(Optional(revision.id))
                            .contentShape(Rectangle())
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
    }

    private func fileHistoryScope(path: String, reference: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(palette.accent)
            Text("文件历史")
                .font(.caption.weight(.semibold))
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(palette.secondaryText)
            if let reference, !reference.isEmpty {
                Text("截至 \(shortReference(reference))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .help("文件历史截至修订 \(reference)")
            }
            Spacer(minLength: 6)
            Button("显示全部历史", action: clearFileHistory)
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                .help("关闭文件历史范围，返回仓库提交历史")
        }
        .padding(.horizontal, 14)
        .frame(height: 31)
        .background(palette.selection.opacity(0.42))
        .help(path)
    }

    private func shortReference(_ reference: String) -> String {
        // 只缩写完整提交哈希；分支名和标签保留原文，交由布局自然省略。
        reference.count >= 40 && reference.allSatisfy(\.isHexDigit)
            ? String(reference.prefix(10)) : reference
    }

    private func syncSummary(_ status: RepositorySyncStatus) -> some View {
        HStack(spacing: 7) {
            Image(systemName: syncSymbol(for: status))
                .foregroundStyle(syncColor(for: status))
            Text(status.summary)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if !status.detail.isEmpty {
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 27)
        .background(palette.sidebar.opacity(0.55))
        .help(status.detail.isEmpty ? status.summary : "\(status.summary)\n\(status.detail)")
    }

    private func syncSymbol(for status: RepositorySyncStatus) -> String {
        if status.states.values.contains(.uncertain) { return "questionmark.circle" }
        if status.states.isEmpty, status.incomingCount == nil, status.outgoingCount == nil { return "questionmark.circle" }
        if (status.incomingCount ?? 0) > 0 { return "arrow.down.circle" }
        if (status.outgoingCount ?? 0) > 0 { return "arrow.up.circle" }
        return "checkmark.circle"
    }

    private func syncColor(for status: RepositorySyncStatus) -> Color {
        (status.states.values.contains(.uncertain) || (status.states.isEmpty && status.incomingCount == nil && status.outgoingCount == nil))
            ? palette.secondaryText : palette.accent
    }

    @ViewBuilder private var bindingSource: some View {
        if bindings.count > 1 {
            WorkbenchSegmentedPicker(title: "版本控制", selection: $selectedBindingID,
                options: bindings.map { .init(Optional($0.id), $0.providerID == .svn ? "SVN" : $0.providerName) }, palette: palette)
                .frame(width: 130)
        } else if let binding = bindings.first {
            Label(binding.providerName, systemImage: binding.providerID == .git ? "arrow.triangle.branch" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
                .frame(height: 30).padding(.trailing, 4).fixedSize()
                .accessibilityLabel("版本控制来源：\(binding.providerName)")
        }
    }

    private func tableHeader(graphWidth: CGFloat, showAuthor: Bool, showDate: Bool, showHash: Bool) -> some View {
        HStack(spacing: 8) {
            if supportsGraph { Text("图").frame(width: graphWidth) }
            Text("提交说明").frame(maxWidth: .infinity, alignment: .leading)
            if showAuthor { Text("作者").frame(width: 92, alignment: .leading) }
            if showDate { Text("日期").frame(width: 126, alignment: .leading) }
            if showHash { Text(usesGitIdentifiers ? "哈希" : "修订号").frame(width: 70, alignment: .leading) }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

private struct HistoryRevisionInspector: View {
    @Bindable var model: WorkspaceModel
    let palette: AppPalette
    let isCompact: Bool
    @State private var issueDetailsExpanded = false
    @State private var messageDetailsExpanded = false
    @State private var revisionTree: [PathTreeNode<FileChange>] = []

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 7 : 12) {
            if !issues.isEmpty {
                HistoryIssueNotice(message: issues.joined(separator: "\n"), palette: palette, isExpanded: $issueDetailsExpanded)
            }
            if let revision = selectedRevision {
                Text(revision.subject).font(.headline).lineLimit(isCompact ? 2 : 3)
                referenceLabels(revision.references)
                HStack(spacing: 8) {
                    Text(revision.shortID).font(.system(.caption, design: .monospaced)).foregroundStyle(palette.accent)
                    Text(revision.author).lineLimit(1).font(.caption).foregroundStyle(palette.secondaryText)
                    if let state = model.historySyncStatus?.states[revision.id], state != .synchronized {
                        Label(state.title, systemImage: syncSymbol(for: state))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(state == .uncertain ? palette.secondaryText : palette.accent)
                            .help(syncHelp(for: state))
                    }
                }
                if !isCompact {
                    Label(revision.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.caption).foregroundStyle(palette.secondaryText)
                    if !messageBody.isEmpty {
                        DisclosureGroup(isExpanded: $messageDetailsExpanded) {
                            ScrollView {
                                Text(messageBody).font(.callout).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 88)
                        } label: {
                            Text(messageBody).font(.callout).lineLimit(2)
                        }
                        .tint(palette.accent)
                    }
                    Button { } label: { Label("审查此提交", systemImage: "sparkles") }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                        .disabled(true).help("AI 审查当前不可用")
                }
                HStack {
                    Text(model.historyFilePath == nil ? "变更的文件  \(model.revisionFiles.count)" : "历史文件")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    TreeExpansionControls(directoryIDs: revisionTree.flatMap(\.directoryIDs), collapsed: revisionCollapsed, palette: palette)
                }
                .padding(.top, 8)
                revisionFiles
            } else {
                ContentUnavailableView("选择一个提交", systemImage: "arrowshape.turn.up.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(isCompact ? 10 : 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebar.opacity(0.45))
        .background(palette.surface)
        .task(id: revisionTreeSignature) { rebuildRevisionTree() }
    }

    private var selectedRevision: Revision? {
        model.historyRevisions.first { $0.id == model.selectedRevisionID }
    }

    private var issues: [String] {
        (model.workspace?.issues ?? []) + model.historyIssues
    }

    private var messageBody: String {
        guard let revision = selectedRevision else { return "" }
        return revision.message.components(separatedBy: .newlines).dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func syncSymbol(for state: RevisionSyncState) -> String {
        switch state {
        case .incoming: "arrow.down.circle"
        case .outgoing: "arrow.up.circle"
        case .synchronized: "checkmark.circle"
        case .uncertain: "questionmark.circle"
        }
    }

    private func syncHelp(for state: RevisionSyncState) -> String {
        switch state {
        case .incoming: "此提交尚未更新到本地"
        case .outgoing: "此提交尚未推送到上游"
        case .synchronized: "此提交已同步"
        case .uncertain: "当前无法确认此提交的同步状态"
        }
    }

    @ViewBuilder
    private func referenceLabels(_ references: [String]) -> some View {
        if !references.isEmpty {
            HStack(spacing: 5) { ForEach(references, id: \.self) { Text($0).font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(palette.selection, in: Capsule()) } }
        }
    }

    private var revisionFiles: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                RevisionFileTreeRows(
                    roots: revisionTree,
                    collapsed: revisionCollapsed,
                    selectedPath: model.selectedPath,
                    isFileHistory: model.historyFilePath != nil,
                    palette: palette,
                    select: model.selectRevisionFile,
                    showHistory: showHistory
                )
            }
            .padding(.vertical, 3)
        }
        .frame(maxHeight: .infinity)
    }

    private var revisionTreeSignature: String {
        "\(model.selectedRevisionID ?? "")|\(model.historyFilePath ?? "")|" + model.revisionFiles.map { "\($0.path):\($0.kind.rawValue)" }.joined(separator: "\u{1F}")
    }

    private var revisionCollapsed: Binding<Set<String>> {
        Binding(get: { model.treeState.revisionCollapsed }, set: { model.treeState.revisionCollapsed = $0 })
    }

    private func rebuildRevisionTree() {
        revisionTree = PathTree.make(model.revisionFiles.map {
            PathTreeElement(id: $0.path, path: $0.path, payload: $0)
        }, namespace: "revision")
    }

    private func showHistory(_ change: FileChange) {
        let entry = model.historyFileEntries.first {
            $0.revision.id == model.selectedRevisionID && $0.path == change.path
        }
        model.showFileHistory(path: change.path, reference: entry?.pegRevision ?? model.selectedRevisionID)
    }

}

private struct RevisionFileTreeRows: View {
    let roots: [PathTreeNode<FileChange>]
    @Binding var collapsed: Set<String>
    let selectedPath: String?
    let isFileHistory: Bool
    let palette: AppPalette
    let select: (FileChange?) -> Void
    let showHistory: (FileChange) -> Void

    var body: some View {
        ForEach(roots) { node in
            RevisionFileTreeNodeView(
                node: node,
                depth: 0,
                collapsed: $collapsed,
                selectedPath: selectedPath,
                isFileHistory: isFileHistory,
                palette: palette,
                select: select,
                showHistory: showHistory
            )
        }
    }
}

private struct RevisionFileTreeNodeView: View {
    let node: PathTreeNode<FileChange>
    let depth: Int
    @Binding var collapsed: Set<String>
    let selectedPath: String?
    let isFileHistory: Bool
    let palette: AppPalette
    let select: (FileChange?) -> Void
    let showHistory: (FileChange) -> Void

    var body: some View {
        Button {
            if node.isDirectory { toggle(node.id) }
            else { select(node.payload) }
        } label: {
            HStack(spacing: 7) {
                if node.isDirectory {
                    Image(systemName: isExpanded(node) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 9)
                    Image(systemName: "folder").foregroundStyle(palette.accent).frame(width: 15)
                } else {
                    Color.clear.frame(width: 9, height: 1)
                    statusMark(for: node.payload).frame(width: 15)
                }
                Text(node.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.leading, 8 + CGFloat(depth) * 13).padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(isSelected(node) ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(node.payload?.path ?? node.title)
        .accessibilityLabel(node.payload?.path ?? node.id)
        .contextMenu {
            if let change = node.payload {
                Button("查看文件历史", systemImage: "clock.arrow.circlepath") { showHistory(change) }
            }
        }
        if node.isDirectory, isExpanded(node) {
            ForEach(node.children) { child in
                RevisionFileTreeNodeView(
                    node: child,
                    depth: depth + 1,
                    collapsed: $collapsed,
                    selectedPath: selectedPath,
                    isFileHistory: isFileHistory,
                    palette: palette,
                    select: select,
                    showHistory: showHistory
                )
            }
        }
    }

    @ViewBuilder
    private func statusMark(for change: FileChange?) -> some View {
        if isFileHistory {
            Image(systemName: "doc.text").font(.caption).foregroundStyle(palette.secondaryText)
        } else if let change {
            Text(change.kind.symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(changeColor(change.kind))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(changeColor(change.kind).opacity(0.14), in: Capsule())
        }
    }

    private func isSelected(_ node: PathTreeNode<FileChange>) -> Bool {
        node.payload?.path == selectedPath
    }

    private func isExpanded(_ node: PathTreeNode<FileChange>) -> Bool {
        !collapsed.contains(node.id)
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    private func changeColor(_ kind: FileChangeKind) -> Color {
        switch kind {
        case .added, .copied: palette.added
        case .deleted, .conflicted: palette.removed
        default: palette.accent
        }
    }
}

private struct HistoryIssueNotice: View {
    let message: String
    let palette: AppPalette
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .padding(.top, 3)
        } label: {
            Label(summary, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
        }
        .tint(palette.removed)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(palette.removed.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(message)
    }

    private var summary: String {
        message.split(whereSeparator: \.isNewline).first.map(String.init) ?? "仓库读取失败"
    }
}

private struct RevisionSyncBadge: View {
    let state: RevisionSyncState
    let palette: AppPalette

    var body: some View {
        Label(state.title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.11), in: Capsule())
            .help(helpText)
            .accessibilityLabel(state.title)
    }

    private var symbol: String {
        switch state {
        case .incoming: "arrow.down"
        case .outgoing: "arrow.up"
        case .synchronized: "checkmark"
        case .uncertain: "questionmark"
        }
    }

    private var color: Color {
        switch state {
        case .incoming, .outgoing: palette.accent
        case .synchronized: palette.added
        case .uncertain: palette.secondaryText
        }
    }

    private var helpText: String {
        switch state {
        case .incoming: "此提交尚未更新到本地"
        case .outgoing: "此提交尚未推送到上游"
        case .synchronized: "此提交已同步"
        case .uncertain: "当前无法确认此提交的同步状态"
        }
    }
}

private struct HistoryGraphCell: View {
    let row: GitGraphLayout.Row
    let accent: Color
    let width: CGFloat
    let drawsConnections: Bool
    var body: some View {
        Canvas { context, size in
            let laneWidth: CGFloat = 11
            let centerX = CGFloat(row.currentLane) * laneWidth + 6
            if drawsConnections { for lane in row.passThrough {
                var path = Path()
                path.move(to: CGPoint(x: CGFloat(lane.source) * laneWidth + 6, y: 0))
                path.addLine(to: CGPoint(x: CGFloat(lane.target) * laneWidth + 6, y: size.height))
                context.stroke(path, with: .color(color(for: lane.source).opacity(0.52)), lineWidth: 1.3)
            } }
            if drawsConnections && row.hasIncomingCurrent {
                var path = Path(); path.move(to: CGPoint(x: centerX, y: 0)); path.addLine(to: CGPoint(x: centerX, y: size.height / 2))
                context.stroke(path, with: .color(accent.opacity(0.6)), lineWidth: 1.3)
            }
            if drawsConnections { for lane in row.parentLanes {
                var path = Path(); path.move(to: CGPoint(x: centerX, y: size.height / 2)); path.addLine(to: CGPoint(x: CGFloat(lane) * laneWidth + 6, y: size.height))
                context.stroke(path, with: .color(color(for: lane).opacity(0.7)), lineWidth: 1.3)
            } }
            context.fill(Path(ellipseIn: CGRect(x: centerX - 3.5, y: size.height / 2 - 3.5, width: 7, height: 7)), with: .color(color(for: row.currentLane)))
        }
        .frame(width: width, height: 30)
    }

    private func color(for lane: Int) -> Color {
        switch lane % 3 { case 1: .purple; case 2: .blue; default: accent }
    }
}
