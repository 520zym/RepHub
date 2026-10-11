import SwiftUI
import Observation
import DesignSystem
import RepositoryApplication
import VersionControlCore

struct DiffView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let effectiveColorScheme = appearance.preferredColorScheme ?? systemColorScheme
        let palette = appearance.palette(for: effectiveColorScheme)
        let code = appearance.codePalette(for: effectiveColorScheme)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(diffTitle).font(.headline)
                    Text(diffSubtitle).font(.caption).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                if model.patch?.isTruncated == true { Label("内容已截断", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(palette.surface)
            Divider()
            Group {
                if let patch = model.patch, !patch.text.isEmpty {
                    PatchTextView(text: patch.text, palette: code)
                } else if model.isLoading {
                    ProgressView("正在读取差异…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("选择一个变更", systemImage: "doc.text.magnifyingglass", description: Text("在左侧选取文件后显示真实差异。"))
                }
            }
        }
        .background(palette.surface)
    }

    private var diffTitle: String { model.selectedPath ?? model.selectedRevisionID ?? "差异" }
    private var diffSubtitle: String {
        if let binding = model.selectedBinding { return "\(binding.providerName) · \(binding.root.path)" }
        return ""
    }
}

struct PatchTextView: View {
    let text: String
    let palette: CodePalette
    private var lines: [PatchDisplayLine] { PatchLineParser.parse(text) }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        Text(line.oldLine.map(String.init) ?? "").foregroundStyle(palette.lineNumber).frame(width: 42, alignment: .trailing)
                        Text(line.newLine.map(String.init) ?? "").foregroundStyle(palette.lineNumber).frame(width: 42, alignment: .trailing).padding(.trailing, 12)
                        Text(line.text).foregroundStyle(foreground(for: line.text[...])).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 1)
                    .padding(.trailing, 20)
                    .background(background(for: line.text[...]))
                }
            }
            .padding(.vertical, 10)
        }
        .background(palette.background)
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return palette.addedBackground }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return palette.removedBackground }
        return palette.background
    }

    private func foreground(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return palette.addedForeground }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return palette.removedForeground }
        if line.hasPrefix("@@") || line.hasPrefix("diff ") { return palette.type }
        return palette.foreground
    }
}

struct HistoryWorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    let showAsMainView: Bool

    var body: some View {
        let palette = appearance.palette(for: appearance.preferredColorScheme ?? systemColorScheme)
        HSplitView {
            historyList(palette: palette).frame(minWidth: showAsMainView ? 430 : 360, idealWidth: 520)
            if showAsMainView {
                VSplitView {
                    revisionDetail(palette: palette).frame(minHeight: 210, idealHeight: 280)
                    DiffView(model: model, appearance: appearance).frame(minHeight: 260)
                }
                .frame(minWidth: 420)
            } else {
                revisionDetail(palette: palette).frame(minWidth: 330)
            }
        }
        .background(palette.surface)
    }

    @ViewBuilder
    private func historyList(palette: AppPalette) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(historyHeading).font(.headline)
                Spacer()
                if supportsGraph { Label("Git Graph", systemImage: "point.3.connected.trianglepath.dotted").font(.caption).foregroundStyle(palette.secondaryText) }
            }.padding(12)
            Divider()
            if let snapshot = model.snapshot {
                List(selection: Binding(get: { model.selectedRevisionID }, set: { id in
                    model.selectRevision(snapshot.revisions.first(where: { $0.id == id }))
                })) {
                    let graphRows = GitGraphLayout.rows(for: snapshot.revisions)
                    ForEach(Array(snapshot.revisions.enumerated()), id: \.element.id) { index, revision in
                        HStack(spacing: 8) {
                            if supportsGraph { GitGraphLane(row: graphRows[index], accent: palette.accent) }
                            RevisionRow(revision: revision, palette: palette).tag(Optional(revision.id))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectRevision(revision) }
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView("暂无历史", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    @ViewBuilder
    private func revisionDetail(palette: AppPalette) -> some View {
        if let revision = model.snapshot?.revisions.first(where: { $0.id == model.selectedRevisionID }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(revision.subject).font(.headline)
                Text("\(revision.shortID) · \(revision.author)").font(.caption).foregroundStyle(palette.secondaryText)
                if !revision.references.isEmpty {
                    FlowLabels(labels: revision.references, accent: palette.accent)
                }
                if let error = model.errorMessage {
                    ErrorStrip(message: error, palette: palette)
                }
                if let issues = model.snapshot?.issues, !issues.isEmpty {
                    IssueList(issues: issues, palette: palette)
                }
                Divider()
                if model.isLoading {
                    ProgressView("正在读取修订内容…")
                } else if model.revisionFiles.isEmpty {
                    Text("该修订没有可显示的文件变更，或尚未完成读取。")
                        .font(.callout).foregroundStyle(palette.secondaryText)
                } else {
                    Text("变更文件 · \(model.revisionFiles.count)").font(.subheadline.weight(.semibold))
                    List(selection: Binding(
                        get: { model.selectedPath },
                        set: { path in model.selectRevisionFile(model.revisionFiles.first(where: { $0.path == path })) }
                    )) {
                        ForEach(model.revisionFiles) { change in
                            HStack { Text(change.kind.symbol).foregroundStyle(palette.accent); Text(change.path).font(.system(.caption, design: .monospaced)); Spacer() }
                                .tag(Optional(change.path))
                        }
                    }
                    .listStyle(.plain)
                }
                Spacer()
            }.padding(16)
        } else if !supportsGraph, model.selectedBinding != nil {
            ContentUnavailableView("Subversion 修订历史", systemImage: "list.number", description: Text("按真实修订号显示；Subversion 不提供 Git 提交图。"))
        } else {
            ContentUnavailableView("选择一个提交", systemImage: "arrowshape.turn.up.right")
        }
    }

    private var supportsGraph: Bool { model.selectedBinding?.capabilities.contains(.commitGraph) == true }
    private var historyHeading: String { supportsGraph ? "提交历史" : "修订历史" }
}

private struct RevisionRow: View {
    let revision: Revision
    let palette: AppPalette
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(revision.subject).lineLimit(1); Spacer(); Text(revision.shortID).font(.caption.monospaced()).foregroundStyle(palette.accent) }
            Text("\(revision.author) · \(revision.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(palette.secondaryText)
            if !revision.references.isEmpty { Text(revision.references.joined(separator: " · ")).font(.caption2).foregroundStyle(palette.secondaryText).lineLimit(1) }
        }
        .padding(.vertical, 3)
    }
}

