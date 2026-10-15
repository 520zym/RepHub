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
        .frame(width: 720)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .onAppear { model.prepare() }
        .onDisappear { model.endSession() }
        .onChange(of: source) { _, _ in model.hidePassword() }
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
                Text(source == .local ? "识别已有 Git 或 SVN 工作副本" : remoteSubtitle)
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if !model.isBusy {
                Button(action: { model.hidePassword(); dismiss() }) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
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
        if model.isAcquiring || model.transferHasFinished {
            transferPage
        } else {
            VStack(alignment: .leading, spacing: 0) {
                wizardProgress
                Group {
                    switch model.wizardStep {
                    case .connection: connectionPage
                    case .browse: browsePage
                    case .destination: destinationPage
                    case .review: reviewPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                wizardFooter
            }
            .frame(height: 500)
        }
    }

    private var remoteSubtitle: String {
        if model.isAcquiring { return "正在安全获取工作副本" }
        if model.transferHasFinished { return "查看获取结果或重试" }
        switch model.wizardStep {
        case .connection: return "连接 Git 或 SVN 远程仓库"
        case .browse: return "浏览并选择 SVN 仓库中的目录"
        case .destination: return "选择新的本地工作副本位置"
        case .review: return "确认来源和本地目标后开始获取"
        }
    }

    private var wizardProgress: some View {
        let steps: [RepositoryAcquisitionModel.WizardStep] = model.usesBrowseStep
            ? [.connection, .browse, .destination, .review]
            : [.connection, .destination, .review]
        return HStack(spacing: 7) {
            ForEach(steps, id: \.self) { step in
                let complete = step.rawValue <= model.wizardStep.rawValue
                HStack(spacing: 5) {
                    Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12, weight: .medium))
                    Text(step.title).font(.system(size: 11, weight: step == model.wizardStep ? .semibold : .regular))
                }
                .foregroundStyle(complete ? palette.accent : palette.secondaryText)
                if step != steps.last { Spacer(minLength: 3) }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(palette.sidebar.opacity(0.45))
    }

    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeading("连接远程仓库", detail: "可选择最近使用的远程地址；SVN 账号会按服务器自动填入。")
                if model.isLoadingOptions {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在准备版本控制方式…") }
                        .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                } else if !model.options.isEmpty {
                    WorkbenchSegmentedPicker(title: "远程仓库类型", selection: providerBinding,
                                               options: model.options.map { .init($0.providerID, $0.title) }, palette: palette)
                }
                field("远程地址") {
                    TextField(model.supportsBrowsing ? "https://server/svn/repository" : "https://server/owner/repository.git", text: remoteURLBinding)
                        .textFieldStyle(.plain).textSelection(.enabled)
                }
                if !model.recentRemoteEntries.isEmpty { recentRemoteAddresses }
                if model.supportsCredentials { credentialsForm }
                else { note("Git 使用系统凭据、钥匙串或 SSH 代理；RepHub 会记住成功使用的远程地址。") }
                if let notice = model.historyNotice { note(notice) }
                wizardError
            }
            .padding(22)
        }
    }

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SVN 认证").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
            if !model.savedAccounts.isEmpty { savedAccountPicker }
            inlineField("用户名", text: usernameBinding)
            HStack(spacing: 10) {
                Text("密码").font(.system(size: 12)).foregroundStyle(palette.secondaryText).frame(width: 62, alignment: .leading)
                Group {
                    if model.isPasswordVisible { TextField("已安全记住的密码会自动填入", text: passwordBinding) }
                    else { SecureField("已安全记住的密码会自动填入", text: passwordBinding) }
                }
                .textFieldStyle(.plain)
                Button(action: model.togglePasswordVisibility) {
                    Image(systemName: model.isPasswordVisible ? "eye.slash" : "eye")
                        .font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(palette.secondaryText)
                .accessibilityLabel(model.isPasswordVisible ? "隐藏密码" : "显示密码")
                .help(model.isPasswordVisible ? "隐藏密码" : "显示密码")
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if model.isLoadingSavedCredentials {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在读取上次使用的 SVN 账号…") }
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
        }
    }

    private var recentRemoteAddresses: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近使用").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondaryText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.recentRemoteEntries) { entry in
                        HStack(spacing: 6) {
                            Button { model.selectRecentRemote(entry) } label: {
                                Text(entry.url.removingPercentEncoding ?? entry.url)
                                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).foregroundStyle(palette.secondaryText)
                            Button { model.removeRecentRemote(entry) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain).foregroundStyle(palette.secondaryText)
                            .accessibilityLabel("移除最近地址")
                        }
                        .padding(.horizontal, 9).frame(height: 25)
                        .background(palette.sidebar.opacity(0.45), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 96)
        }
    }

    private var savedAccountPicker: some View {
        HStack(spacing: 8) {
            Text("已记住账号").font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            Menu {
                ForEach(model.savedAccounts) { account in
                    Button("填入 \(account.username)") { model.selectSavedAccount(account) }
                }
                Divider()
                ForEach(model.savedAccounts) { account in
                    Button("忘记 \(account.username)", role: .destructive) { model.removeSavedAccount(account) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.username.isEmpty ? "选择账号" : model.username).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 220, alignment: .leading)
        }
    }

    private var browsePage: some View {
        VStack(alignment: .leading, spacing: 15) {
            pageHeading("选择 SVN 目录", detail: "展开文件夹继续浏览；点文件夹名称选择检出目标，箭头只负责展开或收起。")
            HStack(spacing: 9) {
                Text(model.remoteURL.removingPercentEncoding ?? model.remoteURL)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondaryText)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if model.isBrowsing {
                    Button("取消读取", action: model.cancel)
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                }
                Button(model.isBrowsing ? "正在读取…" : "读取根目录") { model.browseRoot() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                    .disabled(model.isBrowsing)
            }
            if let rootURL = model.rootListingURL, let listing = model.listings[rootURL] {
                RemoteDirectoryTree(listing: listing, listings: model.listings, expandedURLs: model.expandedURLs,
                                    selectedURL: model.selectedRemoteURL, palette: palette,
                                    toggle: model.toggleDirectory, toggleRoot: model.toggleRootDirectory, select: model.selectDirectory)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(palette.sidebar.opacity(0.52), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    if model.isBrowsing { ProgressView().controlSize(.small); Text("正在读取仓库目录…") }
                    else { Image(systemName: "folder.badge.questionmark").font(.system(size: 24)); Text("尚未读取远程目录") }
                }
                .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.sidebar.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let selected = model.selectedRemoteURL { note("将检出：\(selected.removingPercentEncoding ?? selected)") }
            if let notice = model.historyNotice { note(notice) }
            wizardError
        }
        .padding(22)
    }

    private var destinationPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeading("选择本地位置", detail: "获取会在选定父目录下新建工作副本文件夹，不会改动已有目录。")
            sourceSummary
            destinationForm
            wizardError
            Spacer()
        }
        .padding(22)
    }

    private var reviewPage: some View {
        VStack(alignment: .leading, spacing: 17) {
            pageHeading(model.selectedOption?.actionTitle == "检出" ? "确认检出" : "确认克隆", detail: "开始后会显示当前文件和传输状态；可随时取消。")
            VStack(alignment: .leading, spacing: 13) {
                reviewRow("方式", value: model.selectedOption?.title ?? "")
                reviewRow("来源", value: selectedSourceSummary ?? "")
                reviewRow("本地位置", value: model.destinationURL?.path ?? "")
                if model.supportsCredentials, !model.username.isEmpty { reviewRow("认证用户", value: model.username) }
            }
            .padding(16).background(palette.sidebar.opacity(0.54), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            note(model.supportsCredentials
                 ? "密码不会显示或写入日志；检出成功后会安全记住，以便下次自动填入。"
                 : "Git 凭据由系统钥匙串或 SSH 代理管理。")
            wizardError
            Spacer()
        }
        .padding(22)
    }

    private var sourceSummary: some View {
        HStack(spacing: 9) {
            Image(systemName: model.supportsBrowsing ? "folder" : "arrow.triangle.branch").foregroundStyle(palette.accent)
            Text(selectedSourceSummary ?? model.remoteURL).font(.system(size: 11, design: .monospaced))
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
        .foregroundStyle(palette.secondaryText).padding(12)
        .background(palette.sidebar.opacity(0.48), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var wizardFooter: some View {
        HStack {
            Button(model.wizardStep == .connection ? "取消" : "上一步") {
                if model.wizardStep == .connection { model.hidePassword(); dismiss() }
                else { model.goBackInWizard() }
            }
            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
            Spacer()
            if model.wizardStep == .review {
                Button(model.selectedOption?.actionTitle ?? "获取", action: acquire)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
            } else {
                Button("下一步", action: model.advanceWizard)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                    .disabled(model.isLoadingSavedCredentials)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16).background(palette.surface)
    }

    private var transferPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pageHeading(transferTitle, detail: transferDetail)
                    RepositoryTransferProgressView(
                        progress: model.transferProgress,
                        palette: palette,
                        source: selectedSourceSummary,
                        destination: model.destinationURL?.path,
                        isCancelling: model.isCancelling,
                        cancelTitle: "取消获取",
                        cancel: nil
                    )
                    if let notice = model.historyNotice { note(notice) }
                    transferOutcome
                }
                .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 12)
            }
            transferControls
        }
        .frame(height: 500, alignment: .topLeading)
    }

    private var transferTitle: String {
        model.isAcquiring ? (model.selectedOption?.actionTitle ?? "正在获取") : (model.result?.summary ?? "获取未完成")
    }

    private var transferDetail: String {
        if model.isAcquiring { return "正在获取工作副本，可查看当前文件和传输状态。" }
        return model.errorMessage ?? model.result?.details ?? ""
    }

    @ViewBuilder private var transferOutcome: some View {
        if let result = model.result, !isSuccessful(result.outcome) {
            resultMessage(result.summary, details: result.details, partial: result.partialDirectory)
        } else if let message = model.errorMessage {
            resultMessage("操作未完成", details: message, partial: nil)
        }
    }

    private var transferControls: some View {
        HStack {
            if model.isAcquiring {
                Button(model.isCancelling ? "正在取消…" : "取消获取", action: model.cancel)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                    .disabled(model.isCancelling)
            } else {
                Button("返回确认", action: model.retryTransfer)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                Spacer()
                Button("关闭") { model.hidePassword(); dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(palette.surface)
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

    @ViewBuilder private var wizardError: some View {
        if let message = model.errorMessage {
            Text(message).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.selection.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func pageHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.sidebar.opacity(0.48), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func reviewRow(_ name: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(name).font(.system(size: 11)).foregroundStyle(palette.secondaryText).frame(width: 54, alignment: .leading)
            Text(value).font(.system(size: 12)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func acquire() {
        model.acquire { destination in
            model.hidePassword()
            dismiss()
            openAcquiredFolder(destination)
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

    private var providerBinding: Binding<ProviderID> {
        Binding(
            get: { model.selectedProviderID ?? model.options.first!.providerID },
            set: { model.selectProvider($0) }
        )
    }

    private var remoteURLBinding: Binding<String> {
        Binding(get: { model.remoteURL }, set: { model.setRemoteURLFromUser($0) })
    }

    private var usernameBinding: Binding<String> {
        Binding(get: { model.username }, set: { model.setUsernameFromUser($0) })
    }

    private var passwordBinding: Binding<String> {
        Binding(get: { model.password }, set: { model.setPasswordFromUser($0) })
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
                    Spacer(minLength: 6)
                    remoteMetadata(for: entry)
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
                Spacer(minLength: 6)
                remoteMetadata(for: entry)
            }
            .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            .padding(.leading, CGFloat(depth) * 16 + 7).padding(.trailing, 7).frame(height: 24)
        }
    }

    @ViewBuilder private func remoteMetadata(for entry: RemoteDirectoryEntry) -> some View {
        if entry.latestRevision != nil || entry.latestDate != nil {
            HStack(spacing: 5) {
                if let revision = entry.latestRevision { Text("r\(revision)") }
                if let date = entry.latestDate { Text(date.formatted(date: .abbreviated, time: .shortened)) }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
            .help(metadataHelp(for: entry))
        }
    }

    private func metadataHelp(for entry: RemoteDirectoryEntry) -> String {
        var parts: [String] = []
        if let revision = entry.latestRevision { parts.append("修订 r\(revision)") }
        if let date = entry.latestDate { parts.append(date.formatted(date: .long, time: .shortened)) }
        if let author = entry.latestAuthor, !author.isEmpty { parts.append(author) }
        return parts.joined(separator: " · ")
    }
}
