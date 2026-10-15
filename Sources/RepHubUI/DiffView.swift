import SwiftUI
import Observation
import DesignSystem
import RepositoryApplication
import VersionControlCore

public struct DiffView: View {
    @Bindable private var model: WorkspaceModel
    @Bindable private var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var presentation: DiffPresentation = .unified
    @State private var preparedDiff: PreparedDiff?
    @State private var preparedSource: String?
    @State private var preparedPath: String?
    @State private var isPreparingDiff = false
    @State private var ignoresWhitespace = false
    private let focusLine: Int?
    private let focusToken: UUID?

    public init(model: WorkspaceModel, appearance: AppearanceStore, focusLine: Int? = nil, focusToken: UUID? = nil) {
        self.model = model
        self.appearance = appearance
        self.focusLine = focusLine
        self.focusToken = focusToken
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
        .onChange(of: model.historyFilePath != nil, initial: true) { _, isFileHistory in
            presentation = isFileHistory ? .sideBySide : .unified
        }
        .task(id: HighlightedPatchIdentity(text: model.patch?.text ?? "", path: model.selectedPath)) {
            await prepareCurrentPatch()
        }
    }

    @ViewBuilder
    private func content(appPalette: AppPalette, codePalette: CodePalette) -> some View {
        if let preview = model.filePreview {
            filePreviewContent(preview, palette: codePalette)
        } else if let patch = model.patch, !patch.text.isEmpty {
            if preparedSource == patch.text, preparedPath == model.selectedPath, let preparedDiff {
                switch preparedDiff.content {
                case let .unified(diff):
                    SideBySideDiff(diff: diff, presentation: presentation, palette: codePalette,
                                   ignoresWhitespace: ignoresWhitespace, focusLine: focusLine, focusToken: focusToken)
                        .id(preparedSource ?? "")
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
            ProgressView(isDocumentSelection ? "正在读取文档…" : "正在读取差异…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isHistoryVisible {
            ContentUnavailableView("选择一个提交", systemImage: "clock", description: Text("选择历史提交及文件后显示差异。"))
        } else if model.snapshot?.changes.isEmpty == true {
            ContentUnavailableView("工作区没有变更", systemImage: "checkmark.circle", description: Text("当前版本控制来源没有检测到本地变更。"))
        } else {
            ContentUnavailableView("选择一个文件", systemImage: "doc.text.magnifyingglass", description: Text("在左侧查看当前工作区文件及未提交变更。"))
        }
    }

    private func diffHeader(appPalette: AppPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(appPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedPath.map { ($0 as NSString).lastPathComponent } ?? "文件差异")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let path = model.selectedPath {
                    Text((path as NSString).deletingLastPathComponent)
                        .font(.system(size: 11)).foregroundStyle(appPalette.secondaryText).lineLimit(1).truncationMode(.middle)
                }
            }
            .help(model.selectedPath ?? "选择文件查看差异")
            Spacer(minLength: 8)
            if let path = model.selectedPath, model.selectedBinding?.capabilities.contains(.fileHistory) == true {
                Button { model.showFileHistory(path: path, reference: model.selectedRevisionID) } label: {
                    Label("文件历史", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(WorkbenchButtonStyle(palette: appPalette, role: .quiet, compact: true))
                .disabled(model.isInteractionLocked || model.isUntrackedFilePreview)
                .help("切换到提交历史，查看此文件的版本")
            }
            if !isDocumentSelection {
                Menu {
                    Toggle("忽略空白", isOn: $ignoresWhitespace)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("差异显示选项")
            }
        }
        HStack(spacing: 8) {
            Text(comparisonLabel).font(.system(size: 11)).foregroundStyle(appPalette.secondaryText)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if model.isUntrackedFilePreview {
                Label("未跟踪", systemImage: "questionmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appPalette.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(appPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                    .help("尚未加入版本控制；当前显示本地文件内容，不会自动添加或提交。")
            }
            if (!isDocumentSelection && model.filePreview?.isTruncated == true) || model.patch?.isTruncated == true {
                Label("内容已截断", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if model.filePreview == nil && !isDocumentSelection {
                WorkbenchSegmentedPicker(title: "差异布局", selection: $presentation,
                    options: [.init(.sideBySide, "并排"), .init(.unified, "统一")], palette: appPalette, compact: true)
                    .frame(width: 112)
            }
        }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var comparisonLabel: String {
        if model.isUntrackedFilePreview { return "尚未加入版本控制 · 本地内容 · 只读" }
        if let revision = model.filePreview?.revisionID {
            return "\(model.selectedBinding?.providerName ?? "版本控制") · 节点 \(String(revision.prefix(8))) · 只读"
        }
        if model.filePreview != nil { return "工作区文件 · 只读" }
        let provider = model.selectedBinding?.providerName ?? "版本控制"
        if let revision = model.selectedRevisionID { return "\(provider) · \(String(revision.prefix(8))) 与父版本比较" }
        if model.isHistoryVisible { return "\(provider) · 提交历史" }
        let base = provider.localizedCaseInsensitiveContains("svn") || provider.localizedCaseInsensitiveContains("subversion") ? "BASE" : "HEAD"
        return "\(provider) · \(base) → 工作区"
    }

    private var isDocumentSelection: Bool {
        model.selectedPath.flatMap(WorkspaceDocumentPreviewKind.init(path:)) != nil
    }

    @MainActor
    private func prepareCurrentPatch() async {
        guard let patch = model.patch, !patch.text.isEmpty else {
            preparedDiff = nil
            preparedSource = nil
            preparedPath = nil
            isPreparingDiff = false
            return
        }
        let source = patch.text
        let path = model.selectedPath
        preparedDiff = nil
        preparedSource = nil
        isPreparingDiff = true
        do {
            let prepared = try await PreparedDiffCache.shared.prepare(source, path: path)
            guard !Task.isCancelled, model.patch?.text == source, model.selectedPath == path else { return }
            preparedDiff = prepared
            preparedSource = source
            preparedPath = path
            isPreparingDiff = false
        } catch is CancellationError {
            // 新 patch 的 .task 会接管状态，旧任务不覆盖它。
        } catch {
            guard !Task.isCancelled, model.patch?.text == source, model.selectedPath == path else { return }
            preparedDiff = PreparedDiff(content: .unsupported("差异准备失败：\(error.localizedDescription)"), estimatedStorageBytes: 1)
            preparedSource = source
            preparedPath = path
            isPreparingDiff = false
        }
    }

    @ViewBuilder
    private func filePreviewContent(_ preview: WorkspaceFilePreview, palette: CodePalette) -> some View {
        if let kind = preview.documentKind {
            VStack(spacing: 0) {
                Label("此类文档暂不支持内容差异比较。\(preview.revisionID.map { "当前查看节点 \(String($0.prefix(8))) 的文件内容。" } ?? "当前查看工作区文件内容。")", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(palette.secondary.opacity(0.06))
                if let url = preview.systemPreviewURL, let identity = preview.systemPreviewIdentity {
                    HStack(spacing: 7) {
                        Image(systemName: "eye")
                        Text(kind.localizedPreviewTitle)
                        Text("由 macOS 快速查看提供 · 只读")
                            .foregroundStyle(palette.secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(palette.secondary.opacity(0.06))

                    DocumentPreviewView(url: url, kind: kind, identity: identity, snapshot: preview.documentSnapshot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "暂时无法显示\(kind.localizedPreviewTitle)",
                        systemImage: "doc.badge.gearshape",
                        description: Text(preview.message ?? "当前 macOS 的快速查看无法打开此文件。")
                    )
                    .foregroundStyle(palette.secondary)
                }
            }
            .background(palette.background)
        } else if let text = preview.text {
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
                LocalFilePreviewView(text: text, palette: palette, language: SyntaxHighlighting.language(for: model.selectedPath))
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
    let ignoresWhitespace: Bool
    let focusLine: Int?
    let focusToken: UUID?
    @State private var page = 0

    private static let rowsPerPage = 300
    private var visibleRows: [PreparedDiffRow] {
        ignoresWhitespace ? diff.rows.filter { !$0.isWhitespaceOnlyChange } : diff.rows
    }
    private var pageCount: Int { max(1, (visibleRows.count + Self.rowsPerPage - 1) / Self.rowsPerPage) }
    private var displayedPage: Int { min(page, pageCount - 1) }
    private var displayedRows: [PreparedDiffRow] {
        let start = displayedPage * Self.rowsPerPage
        let end = min(start + Self.rowsPerPage, visibleRows.count)
        return start < end ? Array(visibleRows[start..<end]) : []
    }
    private var displayedColumnRows: [PreparedDiffRow] {
        displayedRows.filter { row in
            if case let .metadata(_, isHunk) = row { return isHunk }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if pageCount > 1 { pageNavigation }
            Group {
                if presentation == .sideBySide { sideBySideBody }
                else { unifiedBody }
            }
            .id(displayedPage)
        }
        .background(palette.background)
        .onAppear { selectPageForFocusLine() }
        .onChange(of: focusToken) { _, _ in selectPageForFocusLine() }
    }

    private var pageNavigation: some View {
        HStack(spacing: 10) {
            Text("大型差异：第 \(displayedPage + 1) / \(pageCount) 段，每段最多 \(Self.rowsPerPage) 行")
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Menu {
                Button("首段") { page = 0 }
                Divider()
                ForEach(0..<pageCount, id: \.self) { target in
                    Button("第 \(target + 1) 段") { page = target }
                }
                Divider()
                Button("末段") { page = pageCount - 1 }
            } label: {
                Label("跳转", systemImage: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("跳转到任意段")
            .help("跳转到任意段")
            Spacer()
            Button { if page > 0 { page -= 1 } } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).disabled(displayedPage == 0)
                .accessibilityLabel("前一段").help("前一段")
            Button { if displayedPage + 1 < pageCount { page += 1 } } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).disabled(displayedPage + 1 >= pageCount)
                .accessibilityLabel("后一段").help("后一段")
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .foregroundStyle(palette.foreground)
        .tint(palette.type)
        .background(palette.secondary.opacity(0.05))
    }

    private var sideBySideBody: some View {
        GeometryReader { geometry in
            let viewportColumnWidth = max(1, (geometry.size.width - 6) / 2)
            let rowHeight = CGFloat(displayedColumnRows.count) * 24
            let contentHeight = max(rowHeight, geometry.size.height - 28)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    columnTitle("旧版本", width: viewportColumnWidth)
                    columnGutter
                    columnTitle("新版本", width: viewportColumnWidth)
                }
                .frame(height: 28)
                // 每列独立横向滚动，始终各占一半视口；分页确保嵌套滚动中的节点数量有上限。
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        HStack(spacing: 0) {
                            diffColumn(.old, viewportWidth: viewportColumnWidth, contentHeight: contentHeight)
                            columnGutter
                            diffColumn(.new, viewportWidth: viewportColumnWidth, contentHeight: contentHeight)
                        }
                    }
                    .onAppear { scrollSideBySide(proxy) }
                    .onChange(of: focusToken) { _, _ in scrollSideBySide(proxy) }
                }
            }
        }
    }

    private var columnGutter: some View {
        palette.secondary.opacity(0.055).frame(width: 6)
    }

    private var unifiedBody: some View {
        let rows = displayedRows
        return GeometryReader { geometry in
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    switch row {
                    case let .metadata(text, isHunk): metadataRow(text, isHunk: isHunk)
                    case let .paired(old, new): unifiedRow(old: old, new: new).id(unifiedRowID(old: old, new: new))
                    }
                }
                }.frame(minWidth: max(geometry.size.width, 620), alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
            .onChange(of: focusToken) { _, _ in
                guard let anchor = unifiedFocusAnchor else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(anchor, anchor: .center) }
            }
        }
        }
    }

    private func columnTitle(_ title: String, width: CGFloat) -> some View {
        Text(title).padding(.leading, 68).frame(width: width, alignment: .leading)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
            .frame(height: 28).background(palette.secondary.opacity(0.035))
    }

    private func diffColumn(_ side: DiffColumn, viewportWidth: CGFloat, contentHeight: CGFloat) -> some View {
        let contentWidth = max(viewportWidth, side == .old ? diff.oldColumnWidth : diff.newColumnWidth)
        return ScrollView(.horizontal) {
            diffColumnContent(side, width: contentWidth, height: contentHeight)
        }
        .frame(width: viewportWidth, height: contentHeight)
    }

    private func diffColumnContent(_ side: DiffColumn, width: CGFloat, height: CGFloat) -> some View {
        let rows = displayedColumnRows
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                switch row {
                case let .metadata(text, isHunk):
                    if isHunk { metadataRow(text, isHunk: true).frame(width: width, alignment: .leading) }
                case let .paired(old, new):
                    let line = side == .old ? old : new
                    codeCell(line)
                        .id(line?.number.map { "\(side.rawValue)-\($0)" } ?? "\(side.rawValue)-empty-\(index)")
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
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
            inlineHighlightedText(line)
                .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
            Spacer(minLength: 12)
        }
        .font(.system(size: 13, design: .monospaced)).frame(height: 24)
        .background(focusLine == line?.number ? palette.selection.opacity(palette.isDark ? 0.46 : 0.58) : background(for: kind))
    }

    private func inlineHighlightedText(_ line: PreparedDiffLine?) -> Text {
        guard let line, !line.inlineChangeRanges.isEmpty else {
            return SyntaxHighlighting.text(tokens: line?.tokens ?? [], palette: palette)
        }
        let characters = Array(line.text)
        var result = AttributedString()
        var offset = 0
        for token in line.tokens {
            let tokenCharacters = Array(token.value)
            var tokenOffset = 0
            while tokenOffset < tokenCharacters.count {
                let marked = line.inlineChangeRanges.contains { $0.contains(offset + tokenOffset) }
                var end = tokenOffset + 1
                while end < tokenCharacters.count,
                      line.inlineChangeRanges.contains(where: { $0.contains(offset + end) }) == marked {
                    end += 1
                }
                var fragment = AttributedString(String(tokenCharacters[tokenOffset..<end]))
                fragment.foregroundColor = SyntaxHighlighting.color(for: token.kind, palette: palette)
                if marked {
                    fragment.backgroundColor = line.kind == .removed
                        ? palette.removedForeground.opacity(palette.isDark ? 0.34 : 0.22)
                        : palette.addedForeground.opacity(palette.isDark ? 0.34 : 0.22)
                }
                result += fragment
                tokenOffset = end
            }
            offset += tokenCharacters.count
        }
        // 词法 token 永远应覆盖整行；异常时以完整文本回退而非丢失字符。
        if offset != characters.count { return SyntaxHighlighting.text(tokens: line.tokens, palette: palette) }
        return Text(result)
    }

    private func selectPageForFocusLine() {
        guard let focusLine,
              let index = visibleRows.firstIndex(where: { $0.contains(line: focusLine) }) else { return }
        page = index / Self.rowsPerPage
    }
    private var unifiedFocusAnchor: String? {
        guard let focusLine else { return nil }
        return displayedRows.compactMap { row in
            guard case let .paired(old, new) = row, row.contains(line: focusLine) else { return nil }
            return unifiedRowID(old: old, new: new)
        }.first
    }
    private func unifiedRowID(old: PreparedDiffLine?, new: PreparedDiffLine?) -> String {
        "diff-row-\(new?.number ?? old?.number ?? -1)"
    }
    private func scrollSideBySide(_ proxy: ScrollViewProxy) {
        guard let focusLine else { return }
        let anchor = displayedRows.compactMap { row -> String? in
            guard case let .paired(old, new) = row else { return nil }
            if new?.number == focusLine { return "\(DiffColumn.new.rawValue)-\(focusLine)" }
            if old?.number == focusLine { return "\(DiffColumn.old.rawValue)-\(focusLine)" }
            return nil
        }.first
        guard let anchor else { return }
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(anchor, anchor: .center) }
    }

    private func marker(for line: PreparedDiffLine?, alwaysShow: Bool) -> String {
        guard let line else { return "" }
        return switch line.kind { case .added: "+"; case .removed: "-"; case .context: alwaysShow ? " " : "" }
    }
    private func background(for kind: PreparedDiffSideKind) -> Color { switch kind { case .added: palette.addedBackground; case .removed: palette.removedBackground; case .context: palette.background } }
    private func foreground(for kind: PreparedDiffSideKind) -> Color { switch kind { case .added: palette.addedForeground; case .removed: palette.removedForeground; case .context: palette.foreground } }
}

private enum DiffColumn: String, Equatable { case old, new }

private struct HighlightedPatchIdentity: Equatable {
    let text: String
    let path: String?
}

/// 管理窗口复用同一后台准备与分页渲染，避免另建逐行同步高亮路径。
struct HighlightedPatchPreview: View {
    let text: String
    let path: String?
    let palette: CodePalette
    @State private var prepared: PreparedDiff?
    @State private var preparedIdentity: HighlightedPatchIdentity?

    var body: some View {
        let identity = HighlightedPatchIdentity(text: text, path: path)
        Group {
            if preparedIdentity == identity, let prepared {
                switch prepared.content {
                case .unified(let diff):
                    SideBySideDiff(diff: diff, presentation: .unified, palette: palette,
                                   ignoresWhitespace: false, focusLine: nil, focusToken: nil)
                        .id(identity.text)
                case .binary(let message), .unsupported(let message):
                    ScrollView { Text(message).font(.caption).textSelection(.enabled).padding(12) }
                }
            } else { ProgressView("正在准备差异…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .task(id: identity) {
            do {
                let value = try await PreparedDiffCache.shared.prepare(text, path: path)
                guard !Task.isCancelled else { return }
                prepared = value; preparedIdentity = identity
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                prepared = PreparedDiff(content: .unsupported(error.localizedDescription), estimatedStorageBytes: 1)
                preparedIdentity = identity
            }
        }
    }
}
