import SwiftUI
import DesignSystem
import VersionControlCore
import RepositoryApplication

/// 统一打开入口：已有本地目录、Git 克隆和 SVN 子目录检出在同一个工作流中完成。
struct RepositoryAcquisitionView: View {
    @Bindable var model: RepositoryAcquisitionModel
    let palette: AppPalette
    let dismiss: () -> Void
    let openLocalFolder: () -> Void
    let openAcquiredFolder: (URL) -> Void
    let recentRepositories: RecentRepositoryStore
    let openRecentRepository: (RecentRepository) -> Void

    @State private var source: Source = .local

    private enum Source: Hashable { case local, remote }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            WorkbenchSegmentedPicker(
                title: "打开方式",
                selection: $source,
                options: [.init(.local, "本地文件夹"), .init(.remote, "远程仓库")],
                palette: palette
            )
            .disabled(model.isAcquiring)
            .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 14)
            if source == .local { localContent } else { remoteContent }
        }
        .frame(width: 680)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .onAppear { model.prepare() }
        .interactiveDismissDisabled(model.isBusy)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: source == .local ? "folder.badge.plus" : "arrow.down.to.line.compact")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 31, height: 31)
                .background(palette.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("打开仓库").font(.system(size: 15, weight: .semibold))
                Text(source == .local ? "识别已有 Git 或 SVN 工作副本" : "克隆 Git，或浏览并检出 SVN 目录")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if !model.isBusy {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .accessibilityLabel("关闭打开仓库窗口")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(palette.surface)
    }

    private var localContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("选择已经存在的本地文件夹。RepHub 会自动识别 Git、SVN，或两者同时存在的工作副本。")
                .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .background(palette.sidebar.opacity(0.58), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            HStack {
                Spacer()
                Button("选择本地文件夹…") {
                    dismiss()
                    openLocalFolder()
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                Spacer()
            }
            if !recentRepositories.entries.isEmpty {
                RecentRepositoriesView(store: recentRepositories, palette: palette, open: openRecentRepository)
                    .padding(.top, 8)
                    .disabled(model.isBusy)
            }
        }
        .padding(22).frame(minHeight: 205, alignment: .topLeading)
    }

    @ViewBuilder private var remoteContent: some View {
        if model.isAcquiring {
            acquisitionProgressContent
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if model.isLoadingOptions {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在准备版本控制方式…") }
                            .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                    } else if !model.options.isEmpty {
                        WorkbenchSegmentedPicker(
                            title: "远程仓库类型",
                            selection: providerBinding,
                            options: model.options.map { .init($0.providerID, $0.title) },
                            palette: palette
                        )
                        .disabled(model.isAcquiring)
                    }

                    field("远程地址") {
                        TextField(model.supportsBrowsing ? "https://server/svn/repository" : "https://server/owner/repository.git", text: $model.remoteURL)
                            .textFieldStyle(.plain).textSelection(.enabled)
                            .onChange(of: model.remoteURL) { _, _ in model.remoteLocationChanged() }
                            .disabled(model.isAcquiring)
                    }

                    if model.supportsCredentials {
                        DisclosureGroup("需要认证") {
                            VStack(spacing: 9) {
                                inlineField("用户名", text: $model.username)
                                    .onChange(of: model.username) { _, _ in model.remoteLocationChanged() }
                                HStack(spacing: 10) {
                                    Text("密码").font(.system(size: 12)).foregroundStyle(palette.secondaryText).frame(width: 44, alignment: .leading)
                                    SecureField("仅本次会话使用", text: $model.password)
                                        .textFieldStyle(.plain)
                                        .onChange(of: model.password) { _, _ in model.remoteLocationChanged() }
                                }
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .padding(.top, 8)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .tint(palette.accent)
                        .disabled(model.isAcquiring)
                    } else {
                        Text("Git 使用系统凭据、钥匙串或 SSH 代理；不会在 RepHub 中保存密码。")
                            .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    }

                    if model.supportsBrowsing { remoteBrowser.disabled(model.isAcquiring) } else { gitHint }
                    destinationForm
                    feedback
                    actionBar
                }
                .padding(22)
            }
            .frame(height: model.supportsBrowsing ? 590 : 410)
        }
    }

    private var acquisitionProgressContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.selectedOption?.actionTitle ?? "正在获取")
                .font(.system(size: 13, weight: .semibold))
            RepositoryTransferProgressView(
                progress: model.transferProgress,
                palette: palette,
                source: selectedSourceSummary,
                destination: model.destinationURL?.path,
                isCancelling: model.isCancelling,
                cancelTitle: "取消获取",
                cancel: model.cancel
            )
            Text("取消会停止当前传输；已产生的暂存内容会保留，便于检查。")
                .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
        }
        .padding(22)
        .frame(height: 480, alignment: .topLeading)
    }

    private var remoteBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("仓库目录").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
                Spacer()
                Button(model.isBrowsing ? "正在读取…" : "浏览") { model.browseRoot() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                    .disabled(model.isBusy || model.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let rootURL = model.rootListingURL, let listing = model.listings[rootURL] {
                RemoteDirectoryTree(
                    listing: listing,
                    listings: model.listings,
                    expandedURLs: model.expandedURLs,
                    selectedURL: model.selectedRemoteURL,
                    palette: palette,
                    toggle: model.toggleDirectory,
                    toggleRoot: model.toggleRootDirectory,
                    select: model.selectDirectory
                )
                .frame(height: 176, alignment: .topLeading)
                .background(palette.sidebar.opacity(0.48), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("连接后可展开目录并选择一个 SVN 文件夹；文件不会作为检出目标。")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 12).frame(height: 56, alignment: .leading)
                    .background(palette.sidebar.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let selected = model.selectedRemoteURL {
                Text("检出目录：\(selected.removingPercentEncoding ?? selected)")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(selected.removingPercentEncoding ?? selected)
            }
        }
    }

    private var gitHint: some View {
        Text("将克隆远程仓库的默认分支到新的本地文件夹。")
            .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 12).frame(height: 38, alignment: .leading)
            .background(palette.sidebar.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var destinationForm: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("本地保存位置").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
            HStack(spacing: 8) {
                Text(model.destinationParent?.path ?? "请选择父目录")
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(model.destinationParent == nil ? palette.secondaryText : palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Button("选择…", action: model.chooseDestinationParent)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                    .disabled(model.isBusy)
            }
            inlineField("新文件夹", text: Binding(
                get: { model.directoryName }, set: { model.setDirectoryName($0) }
            ))
            if let destination = model.destinationURL {
                Text(destination.path).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var feedback: some View {
        if model.isBrowsing {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(model.progressMessage.isEmpty ? "正在处理…" : model.progressMessage)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.selection.opacity(0.52), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        if let result = model.result, !isSuccessful(result.outcome) {
            resultMessage(result.summary, details: result.details, partial: result.partialDirectory)
            if !model.transferProgress.records.isEmpty {
                RepositoryTransferProgressView(
                    progress: model.transferProgress,
                    palette: palette,
                    source: selectedSourceSummary,
                    destination: model.destinationURL?.path,
                    isCancelling: false,
                    cancelTitle: "",
                    cancel: nil
                )
            }
        }
        if let errorMessage = model.errorMessage {
            resultMessage("操作未完成", details: errorMessage, partial: nil)
            if !model.transferProgress.records.isEmpty {
                RepositoryTransferProgressView(
                    progress: model.transferProgress,
                    palette: palette,
                    source: selectedSourceSummary,
                    destination: model.destinationURL?.path,
                    isCancelling: false,
                    cancelTitle: "",
                    cancel: nil
                )
            }
        }
    }

    private func resultMessage(_ title: String, details: String, partial: URL?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if !details.isEmpty { Text(details).font(.system(size: 11)).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true) }
            if let partial { Text("保留位置：\(partial.path)").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondaryText).textSelection(.enabled) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.sidebar.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func isSuccessful(_ outcome: RepositoryOperationOutcome) -> Bool {
        if case .succeeded = outcome { return true }
        return false
    }

    private var actionBar: some View {
        HStack {
            if model.isBusy {
                Button(model.isCancelling ? "正在取消…" : "取消", action: model.cancel)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                    .disabled(model.isCancelling)
            } else {
                Button("取消", action: dismiss).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
            }
            Spacer()
            Button(model.selectedOption?.actionTitle ?? "获取") {
                model.acquire { destination in
                    dismiss()
                    openAcquiredFolder(destination)
                }
            }
            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
            .disabled(model.isBusy || model.selectedOption == nil || model.destinationParent == nil || model.directoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.supportsBrowsing && model.selectedRemoteURL == nil) || (!model.supportsBrowsing && model.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
    }

    private var providerBinding: Binding<ProviderID> {
        Binding(
            get: { model.selectedProviderID ?? model.options.first!.providerID },
            set: { model.selectProvider($0) }
        )
    }

    private var selectedSourceSummary: String? {
        let selected = model.selectedRemoteURL ?? model.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected.removingPercentEncoding ?? selected
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
            content().padding(.horizontal, 10).frame(height: 30)
                .background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func inlineField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                .lineLimit(1).frame(width: 62, alignment: .leading)
            TextField(title, text: text).textFieldStyle(.plain)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct RemoteDirectoryTree: View {
    let listing: RemoteDirectoryListing
    let listings: [String: RemoteDirectoryListing]
    let expandedURLs: Set<String>
    let selectedURL: String?
    let palette: AppPalette
    let toggle: (RemoteDirectoryEntry) -> Void
    let toggleRoot: () -> Void
    let select: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                directoryRow(name: listing.url, url: listing.url, depth: 0, isRoot: true)
                if expandedURLs.contains(listing.url) {
                    RemoteDirectoryChildren(
                        entries: listing.entries, listings: listings, expandedURLs: expandedURLs,
                        selectedURL: selectedURL, palette: palette, toggle: toggle, select: select, depth: 1
                    )
                }
            }
            .padding(6)
        }
    }

    private func directoryRow(name: String, url: String, depth: Int, isRoot: Bool, entry: RemoteDirectoryEntry? = nil) -> some View {
        let selected = selectedURL == url
        return HStack(spacing: 4) {
            Button { if let entry { toggle(entry) } else { toggleRoot() } } label: {
                Image(systemName: expandedURLs.contains(url) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expandedURLs.contains(url) ? "收起根目录" : "展开根目录")
            Button { select(url) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder").foregroundStyle(palette.accent).frame(width: 14)
                    Text(isRoot ? "仓库根目录" : name).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.trailing, 7)
        .background(selected ? palette.selection.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct RemoteDirectoryChildren: View {
    let entries: [RemoteDirectoryEntry]
    let listings: [String: RemoteDirectoryListing]
    let expandedURLs: Set<String>
    let selectedURL: String?
    let palette: AppPalette
    let toggle: (RemoteDirectoryEntry) -> Void
    let select: (String) -> Void
    let depth: Int

    var body: some View {
        ForEach(entries) { entry in
            row(entry)
            if entry.isDirectory, expandedURLs.contains(entry.url), let child = listings[entry.url] {
                RemoteDirectoryChildren(
                    entries: child.entries, listings: listings, expandedURLs: expandedURLs,
                    selectedURL: selectedURL, palette: palette, toggle: toggle, select: select, depth: depth + 1
                )
            }
        }
    }

    @ViewBuilder private func row(_ entry: RemoteDirectoryEntry) -> some View {
        if entry.isDirectory {
            let selected = selectedURL == entry.url
            HStack(spacing: 4) {
                Button { toggle(entry) } label: {
                    Image(systemName: expandedURLs.contains(entry.url) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expandedURLs.contains(entry.url) ? "收起" : "展开") \(entry.name)")
                Button { select(entry.url) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder").foregroundStyle(palette.accent).frame(width: 14)
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 16).padding(.trailing, 7)
            .background(selected ? palette.selection.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            HStack(spacing: 7) {
                Image(systemName: "doc").foregroundStyle(palette.secondaryText).frame(width: 14)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            .padding(.leading, CGFloat(depth) * 16 + 7).padding(.trailing, 7).frame(height: 24)
        }
    }
}
