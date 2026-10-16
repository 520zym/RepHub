import AppKit
import Observation
import SwiftUI
import DesignSystem
import RepositoryApplication
import VersionControlCore

/// 提交历史阅读器。分支筛选只改变读取参考，不执行检出或切换工作副本。
struct HistoryWorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    let showAsMainView: Bool
    @State private var branchSearch = ""
    @State private var revisionSearch = ""
    @State private var revisionFilter = HistoryFilter()

    var body: some View {
        let palette = appearance.palette(for: appearance.preferredColorScheme ?? systemColorScheme)
        VStack(spacing: 0) {
            if let path = model.historyFilePath {
                HistoryFileHistoryScopeBar(
                    path: path,
                    reference: model.historyFileReference,
                    palette: palette,
                    clear: model.clearFileHistory
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            historyContent(palette: palette)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .onAppear {
            if showAsMainView { model.setHistoryVisible(true) }
        }
        .onChange(of: filterScopeID) { _, _ in
            // 新的仓库来源不能沿用上一个来源的作者或日期条件。
            revisionSearch = ""
            revisionFilter.clear()
        }
    }

    private var supportsGraph: Bool {
        model.inspectedRevision == nil && !isFileHistory && model.selectedBinding?.capabilities.contains(.commitGraph) == true
    }

    private var supportsBranches: Bool {
        !isFileHistory && model.selectedBinding?.capabilities.contains(.branches) == true
    }

    @ViewBuilder
    private func historyContent(palette: AppPalette) -> some View {
        // 历史页面保持三段明确的阅读节奏：提交列表、提交概览、代码差异。
        // 区域之间以暖灰留白区分，不依赖分割线。
        SoftHorizontalSplit(
            initialWidth: showAsMainView ? 404 : 350,
            minimumFixed: 280,
            flexibleMinimum: showAsMainView ? 500 : 320,
            storageKey: showAsMainView ? "history.reader.revisions.soft-v2" : "history.compact.revisions.soft-v2"
        ) {
            revisionTable(palette: palette)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.trailing, 6)
        } trailing: {
            HistoryReaderPane(
                model: model,
                appearance: appearance,
                palette: palette,
                isFileHistory: isFileHistory,
                showAsMainView: showAsMainView
            )
            .padding(.leading, 6)
        }
        .padding(12)
        .background(palette.background)
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
        revisionFilter.filtered(model.historyRevisions, search: revisionSearch)
    }

    private func revisionTable(palette: AppPalette) -> some View {
        VStack(spacing: 0) {
        if let revision = model.inspectedRevision {
            HStack {
                Text("追溯提交 · \(revision.shortID)").font(.system(size: 11))
                Spacer()
                Button("返回仓库历史", action: model.clearInspectedRevision).buttonStyle(.plain)
            }.foregroundStyle(palette.accent).padding(10).background(palette.selection.opacity(0.4))
        }
        HistoryRevisionTable(
            revisions: filteredRevisions,
            supportsGraph: supportsGraph,
            supportsBranches: supportsBranches,
            snapshot: model.snapshot,
            treeState: model.treeState,
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
            filter: $revisionFilter,
            selectedReference: model.historyReference,
            references: model.snapshot?.branches ?? [],
            branchSearch: $branchSearch,
            selectReference: model.selectHistoryReference,
            chooseFileHistory: model.chooseFileHistory,
            fullHistorySearch: model.showFullHistorySearch,
            drawsGraphConnections: !isFileHistory && revisionSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !revisionFilter.isActive,
            loadedCount: model.historyRevisions.count,
            hasMore: model.hasMoreHistory,
            isLoadingMore: model.isLoadingMoreHistory,
            isReading: model.isLoading || model.isInteractionLocked,
            loadMoreError: model.historyPageError,
            loadMore: model.loadMoreHistory,
            cancelLoadMore: model.cancelLoadingMoreHistory,
            palette: palette
        )
        }
    }

    private var isFileHistory: Bool { model.historyFilePath != nil }

    private var filterScopeID: String {
        "\(model.workspace?.id ?? "")|\(model.selectedBindingID ?? "")"
    }
}

/// 文件历史是整个历史页面的范围，而不是提交列表的一条局部提示。
private struct HistoryFileHistoryScopeBar: View {
    let path: String
    let reference: String?
    let palette: AppPalette
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: clear) {
                Label("全部历史", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
            .help("关闭文件范围，返回仓库全部提交历史")

            Image(systemName: "doc.text")
                .foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("文件历史")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                Text(path)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let reference, !reference.isEmpty {
                Text("截至 \(shortReference(reference))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .help("文件历史截至修订 \(reference)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(palette.surface)
        .help(path)
    }

    private func shortReference(_ reference: String) -> String {
        reference.count >= 40 && reference.allSatisfy(\.isHexDigit)
            ? String(reference.prefix(10)) : reference
    }
}

/// 右侧阅读区保持提交摘要、文件树和差异之间的连续关系。
/// 文件树可以临时收起，纵向分栏则让每个人按自己的阅读习惯分配摘要与代码空间。
private struct HistoryReaderPane: View {
    @Bindable var model: WorkspaceModel
    @Bindable var appearance: AppearanceStore
    let palette: AppPalette
    let isFileHistory: Bool
    let showAsMainView: Bool
    @State private var showsChangedFiles = true

    var body: some View {
        SoftVerticalSplit(
            fixedSide: .top,
            // 摘要和文件树在宽窗口内横向并列；使用新 key，避免旧布局的高度继续影响新界面。
            initialHeight: isFileHistory ? 188 : 344,
            minimumFixed: isFileHistory ? 132 : 216,
            flexibleMinimum: 220,
            storageKey: (showAsMainView ? "history.reader.summary" : "history.compact.summary")
                + (isFileHistory ? ".file.soft-v2" : ".repository.soft-v2")
        ) {
            HistoryRevisionInspector(
                model: model,
                palette: palette,
                isCompact: false,
                showsChangedFiles: $showsChangedFiles
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 6)
        } bottom: {
            DiffView(
                model: model,
                appearance: appearance,
                focusLine: model.diffFocusLine,
                focusToken: model.diffFocusToken
            )
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 6)
        }
        .id(isFileHistory)
    }
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
            if !isCompact {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        guard let name = node.payload?.name, let selectedReference else { return false }
        return name == selectedReference
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
    let snapshot: BindingSnapshot?
    @Bindable var treeState: WorkspaceTreeState
    let usesGitIdentifiers: Bool
    let syncStatus: RepositorySyncStatus?
    let issues: [String]
    let bindings: [RepositoryBinding]
    @Binding var selectedBindingID: String?
    @Binding var selectedRevisionID: String?
    @Binding var search: String
    @Binding var filter: HistoryFilter
    let selectedReference: String?
    let references: [BranchReference]
    @Binding var branchSearch: String
    let selectReference: (String?) -> Void
    let chooseFileHistory: () -> Void
    let fullHistorySearch: () -> Void
    let drawsGraphConnections: Bool
    let loadedCount: Int
    let hasMore: Bool
    let isLoadingMore: Bool
    let isReading: Bool
    let loadMoreError: String?
    let loadMore: () -> Void
    let cancelLoadMore: () -> Void
    let palette: AppPalette

    @State private var isNearHistoryEnd = false
    @State private var isFilterPopoverPresented = false
    @State private var isBranchNavigatorExpanded = false
    @State private var graphRows: [GitGraphLayout.Row] = []
    @State private var graphSource: [Revision] = []
    @State private var graphFirstLane = 0

    var body: some View {
        GeometryReader { proxy in
            // 翻页追加时保留已有行的布局，后台准备新页不会令摘要列先缩回再展开。
            let currentGraph = revisions.starts(with: graphSource) ? graphRows : []
            let viewport = HistoryGraphViewport(
                totalLanes: drawsGraphConnections ? (currentGraph.map(\.laneCount).max() ?? 1) : 1,
                availableWidth: proxy.size.width, requestedFirstLane: graphFirstLane
            )
            let compactMetadata = proxy.size.width < 360
            let rowHeight: CGFloat = compactMetadata ? 94 : 78
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("提交历史")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.35)
                        .padding(.top, 3)
                    HStack(spacing: 8) {
                        bindingSource
                        if supportsBranches {
                            Button {
                                isBranchNavigatorExpanded.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.triangle.branch")
                                    Text(selectedReference ?? "所有分支").lineLimit(1).truncationMode(.middle)
                                    Image(systemName: isBranchNavigatorExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(selectedReference == nil ? palette.secondaryText : palette.accent)
                                .padding(.horizontal, 8).frame(height: 27)
                                .background(selectedReference == nil ? .clear : palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: 154)
                            .help("展开分支和标签树；筛选历史范围不会切换工作副本分支")
                        }
                        Spacer(minLength: 0)
                        Button(action: fullHistorySearch) {
                            Label("全历史搜索", systemImage: "text.magnifyingglass").labelStyle(.iconOnly)
                        }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                        .accessibilityLabel("全历史搜索")
                        .help("搜索尚未加载的历史记录，可按作者、日期和文件路径筛选")
                        Button(action: chooseFileHistory) {
                            Label("文件历史", systemImage: "doc.text.magnifyingglass").labelStyle(.iconOnly)
                        }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                        .accessibilityLabel("选择文件查看历史")
                        .help("选择当前工作区中的一个文件，查看其提交历史")
                    }
                    HStack(spacing: 8) {
                        WorkbenchSearchField("搜索已加载的提交、作者、版本号…", text: $search, palette: palette)
                        filterControl
                    }
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
                .background(palette.surface)
                if supportsBranches, isBranchNavigatorExpanded {
                    HistoryBranchSidebar(
                        snapshot: snapshot,
                        selectedReference: selectedReference,
                        search: $branchSearch,
                        palette: palette,
                        isCompact: true,
                        treeState: treeState,
                        selectReference: { reference in
                            selectReference(reference)
                            isBranchNavigatorExpanded = false
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 228)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let syncStatus {
                    syncSummary(syncStatus)
                }
                if supportsGraph, viewport.hasOverflow {
                    graphNavigation(viewport)
                }
                if revisions.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: issues.isEmpty ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                            .font(.title3)
                        Text(hasActiveFilter ? "已加载记录中没有匹配的提交" : (issues.isEmpty ? "暂无提交记录" : "提交历史暂时不可用"))
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
                                if supportsGraph, currentGraph.indices.contains(index) {
                                    HistoryGraphCell(
                                        row: currentGraph[index],
                                        accent: palette.accent,
                                        viewport: viewport,
                                        height: rowHeight,
                                        drawsConnections: drawsGraphConnections
                                    )
                                } else if supportsGraph {
                                    Circle().fill(drawsGraphConnections ? .clear : palette.accent)
                                        .frame(width: 7, height: 7)
                                        .frame(width: viewport.width, alignment: .leading)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        Text(revision.subject)
                                            .font(.system(size: 14, weight: .semibold))
                                            .lineSpacing(3)
                                            .lineLimit(2)
                                            .help(revision.subject)
                                            .layoutPriority(2)
                                        if let state = syncStatus?.states[revision.id], state != .synchronized {
                                            RevisionSyncBadge(state: state, palette: palette)
                                        }
                                    }
                                    revisionMetadata(revision, compact: compactMetadata)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: rowHeight, alignment: .center)
                            .tag(Optional(revision.id))
                            .contentShape(Rectangle())
                            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button("复制完整\(usesGitIdentifiers ? "哈希" : "修订号")") {
                                    copyRevisionID(revision.id)
                                }
                            }
                        }
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.visibleRect.height > 0 && geometry.contentSize.height > geometry.visibleRect.height
                            && geometry.visibleRect.maxY >= geometry.contentSize.height - 64
                    } action: { _, nearEnd in
                        isNearHistoryEnd = nearEnd
                        loadMoreIfNearEnd()
                    }
                    .onChange(of: isReading) { _, reading in
                        if !reading { loadMoreIfNearEnd() }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(palette.surface)
                }
                paginationFooter
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.18), value: isBranchNavigatorExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
        .task(id: supportsGraph && drawsGraphConnections ? revisions : []) {
            guard supportsGraph, drawsGraphConnections else { graphRows = []; graphSource = []; return }
            let source = revisions
            let computation = Task.detached(priority: .userInitiated) {
                GitGraphLayout.rows(for: source, isCancelled: { Task.isCancelled })
            }
            let rows = await withTaskCancellationHandler {
                await computation.value
            } onCancel: {
                computation.cancel()
            }
            guard !Task.isCancelled else { return }
            graphRows = rows
            graphSource = source
        }
        .onChange(of: selectedReference) { _, _ in graphFirstLane = 0 }
        .onChange(of: selectedBindingID) { _, _ in graphFirstLane = 0 }
        .onChange(of: drawsGraphConnections) { _, _ in graphFirstLane = 0 }
    }

    private func graphNavigation(_ viewport: HistoryGraphViewport) -> some View {
        HStack(spacing: 7) {
            Text("分支图").font(.system(size: 11, weight: .medium))
            Button { graphFirstLane = max(0, viewport.firstLane - viewport.visibleLanes) } label: {
                Image(systemName: "chevron.left").frame(width: 20, height: 22)
            }
            .disabled(viewport.firstLane == 0)
            .accessibilityLabel("向左查看分支图")
            Text("\(viewport.firstLane + 1)–\(viewport.firstLane + viewport.visibleLanes) / \(viewport.totalLanes)")
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .help("当前可见轨道；左右切换不会改变提交记录或分支筛选。")
            Button { graphFirstLane = min(viewport.maximumFirstLane, viewport.firstLane + viewport.visibleLanes) } label: {
                Image(systemName: "chevron.right").frame(width: 20, height: 22)
            }
            .disabled(viewport.firstLane == viewport.maximumFirstLane)
            .accessibilityLabel("向右查看分支图")
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 16)
        .background(palette.background.opacity(0.52))
    }

    private func revisionMetadata(_ revision: Revision, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(revision.author).lineLimit(1).truncationMode(.tail)
                Text("·")
                if !compact {
                    Text(revision.date.formatted(date: .numeric, time: .shortened)).lineLimit(1).fixedSize()
                    Text("·")
                }
                Text(revision.shortID).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).fixedSize()
            }
            if compact {
                Text(revision.date.formatted(date: .numeric, time: .shortened)).lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.secondaryText)
        .help("\(revision.author) · \(revision.date.formatted()) · \(revision.id)")
    }

    private func loadMoreIfNearEnd() {
        guard isNearHistoryEnd, !isReading, !isLoadingMore, hasMore, loadMoreError == nil else { return }
        loadMore()
    }

    private var paginationFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let loadMoreError {
                Text("继续加载失败：\(loadMoreError)")
                    .font(.system(size: 11)).foregroundStyle(palette.removed)
                    .lineLimit(2).help(loadMoreError)
            }
            HStack(spacing: 8) {
                Text("已加载 \(loadedCount) 条 · 当前显示 \(revisions.count) 条")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .help(hasActiveFilter ? "搜索和筛选仅作用于已加载的提交；可继续加载更早的提交。" : "当前显示所有已加载的提交。")
                Spacer(minLength: 0)
                if isLoadingMore {
                    ProgressView().controlSize(.small)
                    Button("取消加载", action: cancelLoadMore)
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                } else if hasMore {
                    Button(loadMoreError == nil ? "加载更早的提交" : "重试加载", action: loadMore)
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                        .disabled(isReading)
                } else if !isReading, issues.isEmpty, loadedCount > 0 {
                    Text("已到最早记录").font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(palette.background.opacity(0.5))
    }

    private var hasActiveFilter: Bool {
        filter.isActive || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filterControl: some View {
        Button {
            isFilterPopoverPresented.toggle()
        } label: {
            Label("筛选提交", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: filter.isActive ? .secondary : .quiet))
        .accessibilityLabel(filter.isActive ? "提交筛选，已启用" : "筛选已加载的提交")
        .help(filter.isActive ? "作者或日期筛选已启用（仅已加载提交）" : "按作者或日期筛选已加载的提交")
        .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .top) {
            HistoryFilterPopover(filter: $filter, palette: palette)
        }
    }

    private func copyRevisionID(_ revisionID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(revisionID, forType: .string)
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
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(palette.background.opacity(0.54))
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
            RepositorySourcePicker(bindings: bindings, selectedID: selectedBindingID, select: { selectedBindingID = $0.id }, palette: palette)
                .frame(width: 160)
        } else if let binding = bindings.first {
            Label(binding.providerName, systemImage: binding.providerID == .git ? "arrow.triangle.branch" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
                .frame(height: 30).padding(.trailing, 4).fixedSize()
                .accessibilityLabel("版本控制来源：\(binding.providerName)")
        }
    }

}

private struct HistoryFilterPopover: View {
    @Binding var filter: HistoryFilter
    let palette: AppPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("筛选已加载的提交")
                .font(.headline)
            Text("筛选不会限制继续读取更早的提交。")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            VStack(alignment: .leading, spacing: 6) {
                Text("作者").font(.caption.weight(.medium)).foregroundStyle(palette.secondaryText)
                TextField("作者姓名", text: $filter.author)
                    .textFieldStyle(.roundedBorder)
            }
            dateControl(title: "起始日期", date: $filter.startDate)
            dateControl(title: "结束日期", date: $filter.endDate)
            if filter.hasInvalidDateRange {
                Label("结束日期早于起始日期，当前不会匹配提交。", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            HStack {
                if let range = filter.dateRangeDescription {
                    Text(range).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("清除") { filter.clear() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .disabled(!filter.isActive)
            }
        }
        .padding(14)
        .frame(width: 286)
        .background(palette.surface)
    }

    private func dateControl(title: String, date: Binding<Date?>) -> some View {
        let enabled = Binding(
            get: { date.wrappedValue != nil },
            set: { isEnabled in date.wrappedValue = isEnabled ? (date.wrappedValue ?? Date()) : nil }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: enabled)
                .font(.callout)
            if enabled.wrappedValue {
                DatePicker(title, selection: Binding(
                    get: { date.wrappedValue ?? Date() },
                    set: { date.wrappedValue = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
            }
        }
    }
}

private struct HistoryRevisionInspector: View {
    @Bindable var model: WorkspaceModel
    let palette: AppPalette
    let isCompact: Bool
    @Binding var showsChangedFiles: Bool
    @State private var issueDetailsExpanded = false
    @State private var messageDetailsExpanded = false
    @State private var summaryContentHeight: CGFloat = 140
    @State private var revisionTree: [PathTreeNode<FileChange>] = []

    var body: some View {
        GeometryReader { geometry in
            let contentHeight = max(1, geometry.size.height - (isCompact ? 20 : 28))
            // 宽窗口让说明与文件树同层，提交内容和文件范围一眼可见；
            // 窄窗口则恢复上下阅读，避免把文件名和说明压成窄列。
            let usesSideBySideLayout = !isCompact && model.historyFilePath == nil && geometry.size.width >= 760
            inspectorContent(
                summaryMaximumHeight: contentHeight * (usesSideBySideLayout || model.historyFilePath != nil ? 1 : 0.65),
                usesSideBySideLayout: usesSideBySideLayout
            )
        }
        .background(palette.background)
        .task(id: revisionTreeSignature) { rebuildRevisionTree() }
        .onChange(of: "\(model.selectedBindingID ?? "")|\(model.selectedRevisionID ?? "")") { _, _ in
            messageDetailsExpanded = false
        }
    }

    @ViewBuilder
    private func inspectorContent(summaryMaximumHeight: CGFloat, usesSideBySideLayout: Bool) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 7 : 10) {
            if !issues.isEmpty {
                HistoryIssueNotice(message: issues.joined(separator: "\n"), palette: palette, isExpanded: $issueDetailsExpanded)
            }
            if let revision = selectedRevision {
                if usesSideBySideLayout {
                    HStack(alignment: .top, spacing: 12) {
                        summarySection(revision, maximumHeight: summaryMaximumHeight, fillsAvailableHeight: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        changedFilesSection
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    summarySection(revision, maximumHeight: summaryMaximumHeight)
                    if model.historyFilePath == nil {
                        changedFilesSection
                    }
                }
            } else {
                ContentUnavailableView("选择一个提交", systemImage: "arrowshape.turn.up.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        // 外层只提供暖灰底；白色卡片自身处理内边距，避免顶部比左栏低一层。
        .padding(.horizontal, isCompact ? 10 : 0)
        .padding(.vertical, isCompact ? 10 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func summarySection(_ revision: Revision, maximumHeight: CGFloat, fillsAvailableHeight: Bool = false) -> some View {
        // 说明区单独滚动，底部操作始终可见，长说明不会挤掉文件树或操作按钮。
        // 给窄窗的两行操作留出完整高度，避免操作按钮被长说明或窄卡片裁掉。
        let footerHeight: CGFloat = 68
        let totalHeight = fillsAvailableHeight
            ? maximumHeight
            : min(summaryContentHeight + footerHeight, maximumHeight)
        let readableHeight = max(1, totalHeight - footerHeight)
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                revisionSummary(revision).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    revisionSummary(revision).fixedSize(horizontal: false, vertical: true)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(height: readableHeight, alignment: .topLeading)
            summaryFooter(revision)
                .frame(minHeight: footerHeight)
        }
        .frame(height: totalHeight, alignment: .topLeading)
        .layoutPriority(1)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: isCompact ? 10 : 14, style: .continuous))
    }

    @ViewBuilder
    private func revisionSummary(_ revision: Revision) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 9) {
            Text(revision.subject)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(isCompact ? 2 : 3)
                .layoutPriority(1)
            referenceLabels(revision.references)
            revisionMetadata(revision)
            if !messageBody.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("提交说明")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                    Text(messageBody)
                        .font(.system(size: 14))
                        .lineSpacing(5.5)
                        .lineLimit(messageDetailsExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 8)
            }
        }
        .padding(isCompact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { summaryContentHeight = $0 }
    }

    @ViewBuilder
    private func summaryFooter(_ revision: Revision) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                messageVisibilityAction
                copyMessageAction(revision)
                Spacer(minLength: 4)
                revisionActions(revision)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    messageVisibilityAction
                    copyMessageAction(revision)
                }
                revisionActions(revision)
            }
        }
        .padding(.horizontal, isCompact ? 10 : 14)
        .padding(.bottom, isCompact ? 8 : 10)
    }

    @ViewBuilder
    private var messageVisibilityAction: some View {
        if !messageBody.isEmpty {
            Button {
                messageDetailsExpanded.toggle()
            } label: {
                Label(messageDetailsExpanded ? "收起" : "展开全文",
                      systemImage: messageDetailsExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
            .accessibilityLabel(messageDetailsExpanded ? "收起提交说明" : "展开完整提交说明")
        }
    }

    private func copyMessageAction(_ revision: Revision) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(revision.message, forType: .string)
        } label: {
            Label("复制说明", systemImage: "doc.on.doc")
        }
        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
        .accessibilityLabel("复制完整提交说明")
        .help("复制完整提交说明")
    }

    @ViewBuilder
    private var changedFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("变更的文件")
                        .font(.system(size: 14, weight: .semibold))
                    Text("共 \(model.revisionFiles.count) 项")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Button {
                    showsChangedFiles.toggle()
                } label: {
                    Label(showsChangedFiles ? "收起文件" : "展开文件", systemImage: showsChangedFiles ? "chevron.up" : "chevron.down")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                .accessibilityLabel(showsChangedFiles ? "收起变更文件" : "展开变更文件")
                .help(showsChangedFiles ? "收起变更文件树，为代码差异留出更多空间" : "展开变更文件树")
                if showsChangedFiles {
                    TreeExpansionControls(directoryIDs: revisionTree.flatMap(\.directoryIDs), collapsed: revisionCollapsed, palette: palette)
                }
            }
            if showsChangedFiles {
                revisionFiles
            } else {
                Text("已收起 \(model.revisionFiles.count) 个变更文件")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(isCompact ? 9 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: isCompact ? 10 : 14, style: .continuous))
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

    @ViewBuilder
    private func revisionActions(_ revision: Revision) -> some View {
        HStack(spacing: 6) {
            Button { model.showAIReview(revision: revision.id) } label: {
                Label("AI 审查", systemImage: "sparkles")
            }
            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
            .disabled(model.aiReview == nil || model.isInteractionLocked)
            .help("选择文件并审查此提交的差异")
            if model.selectedBinding?.capabilities.contains(.revisionComparison) == true {
                Button { model.prepareComparison(revision: revision) } label: {
                    Label("比较版本", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                .disabled(model.isInteractionLocked)
                .help("打开版本比较并选择两个固定修订")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func revisionMetadata(_ revision: Revision) -> some View {
        let hash = Text(revision.shortID)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(palette.accent)
        let author = Text(revision.author).lineLimit(1)
        let date = Text(revision.date.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
        let state = model.historySyncStatus?.states[revision.id]

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                hash
                Text("·")
                author
                Text("·")
                date
                syncStateLabel(state)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    hash
                    Text("·")
                    author
                    syncStateLabel(state)
                }
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                    date
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.secondaryText)
        .contextMenu {
            Button("复制完整修订号") { copyRevisionID(revision.id) }
        }
    }

    @ViewBuilder
    private func syncStateLabel(_ state: RevisionSyncState?) -> some View {
        if let state, state != .synchronized {
            Label(state.title, systemImage: syncSymbol(for: state))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(state == .uncertain ? palette.secondaryText : palette.accent)
                .help(syncHelp(for: state))
        }
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

    private func copyRevisionID(_ revisionID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(revisionID, forType: .string)
    }

    @ViewBuilder
    private func referenceLabels(_ references: [String]) -> some View {
        if !references.isEmpty {
            RevisionReferenceLabels(references: references, visibleLimit: isCompact ? 1 : 2,
                                    maximumExpandedHeight: isCompact ? 84 : 180, palette: palette)
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
                    // 状态胶囊本身带有水平留白；15pt 会把单字母状态压到标题下面。
                    // 给它稳定的占位，深层目录和窄检查器中也不会与文件名重叠。
                    statusMark(for: node.payload).frame(width: 20, alignment: .center)
                }
                Text(node.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if node.isDirectory, node.payload != nil {
                    statusMark(for: node.payload).frame(width: 20, alignment: .center)
                }
            }
            .font(.system(size: 14))
            .padding(.leading, 8 + CGFloat(depth) * 13).padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(isSelected(node) ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(node.payload?.path ?? node.title)
        .accessibilityLabel(node.payload?.path ?? node.id)
        .contextMenu {
            if node.isDirectory, let change = node.payload {
                Button("查看变更", systemImage: "doc.text.magnifyingglass") { select(change) }
                Divider()
            }
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
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func isSelected(_ node: PathTreeNode<FileChange>) -> Bool {
        guard let path = node.payload?.path, let selectedPath else { return false }
        return path == selectedPath
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
    let viewport: HistoryGraphViewport
    let height: CGFloat
    let drawsConnections: Bool
    var body: some View {
        Canvas { context, size in
            let centerX = drawsConnections ? viewport.x(for: row.currentLane) : HistoryGraphViewport.inset
            if drawsConnections { for lane in row.passThrough {
                var path = Path()
                path.move(to: CGPoint(x: viewport.x(for: lane.source), y: 0))
                path.addLine(to: CGPoint(x: viewport.x(for: lane.target), y: size.height))
                context.stroke(path, with: .color(color(for: lane.source).opacity(0.52)), lineWidth: 1.3)
            } }
            if drawsConnections && row.hasIncomingCurrent {
                var path = Path(); path.move(to: CGPoint(x: centerX, y: 0)); path.addLine(to: CGPoint(x: centerX, y: size.height / 2))
                context.stroke(path, with: .color(accent.opacity(0.6)), lineWidth: 1.3)
            }
            if drawsConnections { for lane in row.parentLanes {
                var path = Path(); path.move(to: CGPoint(x: centerX, y: size.height / 2)); path.addLine(to: CGPoint(x: viewport.x(for: lane), y: size.height))
                context.stroke(path, with: .color(color(for: lane).opacity(0.7)), lineWidth: 1.3)
            } }
            context.fill(Path(ellipseIn: CGRect(x: centerX - 3.5, y: size.height / 2 - 3.5, width: 7, height: 7)), with: .color(color(for: row.currentLane)))
            if drawsConnections, !viewport.contains(row.currentLane) {
                // 当前节点在视口之外时，明确标出方向；不把不同轨道压成一条假连接。
                let isLeft = row.currentLane < viewport.firstLane
                let x: CGFloat = isLeft ? 4 : size.width - 4
                let y = size.height / 2
                var arrow = Path()
                arrow.move(to: CGPoint(x: x + (isLeft ? 3 : -3), y: y - 4))
                arrow.addLine(to: CGPoint(x: x, y: y))
                arrow.addLine(to: CGPoint(x: x + (isLeft ? 3 : -3), y: y + 4))
                context.stroke(arrow, with: .color(color(for: row.currentLane)), lineWidth: 1.6)
            }
        }
        .frame(width: viewport.width, height: height)
        .clipped()
        .help(drawsConnections && !viewport.contains(row.currentLane)
              ? "提交节点位于第 \(row.currentLane + 1) 条轨道，可用列表上方的左右按钮查看。"
              : "提交分支图")
    }

    private func color(for lane: Int) -> Color {
        switch lane % 3 { case 1: .purple; case 2: .blue; default: accent }
    }
}