/// 节点及连线仅由 Revision.parents 推导；没有提交图能力时该组件不会出现。
private struct GitGraphLane: View {
    let row: GitGraphLayout.Row
    let accent: Color
    var body: some View {
        Canvas { context, size in
            let laneWidth: CGFloat = 12
            let currentX = CGFloat(row.currentLane) * laneWidth + 7
            for lane in row.passThrough {
                let sourceX = CGFloat(lane.source) * laneWidth + 7
                let targetX = CGFloat(lane.target) * laneWidth + 7
                var path = Path(); path.move(to: CGPoint(x: sourceX, y: 0)); path.addLine(to: CGPoint(x: targetX, y: size.height))
                context.stroke(path, with: .color(accent.opacity(0.52)), lineWidth: 1.4)
            }
            if row.hasIncomingCurrent {
                var path = Path(); path.move(to: CGPoint(x: currentX, y: 0)); path.addLine(to: CGPoint(x: currentX, y: size.height / 2))
                context.stroke(path, with: .color(accent.opacity(0.52)), lineWidth: 1.4)
            }
            for lane in row.parentLanes {
                let x = CGFloat(lane) * laneWidth + 7
                var path = Path(); path.move(to: CGPoint(x: currentX, y: size.height / 2)); path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(accent.opacity(0.72)), lineWidth: 1.4)
            }
            context.fill(Path(ellipseIn: CGRect(x: currentX - 4, y: size.height / 2 - 4, width: 8, height: 8)), with: .color(accent))
        }
        .frame(width: max(20, CGFloat(row.laneCount) * 12 + 2), height: 40)
        .accessibilityLabel("提交图节点，父提交 \(row.parentCount) 个")
    }
}

private struct FlowLabels: View {
    let labels: [String]
    let accent: Color
    var body: some View {
        HStack(spacing: 6) { ForEach(labels, id: \.self) { Text($0).font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(accent.opacity(0.14), in: Capsule()).foregroundStyle(accent) } }
    }
}

private struct IssueList: View {
    let issues: [String]
    let palette: AppPalette
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(issues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(palette.secondaryText)
            }
        }
    }
}

struct CommitDrawer: View {
    let workspace: Workspace?
    let palette: AppPalette
    let dismiss: () -> Void
    @State private var targets: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("提交准备").font(.headline); Spacer(); Button("关闭", action: dismiss) }
            Text("提交、推送和 AI 操作当前不可用，不会执行写入。")
                .font(.caption).foregroundStyle(palette.secondaryText)
            HStack {
                ForEach(workspace?.bindings ?? []) { binding in
                    Toggle(binding.providerName, isOn: Binding(get: { targets.contains(binding.id) }, set: { selected in if selected { targets.insert(binding.id) } else { targets.remove(binding.id) } }))
                }
                Spacer()
                Button("提交", action: {}).buttonStyle(.borderedProminent).disabled(true)
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border.opacity(0.8)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }
}

struct ErrorStrip: View {
    let message: String
    let palette: AppPalette
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(palette.text).padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.removed.opacity(0.16))
    }
}
