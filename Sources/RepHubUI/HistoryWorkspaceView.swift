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
        HSplitView {
            HistoryBranchSidebar(
                snapshot: model.snapshot,
                selectedReference: model.historyReference,
                search: $branchSearch,
                palette: palette,
                isCompact: !showAsMainView,
                selectReference: model.selectHistoryReference
            )
            if showAsMainView {
                GeometryReader { proxy in
                    let availableHeight = max(0, proxy.size.height - 1)
                    VStack(spacing: 0) {
                        HSplitView {
                            revisionTable(palette: palette)
                                .frame(minWidth: 500, idealWidth: 700)
                            HistoryRevisionInspector(model: model, palette: palette, isCompact: false)
                                .frame(minWidth: 270, idealWidth: 286, maxWidth: 310)
                        }
                        .frame(height: availableHeight * 0.56)
                        Divider()
                        DiffView(model: model, appearance: appearance)
                            .frame(height: availableHeight * 0.44)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            } else {
                revisionTable(palette: palette)
                    .frame(minWidth: 320, idealWidth: 540, maxHeight: .infinity)
                HistoryRevisionInspector(model: model, palette: palette, isCompact: true)
                    .frame(minWidth: 260, idealWidth: 270, maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
        .onChange(of: model.snapshot?.revisions.first?.id) { _, firstID in
            guard showAsMainView, model.selectedRevisionID == nil,
                  let firstID,
                  let revision = model.snapshot?.revisions.first(where: { $0.id == firstID }) else { return }
            model.selectRevision(revision)
        }
    }

    private var supportsGraph: Bool {
        model.selectedBinding?.capabilities.contains(.commitGraph) == true
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
        guard !query.isEmpty else { return model.snapshot?.revisions ?? [] }
        return (model.snapshot?.revisions ?? []).filter {
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
            bindings: model.workspace?.bindings ?? [],
            selectedBindingID: bindingSelection,
            selectedRevisionID: Binding(
                get: { model.selectedRevisionID },
                set: { id in model.selectRevision(filteredRevisions.first(where: { $0.id == id })) }
            ),
            search: $revisionSearch,
            selectedReference: model.historyReference,
            clearReference: { model.selectHistoryReference(nil) },
            drawsGraphConnections: revisionSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            palette: palette
        )
    }
}

private struct HistoryBranchSidebar: View {
    let snapshot: BindingSnapshot?
    let selectedReference: String?
    @Binding var search: String
    let palette: AppPalette
    let isCompact: Bool
    let selectReference: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("分支").font(.headline)
                Spacer()
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            TextField("搜索分支或标签…", text: $search)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    referenceButton(title: "所有分支", icon: "point.3.connected.trianglepath.dotted", reference: nil)
                    referenceSection("本地", kind: .local, icon: "arrow.triangle.branch")
                    referenceSection("远端", kind: .remote, icon: "network")
                    referenceSection("标签", kind: .tag, icon: "tag")
                }
                .padding(10)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: isCompact ? 180 : 210, idealWidth: isCompact ? 190 : 220, maxWidth: isCompact ? 200 : 230, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebar)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func referenceSection(_ title: String, kind: BranchReference.Kind, icon: String) -> some View {
        let references = filteredReferences.filter { $0.kind == kind }
        if !references.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
                ForEach(references) { reference in
                    referenceButton(title: reference.name, icon: symbol(for: reference), reference: reference.name)
                }
            }
        }
    }

    private var filteredReferences: [BranchReference] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (snapshot?.branches ?? []).filter { query.isEmpty || $0.name.lowercased().contains(query) }
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

    private func symbol(for reference: BranchReference) -> String {
        switch reference.kind { case .local: "arrow.triangle.branch"; case .remote: "network"; case .tag: "tag" }
    }
}

private struct HistoryRevisionTable: View {
    let revisions: [Revision]
    let supportsGraph: Bool
    let bindings: [RepositoryBinding]
    @Binding var selectedBindingID: String?
    @Binding var selectedRevisionID: String?
    @Binding var search: String
    let selectedReference: String?
    let clearReference: () -> Void
    let drawsGraphConnections: Bool
    let palette: AppPalette

