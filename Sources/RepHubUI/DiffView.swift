import SwiftUI
import Observation
import DesignSystem
import RepositoryApplication
import VersionControlCore

public struct DiffView: View {
    @Bindable private var model: WorkspaceModel
    @Bindable private var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var presentation: DiffPresentation = .sideBySide
    @State private var preparedDiff: PreparedDiff?
    @State private var preparedSource: String?
    @State private var isPreparingDiff = false

    public init(model: WorkspaceModel, appearance: AppearanceStore) {
        self.model = model
        self.appearance = appearance
    }

    public var body: some View {
        let effectiveScheme = appearance.preferredColorScheme ?? systemColorScheme
        let appPalette = appearance.palette(for: effectiveScheme)
        let codePalette = appearance.codePalette(for: effectiveScheme)
        VStack(spacing: 0) {
            diffHeader(appPalette: appPalette)
                .background(appPalette.sidebar.opacity(0.45))
            content(appPalette: appPalette, codePalette: codePalette)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(appPalette.surface)
        .task(id: model.patch?.text ?? "") {
            await prepareCurrentPatch()
        }
    }

    @ViewBuilder
    private func content(appPalette: AppPalette, codePalette: CodePalette) -> some View {
        if let preview = model.filePreview {
            filePreviewContent(preview, palette: codePalette)
        } else if let patch = model.patch, !patch.text.isEmpty {
            if preparedSource == patch.text, let preparedDiff {
                switch preparedDiff.content {
                case let .unified(diff):
                    SideBySideDiff(diff: diff, presentation: presentation, palette: codePalette)
                case let .binary(text):
                    binaryState(text, palette: appPalette)
                case let .unsupported(text):
                    unsupportedState(text, palette: appPalette)
                }
            } else if isPreparingDiff {
                ProgressView("正在准备差异…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("正在读取差异…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if model.isLoading {
            ProgressView("正在读取差异…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isHistoryVisible {
            ContentUnavailableView("选择一个提交", systemImage: "clock", description: Text("选择历史提交及文件后显示差异。"))
        } else if model.snapshot?.changes.isEmpty == true {
            ContentUnavailableView("工作区没有变更", systemImage: "checkmark.circle", description: Text("当前版本控制来源没有检测到本地变更。"))
        } else {
            ContentUnavailableView("选择一个变更", systemImage: "doc.text.magnifyingglass", description: Text("选择工作区文件或历史提交后显示差异。"))
        }
    }

    private func diffHeader(appPalette: AppPalette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(appPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedPath ?? "所有变更").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 360, alignment: .leading)
                Text(comparisonLabel).font(.system(size: 11)).foregroundStyle(appPalette.secondaryText)
            }
            Spacer(minLength: 8)
            if model.filePreview?.isTruncated == true || model.patch?.isTruncated == true {
                Label("内容已截断", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if model.filePreview == nil {
                WorkbenchSegmentedPicker(title: "差异布局", selection: $presentation,
                    options: [.init(.sideBySide, "并排"), .init(.unified, "统一")], palette: appPalette, compact: true)
                    .frame(width: 112)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var comparisonLabel: String {
        if model.filePreview != nil { return "工作区文件 · 只读" }
        let provider = model.selectedBinding?.providerName ?? "版本控制"
        if let revision = model.selectedRevisionID { return "\(provider) · \(String(revision.prefix(8))) 与父版本比较" }
        if model.isHistoryVisible { return "\(provider) · 提交历史" }
        let base = provider.localizedCaseInsensitiveContains("svn") || provider.localizedCaseInsensitiveContains("subversion") ? "BASE" : "HEAD"
        return "\(provider) · \(base) → 工作区"
    }

    @MainActor
    private func prepareCurrentPatch() async {
        guard let patch = model.patch, !patch.text.isEmpty else {
            preparedDiff = nil
            preparedSource = nil
            isPreparingDiff = false
            return
        }
        let source = patch.text
        preparedDiff = nil
        preparedSource = nil
        isPreparingDiff = true
        do {
            let prepared = try await PreparedDiffCache.shared.prepare(source)
            guard !Task.isCancelled, model.patch?.text == source else { return }
            preparedDiff = prepared
            preparedSource = source
            isPreparingDiff = false
        } catch is CancellationError {
            // 新 patch 的 .task 会接管状态，旧任务不覆盖它。
        } catch {
            guard !Task.isCancelled, model.patch?.text == source else { return }
            preparedDiff = PreparedDiff(content: .unsupported("差异准备失败：\(error.localizedDescription)"), estimatedStorageBytes: 1)
            preparedSource = source
            isPreparingDiff = false
        }
    }

    @ViewBuilder
    private func filePreviewContent(_ preview: WorkspaceFilePreview, palette: CodePalette) -> some View {
        if let text = preview.text {
            VStack(spacing: 0) {
                if let message = preview.message, !message.isEmpty {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(palette.secondary.opacity(0.06))
                }
                LocalFilePreviewView(text: text, palette: palette)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(palette.background)
        } else {
            ContentUnavailableView(
                "无法预览工作区文件",
                systemImage: "doc.badge.gearshape",
                description: Text(preview.message ?? "该文件无法按文本显示。")
            )
            .foregroundStyle(palette.secondary)
            .background(palette.background)
        }
    }

    private func binaryState(_ text: String, palette: AppPalette) -> some View {
        ContentUnavailableView("二进制文件差异", systemImage: "doc.badge.gearshape", description: Text("此文件无法按文本逐行比较。\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"))
            .foregroundStyle(palette.secondaryText)
    }

    private func unsupportedState(_ text: String, palette: AppPalette) -> some View {
        ContentUnavailableView("暂时无法显示差异", systemImage: "exclamationmark.bubble", description: Text(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            .foregroundStyle(palette.secondaryText)
    }
}

private enum DiffPresentation: Hashable { case sideBySide, unified }

private struct SideBySideDiff: View {
    let diff: PreparedUnifiedDiff
    let presentation: DiffPresentation
    let palette: CodePalette

    var body: some View {
        Group {
            if presentation == .sideBySide { sideBySideBody }
            else { unifiedBody }
        }.background(palette.background)
    }

    private var sideBySideBody: some View {
        GeometryReader { geometry in
            let columnWidth = max(1, (geometry.size.width - 6) / 2)
            let rowHeight = CGFloat(diff.columnRows.count) * 24
            let contentHeight = max(1, max(rowHeight, geometry.size.height - 28))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    columnTitle("旧版本", width: columnWidth)
                    columnGutter
                    columnTitle("新版本", width: columnWidth)
                }
                .frame(height: 28)
                ScrollView(.vertical) {
                    HStack(spacing: 0) {
                        diffColumn(.old, width: columnWidth, height: contentHeight)
                        columnGutter
                        diffColumn(.new, width: columnWidth, height: contentHeight)
                    }
                }
            }
        }
    }

    private var columnGutter: some View {
        palette.secondary.opacity(0.055).frame(width: 6)
    }

    private var unifiedBody: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.rows.indices, id: \.self) { index in
                    let row = diff.rows[index]
                    switch row {
                    case let .metadata(text, isHunk): metadataRow(text, isHunk: isHunk)
                    case let .paired(old, new): unifiedRow(old: old, new: new)
                    }
                }
            }.frame(minWidth: 620, alignment: .leading)
        }.defaultScrollAnchor(.topLeading)
    }

    private func columnTitle(_ title: String, width: CGFloat) -> some View {
        Text(title).padding(.leading, 68).frame(width: width, alignment: .leading)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
            .frame(height: 28).background(palette.secondary.opacity(0.035))
    }

    private func diffColumn(_ side: DiffColumn, width: CGFloat, height: CGFloat) -> some View {
        let preparedWidth = side == .old ? diff.oldColumnWidth : diff.newColumnWidth
        let contentWidth = max(width, preparedWidth)
        return ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.columnRows.indices, id: \.self) { index in
                    let row = diff.columnRows[index]
                    switch row {
                    case let .metadata(text, isHunk):
                        if isHunk { metadataRow(text, isHunk: true).frame(width: contentWidth, alignment: .leading) }
                    case let .paired(old, new):
                        codeCell(side == .old ? old : new).frame(width: contentWidth, alignment: .leading)
                    }
                }
            }.frame(width: contentWidth, height: height, alignment: .topLeading)
        }.frame(width: width, height: height)
    }

    private func metadataRow(_ text: String, isHunk: Bool) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(isHunk ? palette.type : palette.secondary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
            .background(isHunk ? palette.selection.opacity(0.46) : palette.background)
    }

    @ViewBuilder private func unifiedRow(old: PreparedDiffLine?, new: PreparedDiffLine?) -> some View {
        if old?.kind == .context, let old { codeCell(old, showMarker: true).frame(maxWidth: .infinity, alignment: .leading) }
        else {
            if let old { codeCell(old, showMarker: true).frame(maxWidth: .infinity, alignment: .leading) }
            if let new { codeCell(new, showMarker: true).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private func codeCell(_ line: PreparedDiffLine?, showMarker: Bool = false) -> some View {
        let kind = line?.kind ?? .context
        return HStack(spacing: 0) {
            Text(line?.number.map(String.init) ?? "").foregroundStyle(palette.lineNumber).frame(width: 45, alignment: .trailing).padding(.trailing, 8)
            Text(marker(for: line, alwaysShow: showMarker)).foregroundStyle(foreground(for: kind)).frame(width: 15)
            SyntaxHighlighting.text(line?.text ?? "", palette: palette).fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
            Spacer(minLength: 12)
        }
        .font(.system(size: 13, design: .monospaced)).frame(height: 24)
        .background(background(for: kind))
    }

    private func marker(for line: PreparedDiffLine?, alwaysShow: Bool) -> String {
        guard let line else { return "" }
        return switch line.kind { case .added: "+"; case .removed: "-"; case .context: alwaysShow ? " " : "" }
    }
    private func background(for kind: PreparedDiffSideKind) -> Color { switch kind { case .added: palette.addedBackground; case .removed: palette.removedBackground; case .context: palette.background } }
    private func foreground(for kind: PreparedDiffSideKind) -> Color { switch kind { case .added: palette.addedForeground; case .removed: palette.removedForeground; case .context: palette.foreground } }
}

private enum DiffColumn: Equatable { case old, new }
