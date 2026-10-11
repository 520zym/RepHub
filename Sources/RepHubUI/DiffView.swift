import SwiftUI
import AppKit
import Observation
import DesignSystem
import VersionControlCore

public struct DiffView: View {
    @Bindable private var model: WorkspaceModel
    @Bindable private var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var presentation: DiffPresentation = .sideBySide

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
            Divider().overlay(appPalette.border)
            content(appPalette: appPalette, codePalette: codePalette)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(appPalette.surface)
    }

    @ViewBuilder
    private func content(appPalette: AppPalette, codePalette: CodePalette) -> some View {
        if let patch = model.patch, !patch.text.isEmpty {
            if hasUnifiedHunk(patch.text) {
                SideBySideDiff(rows: SideBySideDiffParser.parse(patch.text), presentation: presentation, palette: codePalette, border: appPalette.border)
            } else if isBinary(patch.text) {
                binaryState(patch.text, palette: appPalette)
            } else {
                unsupportedState(patch.text, palette: appPalette)
            }
        } else if model.isLoading {
            ProgressView("正在读取差异…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if model.patch?.isTruncated == true { Label("内容已截断", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            Picker("差异布局", selection: $presentation) {
                Label("并排", systemImage: "rectangle.split.2x1").tag(DiffPresentation.sideBySide)
                Label("统一", systemImage: "text.alignleft").tag(DiffPresentation.unified)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 138)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var comparisonLabel: String {
        let provider = model.selectedBinding?.providerName ?? "版本控制"
        if let revision = model.selectedRevisionID { return "\(provider) · \(String(revision.prefix(8))) 与父版本比较" }
        let base = provider.localizedCaseInsensitiveContains("svn") || provider.localizedCaseInsensitiveContains("subversion") ? "BASE" : "HEAD"
        return "\(provider) · \(base) → 工作区"
    }

    private func isBinary(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("binary files") || text.localizedCaseInsensitiveContains("二进制文件")
    }

    private func hasUnifiedHunk(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.hasPrefix("@@ ") }
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
    let rows: [DiffRow]
    let presentation: DiffPresentation
    let palette: CodePalette
    let border: Color

    var body: some View {
        Group {
            if presentation == .sideBySide { sideBySideBody }
            else { unifiedBody }
        }.background(palette.background)
    }

    private var sideBySideBody: some View {
        GeometryReader { geometry in
            let columnWidth = max(1, (geometry.size.width - 1) / 2)
            let rowHeight = CGFloat(columnRows.count) * 24
            let contentHeight = max(1, max(rowHeight, geometry.size.height - 28))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    columnTitle("旧版本", width: columnWidth)
                    Divider().overlay(border)
                    columnTitle("新版本", width: columnWidth)
                }
                .frame(height: 28)
                ScrollView(.vertical) {
                    HStack(spacing: 0) {
                        diffColumn(.old, width: columnWidth, height: contentHeight)
                        Divider().overlay(border)
                        diffColumn(.new, width: columnWidth, height: contentHeight)
                    }
                }
            }
        }
    }

    private var unifiedBody: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
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
            .frame(height: 28).background(palette.background)
    }

    private var columnRows: [DiffRow] {
        rows.filter { if case let .metadata(_, isHunk) = $0 { return isHunk }; return true }
    }

    private func diffColumn(_ side: DiffColumn, width: CGFloat, height: CGFloat) -> some View {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let longestLine = columnRows.map { row -> CGFloat in
            let text: String
            switch row {
            case let .paired(old, new): text = (side == .old ? old : new)?.text ?? ""
            case let .metadata(value, _): text = value
            }
            return (text as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let contentWidth = max(width, ceil(longestLine) + 80)
        return ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(columnRows.enumerated()), id: \.offset) { _, row in
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

    @ViewBuilder private func unifiedRow(old: DiffSideLine?, new: DiffSideLine?) -> some View {
        if old?.kind == .context, let old { codeCell(old, showMarker: true).frame(maxWidth: .infinity, alignment: .leading) }
        else {
            if let old { codeCell(old, showMarker: true).frame(maxWidth: .infinity, alignment: .leading) }
            if let new { codeCell(new, showMarker: true).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private func codeCell(_ line: DiffSideLine?, showMarker: Bool = false) -> some View {
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

    private func marker(for line: DiffSideLine?, alwaysShow: Bool) -> String {
        guard let line else { return "" }
        return switch line.kind { case .added: "+"; case .removed: "-"; case .context: alwaysShow ? " " : "" }
    }
    private func background(for kind: DiffSideKind) -> Color { switch kind { case .added: palette.addedBackground; case .removed: palette.removedBackground; case .context: palette.background } }
    private func foreground(for kind: DiffSideKind) -> Color { switch kind { case .added: palette.addedForeground; case .removed: palette.removedForeground; case .context: palette.foreground } }
}

private enum DiffColumn: Equatable { case old, new }