    var body: some View {
        GeometryReader { proxy in
            let showDate = proxy.size.width >= 610
            let showAuthor = proxy.size.width >= 500
            let showHash = proxy.size.width >= 405
            let graphRows = supportsGraph ? GitGraphLayout.rows(for: revisions) : []
            let graphWidth = max(26, CGFloat(graphRows.map(\.laneCount).max() ?? 1) * 11 + 3)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    bindingSource
                    TextField("搜索提交、作者、版本号…", text: $search).textFieldStyle(.roundedBorder)
                    Button(action: clearReference) {
                        Label(selectedReference ?? "所有分支", systemImage: "arrow.triangle.branch")
                    }
                    .buttonStyle(.bordered)
                    .help(selectedReference == nil ? "当前显示已加载的全部提交" : "清除分支筛选并显示全部提交")
                }
                .padding(12).background(palette.surface)
                Divider()
                tableHeader(graphWidth: graphWidth, showAuthor: showAuthor, showDate: showDate, showHash: showHash)
                Divider()
                if revisions.isEmpty {
                    ContentUnavailableView("暂无提交记录", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedRevisionID) {
                        ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                            HStack(spacing: 8) {
                                if supportsGraph { HistoryGraphCell(row: graphRows[index], accent: palette.accent, width: graphWidth, drawsConnections: drawsGraphConnections) }
                                else { Color.clear.frame(width: graphWidth) }
                                Text(revision.subject).lineLimit(1).layoutPriority(2).frame(maxWidth: .infinity, alignment: .leading)
                                if showAuthor { Text(revision.author).lineLimit(1).frame(width: 92, alignment: .leading) }
                                if showDate { Text(revision.date.formatted(date: .numeric, time: .shortened)).lineLimit(1).frame(width: 126, alignment: .leading) }
                                if showHash { Text(revision.shortID).font(.system(.caption, design: .monospaced)).foregroundStyle(palette.secondaryText).frame(width: 70, alignment: .leading) }
                            }
                            .font(.callout)
                            .tag(Optional(revision.id))
                            .contentShape(Rectangle())
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
    }

    private var bindingSource: some View {
        Picker("版本控制", selection: $selectedBindingID) {
            ForEach(bindings) { binding in
                Label(binding.providerName, systemImage: binding.providerID == .git ? "arrow.triangle.branch" : "point.3.connected.trianglepath.dotted")
                    .tag(Optional(binding.id))
            }
        }
        .labelsHidden().pickerStyle(.segmented)
        .frame(width: bindings.count > 1 ? 150 : 94)
        .disabled(bindings.count < 2)
    }

    private func tableHeader(graphWidth: CGFloat, showAuthor: Bool, showDate: Bool, showHash: Bool) -> some View {
        HStack(spacing: 8) {
            Text("图").frame(width: graphWidth)
            Text("提交说明").frame(maxWidth: .infinity, alignment: .leading)
            if showAuthor { Text("作者").frame(width: 92, alignment: .leading) }
            if showDate { Text("日期").frame(width: 126, alignment: .leading) }
            if showHash { Text("哈希").frame(width: 70, alignment: .leading) }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

private struct HistoryRevisionInspector: View {
    @Bindable var model: WorkspaceModel
    let palette: AppPalette
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 7 : 12) {
            if let revision = selectedRevision {
                Text(revision.subject).font(.headline).lineLimit(isCompact ? 2 : nil).fixedSize(horizontal: false, vertical: !isCompact)
                referenceLabels(revision.references)
                HStack(spacing: 8) {
                    Text(revision.shortID).font(.system(.caption, design: .monospaced)).foregroundStyle(palette.accent)
                    Text(revision.author).lineLimit(1).font(.caption).foregroundStyle(palette.secondaryText)
                }
                if !isCompact {
                    Label(revision.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.caption).foregroundStyle(palette.secondaryText)
                    if !messageBody.isEmpty { Text(messageBody).font(.callout).textSelection(.enabled) }
                    Button { } label: { Label("审查此提交", systemImage: "sparkles") }
                        .disabled(true).help("AI 审查当前不可用")
                }
                Divider()
                Text("变更的文件  \(model.revisionFiles.count)").font(.subheadline.weight(.semibold))
                revisionFiles
            } else {
                ContentUnavailableView("选择一个提交", systemImage: "arrowshape.turn.up.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(isCompact ? 10 : 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface)
    }

    private var selectedRevision: Revision? {
        model.snapshot?.revisions.first { $0.id == model.selectedRevisionID }
    }

    private var messageBody: String {
        guard let revision = selectedRevision else { return "" }
        return revision.message.components(separatedBy: .newlines).dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func referenceLabels(_ references: [String]) -> some View {
        if !references.isEmpty {
            HStack(spacing: 5) { ForEach(references, id: \.self) { Text($0).font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(palette.selection, in: Capsule()) } }
        }
    }

    private var revisionFiles: some View {
        List(selection: Binding(get: { model.selectedPath }, set: { path in
            model.selectRevisionFile(model.revisionFiles.first(where: { $0.path == path }))
        })) {
            ForEach(model.revisionFiles) { change in
                HStack(spacing: 7) {
                    Text(change.kind.symbol).font(.caption2.weight(.bold)).foregroundStyle(changeColor(change.kind))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(changeColor(change.kind).opacity(0.14), in: Capsule())
                        .frame(width: 20)
                    Text(change.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .tag(Optional(change.path)).help(change.path)
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: .infinity)
    }

    private func changeColor(_ kind: FileChangeKind) -> Color {
        switch kind { case .added, .copied: palette.added; case .deleted: palette.removed; default: palette.accent }
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
