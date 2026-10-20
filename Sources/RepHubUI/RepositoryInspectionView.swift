import SwiftUI
import DesignSystem
import RepositoryApplication
import VersionControlCore

/// 只读检查面板：历史搜索按适配器游标扫描，逐行追溯固定在已提交修订。
struct RepositoryInspectionView: View {
    @State private var model: RepositoryInspectionModel
    let palette: AppPalette
    @Bindable var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    let dismiss: () -> Void
    let onSelectRevision: (Revision) -> Void

    init(
        service: RepositoryService,
        binding: RepositoryBinding,
        path: String?,
        palette: AppPalette,
        appearance: AppearanceStore,
        dismiss: @escaping () -> Void,
        onSelectRevision: @escaping (Revision) -> Void
    ) {
        _model = State(initialValue: RepositoryInspectionModel(service: service, binding: binding, path: path))
        self.palette = palette
        self.appearance = appearance
        self.dismiss = dismiss
        self.onSelectRevision = onSelectRevision
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            header
            if model.canBlame {
                WorkbenchSegmentedPicker(
                    title: "检查方式", selection: Binding(get: { model.mode }, set: { model.selectMode($0) }),
                    options: inspectionOptions, palette: palette
                )
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            Group {
                switch model.mode {
                case .blame: blameContent
                case .historySearch: searchContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .workbenchSheet(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 650)
        .background(palette.background).foregroundStyle(palette.text)
        .task { model.loadInitial() }
        .interactiveDismissDisabled(model.isLoading)
    }

    private var inspectionOptions: [WorkbenchSegment<RepositoryInspectionModel.Mode>] {
        var options: [WorkbenchSegment<RepositoryInspectionModel.Mode>] = []
        if model.canBlame { options.append(.init(.blame, "逐行追溯")) }
        options.append(.init(.historySearch, "全历史搜索"))
        return options
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: model.mode == .blame ? "text.line.first.and.arrowtriangle.forward" : "magnifyingglass")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(palette.accent)
                .frame(width: 31, height: 31)
                .background(palette.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.mode == .blame ? "逐行追溯" : "全历史搜索").font(.system(size: 15, weight: .semibold))
                Text(model.mode == .blame ? (model.path ?? "未选择文件") : "从固定历史快照分批扫描，可继续读取到最早提交")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText).lineLimit(1)
            }
            Spacer()
            if model.isLoading {
                Button("取消") { model.cancel() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
        }
        .padding(.horizontal, 22).padding(.vertical, 18).background(palette.surface)
    }

    private var blameContent: some View {
        VStack(spacing: 0) {
            if let blame = model.blame {
                HStack {
                    Text("固定于 \(blame.reference)").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondaryText)
                    Spacer()
                    Text("\(blame.lines.count) 行").font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    Button("重新读取") { model.loadBlame() }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                }
                .padding(.horizontal, 18).padding(.vertical, 9).background(palette.sidebar.opacity(0.5))
                if let error = model.errorMessage { ErrorStrip(message: error, palette: palette) }
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(blame.lines) { line in blameRow(line) }
                        }
                        .padding(.vertical, 6)
                        .frame(minWidth: geometry.size.width, alignment: .topLeading)
                    }
                    .defaultScrollAnchor(.topLeading)
                }
            } else { inspectionPlaceholder("正在读取已提交版本的逐行来源…") }
        }
    }

    private func blameRow(_ line: RepositoryBlameLine) -> some View {
        Button { onSelectRevision(line.revision) } label: {
            HStack(spacing: 0) {
                Text("\(line.lineNumber)").frame(width: 36, alignment: .trailing).padding(.trailing, 14).foregroundStyle(palette.secondaryText)
                Text(line.revision.shortID).frame(width: 76, alignment: .leading).foregroundStyle(palette.accent)
                Text(line.revision.author.isEmpty ? "—" : line.revision.author).frame(width: 104, alignment: .leading)
                Text(line.revision.date.formatted(.iso8601.year().month().day().dateSeparator(.dash)))
                    .frame(width: 96, alignment: .leading).foregroundStyle(palette.secondaryText)
                SyntaxHighlighting.text(tokens: model.blameTokens.indices.contains(line.lineNumber - 1)
                    ? model.blameTokens[line.lineNumber - 1] : [.init(value: line.content, kind: .plain)], palette: codePalette)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
            }
            .lineLimit(1)
            .font(.system(size: 12, design: .monospaced)).padding(.horizontal, 12).frame(minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(line.revision.subject)\n点击查看提交")
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            searchFields
            if let error = model.errorMessage { ErrorStrip(message: error, palette: palette).padding(.horizontal, 16).padding(.bottom, 8) }
            if model.isLoading && model.searchResults.isEmpty { inspectionPlaceholder("正在从固定历史快照中扫描…") }
            else if model.searchResults.isEmpty { inspectionPlaceholder(model.isSearchComplete ? "没有匹配的提交" : "填写条件后搜索全部历史") }
            else {
                List(model.searchResults) { revision in
                    Button { onSelectRevision(revision) } label: { searchRow(revision) }.buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            searchFooter
        }
    }

    private var searchFields: some View {
        @Bindable var model = model
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("提交说明", text: $model.queryText).textFieldStyle(.plain).inspectionField(palette)
                TextField("作者", text: $model.queryAuthor).textFieldStyle(.plain).inspectionField(palette)
                TextField("文件路径（可选）", text: $model.queryPath).textFieldStyle(.plain).inspectionField(palette)
                Button("搜索") { model.search(reset: true) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(model.isLoading)
            }
            HStack(spacing: 12) {
                Toggle("起始日期", isOn: $model.useFromDate).font(.system(size: 11))
                if model.useFromDate { DatePicker("", selection: $model.fromDate, displayedComponents: .date).labelsHidden().font(.system(size: 11)) }
                Toggle("结束日期", isOn: $model.useToDate).font(.system(size: 11))
                if model.useToDate { DatePicker("", selection: $model.toDate, displayedComponents: .date).labelsHidden().font(.system(size: 11)) }
                Spacer()
            }.foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 18).padding(.bottom, 12).padding(.top, model.canBlame ? 0 : 16)
    }

    private func searchRow(_ revision: Revision) -> some View {
        HStack(spacing: 10) {
            Text(revision.shortID).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.accent).frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(revision.subject).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(revision.author.isEmpty ? "未知作者" : revision.author).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            Text(revision.date, format: .dateTime.year().month().day().hour().minute()).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
        }.padding(.vertical, 3).contentShape(Rectangle())
    }

    private var searchFooter: some View {
        HStack {
            Text(model.isSearchComplete ? "已扫描到最早提交，共检查 \(model.scannedCount) 条" : "已检查 \(model.scannedCount) 条提交；可继续扫描更早历史")
                .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            Spacer()
            if !model.isSearchComplete {
                Button(model.isLoading ? "正在扫描…" : "继续搜索更早历史") { model.search(reset: false) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(model.isLoading)
            }
        }.padding(.horizontal, 18).padding(.vertical, 11).background(palette.surface)
    }

    private func inspectionPlaceholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            if model.isLoading { ProgressView().controlSize(.small) }
            Image(systemName: model.errorMessage == nil ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                .font(.system(size: 26)).foregroundStyle(palette.secondaryText.opacity(0.55))
            Text(model.errorMessage ?? text).font(.system(size: 12)).foregroundStyle(palette.secondaryText)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var codePalette: CodePalette { appearance.codePalette(for: appearance.preferredColorScheme ?? systemColorScheme) }
}

private extension View {
    func inspectionField(_ palette: AppPalette) -> some View {
        padding(.horizontal, 10).frame(height: 30)
            .background(palette.secondaryText.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
