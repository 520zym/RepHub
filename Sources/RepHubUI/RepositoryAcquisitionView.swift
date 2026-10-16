import AppKit
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
    var openInNewWindow: ((URL) -> Void)? = nil

    @State private var source: Source = .local
    @State private var remoteDirectoryFilter = ""

    private enum Source: Hashable { case local, remote }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            modePicker
            if source == .local { localContent } else { remoteContent }
        }
        .workbenchSheet(minWidth: 740, idealWidth: sheetWidth, minHeight: 560, idealHeight: sheetHeight)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .onAppear { model.prepare() }
        .onDisappear { model.endSession() }
        .onChange(of: source) { _, _ in model.hidePassword() }
        .interactiveDismissDisabled(model.isBusy)
    }

    private var modePicker: some View {
        WorkbenchSegmentedPicker(
            title: "打开方式",
            selection: $source,
            options: [.init(.local, "本地文件夹"), .init(.remote, "远程仓库")],
            palette: palette
        )
        .disabled(model.isAcquiring)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, WorkbenchLayout.cardInset).padding(.top, 13).padding(.bottom, WorkbenchLayout.sectionGap)
    }

    /// sheet 首次呈现按可用屏幕宽度确定，避免 SwiftUI 只取最小尺寸而压缩三栏浏览页。
    private var sheetWidth: CGFloat {
        let availableWidth = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.width ?? 1_260
        return min(1_180, max(640, availableWidth - 80))
    }

    private var sheetHeight: CGFloat {
        let availableHeight = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 820
        return min(760, max(560, availableHeight - 110))
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: source == .local ? "folder.badge.plus" : "arrow.down.to.line.compact")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 31, height: 31)
                .background(palette.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("打开仓库").font(.system(size: 18, weight: .semibold))
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
        .padding(.horizontal, WorkbenchLayout.cardInset).padding(.vertical, 18)
        .background(palette.surface)
    }

    private var localContent: some View {
        VStack(alignment: .leading, spacing: WorkbenchLayout.sectionGap) {
            VStack(alignment: .leading, spacing: 14) {
                Text("选择已经存在的本地文件夹。RepHub 会自动识别 Git、SVN，或两者同时存在的工作副本。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                        openLocalFolder()
                    } label: {
                        Label {
                            Text("选择本地文件夹…")
                        } icon: {
                            Image(systemName: "folder.badge.plus").foregroundStyle(palette.accent)
                        }
                    }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                    Spacer()
                }
            }
            .padding(WorkbenchLayout.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkbenchLayout.cornerRadius, style: .continuous))
            if !recentRepositories.entries.isEmpty {
                RecentRepositoriesView(store: recentRepositories, palette: palette, open: openRecentRepository,
                                       maximumHeight: nil,
                                       openInNewWindow: openInNewWindow)
                    .padding(.top, WorkbenchLayout.sectionGap)
                    .disabled(model.isBusy)
            }
        }
        .padding(.horizontal, WorkbenchLayout.cardInset).padding(.bottom, WorkbenchLayout.cardInset)
        .frame(minHeight: 300, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var remoteContent: some View {
        if model.isAcquiring || model.transferHasFinished {
            transferPage
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
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
                }
                wizardFooter
            }
            .frame(maxHeight: .infinity)
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
        return VStack(alignment: .leading, spacing: 5) {
            Text("远程获取")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(height: WorkbenchLayout.titleRowHeight, alignment: .leading)
                .padding(.bottom, 13)
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                let isComplete = step.rawValue < model.wizardStep.rawValue
                let isCurrent = step == model.wizardStep
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(isCurrent ? palette.text : (isComplete ? palette.accent : palette.secondaryText.opacity(0.11)))
                        if isComplete {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.surface)
                        } else {
                            Text("\(index + 1)").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isCurrent ? palette.surface : palette.secondaryText)
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text(step.title).font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                }
                .foregroundStyle(isCurrent ? palette.surface : palette.secondaryText)
                .padding(.horizontal, 9).frame(height: 42)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isCurrent ? palette.text : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            Spacer(minLength: 18)
            connectionStatusCard
        }
        .padding(WorkbenchLayout.cardInset)
        .frame(width: 184, alignment: .topLeading)
        .background(palette.background)
    }

    private var connectionStatusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前连接").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondaryText)
            Text(model.remoteURL.isEmpty ? "尚未连接" : model.remoteURL)
                .font(.system(size: 10, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                .foregroundStyle(palette.secondaryText)
            if model.rootListingURL != nil {
                Label("已连接并读取目录", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.accent)
            } else if !model.remoteURL.isEmpty {
                Label("等待连接", systemImage: "circle.dotted")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.74), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
            .padding(WorkbenchLayout.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(palette.secondaryText)
                .accessibilityLabel(model.isPasswordVisible ? "隐藏密码" : "显示密码")
                .help(model.isPasswordVisible ? "隐藏密码" : "显示密码")
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                                    .frame(height: 25)
                                    .contentShape(.interaction, Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(palette.secondaryText)
                            Button { model.removeRecentRemote(entry) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).frame(width: 18, height: 18)
                                    .contentShape(.interaction, Rectangle())
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
            pageHeading("浏览远程仓库", detail: "展开文件夹继续浏览；点文件夹名称选择检出目标，箭头只负责展开或收起。")
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
            WorkbenchSearchField("筛选已读取的目录或文件", text: $remoteDirectoryFilter, palette: palette)
            GeometryReader { proxy in
                let showsSummary = proxy.size.width >= 600
                HStack(alignment: .top, spacing: WorkbenchLayout.sectionGap) {
                    directoryBrowser
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsSummary { selectedDirectorySummary }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = model.historyNotice { note(notice) }
            wizardError
        }
        .padding(WorkbenchLayout.cardInset)
    }

    @ViewBuilder private var directoryBrowser: some View {
        if let rootURL = model.rootListingURL, let listing = model.listings[rootURL] {
            RemoteDirectoryTree(listing: listing, listings: model.listings, expandedURLs: model.expandedURLs,
                                selectedURL: model.selectedRemoteURL, palette: palette,
                                filter: remoteDirectoryFilter, toggle: model.toggleDirectory,
                                toggleRoot: model.toggleRootDirectory, select: model.selectDirectory)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            VStack(spacing: 10) {
                if model.isBrowsing { ProgressView().controlSize(.small); Text("正在读取仓库目录…") }
                else { Image(systemName: "folder.badge.questionmark").font(.system(size: 24)); Text("尚未读取远程目录") }
            }
            .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var selectedDirectorySummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("将检出的目录").font(.system(size: 13, weight: .semibold))
            Image(systemName: model.selectedRemoteURL == nil ? "folder.badge.questionmark" : "folder.fill")
                .font(.system(size: 32, weight: .medium)).foregroundStyle(model.selectedRemoteURL == nil ? palette.secondaryText : palette.accent)
            Text(selectedRemoteDisplayName)
                .font(.system(size: 18, weight: .semibold)).lineLimit(2).truncationMode(.middle)
            Text(selectedSourceSummary ?? "从列表中选择一个文件夹")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondaryText)
                .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 9) {
                summaryMetadataRow("版本", value: selectedRemoteEntry?.latestRevision.map { "r\($0)" } ?? "—")
                summaryMetadataRow("提交人", value: selectedRemoteAuthor)
                summaryMetadataRow("提交时间", value: selectedRemoteEntry?.latestDate.map { $0.formatted(date: .long, time: .shortened) } ?? "—")
            }
            .padding(.top, 2)
            Spacer()
            Label(model.selectedRemoteURL == nil ? "尚未选择检出范围" : "仅检出此目录及其内容", systemImage: model.selectedRemoteURL == nil ? "info.circle" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.selectedRemoteURL == nil ? palette.secondaryText : palette.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((model.selectedRemoteURL == nil ? palette.sidebar : palette.selection).opacity(0.7), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .padding(WorkbenchLayout.cardInset)
        .frame(width: 245)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var selectedRemoteDisplayName: String {
        guard let source = selectedSourceSummary, !source.isEmpty else { return "尚未选择目录" }
        return URL(string: source)?.lastPathComponent.isEmpty == false ? (URL(string: source)?.lastPathComponent ?? source) : source
    }

    /// 只复用浏览树已读取的数据；根节点和未读取的节点没有条目元数据，按缺失展示。
    private var selectedRemoteEntry: RemoteDirectoryEntry? {
        guard let selectedURL = model.selectedRemoteURL else { return nil }
        return model.listings.values.lazy
            .flatMap { $0.entries }
            .first { $0.url == selectedURL }
    }

    private var selectedRemoteAuthor: String {
        guard let author = selectedRemoteEntry?.latestAuthor, !author.isEmpty else { return "—" }
        return author
    }

    private func summaryMetadataRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondaryText)
                .frame(width: 48, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.text)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var destinationPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeading("选择本地位置", detail: "获取会在选定父目录下新建工作副本文件夹，不会改动已有目录。")
            sourceSummary
            destinationForm
            wizardError
            Spacer()
        }
        .padding(WorkbenchLayout.cardInset)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkbenchLayout.cardInset)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkbenchLayout.cornerRadius, style: .continuous))
            note(model.supportsCredentials
                 ? "密码不会显示或写入日志；检出成功后会安全记住，以便下次自动填入。"
                 : "Git 凭据由系统钥匙串或 SSH 代理管理。")
            wizardError
            Spacer()
        }
        .padding(WorkbenchLayout.cardInset)
    }

    private var sourceSummary: some View {
        HStack(spacing: 9) {
            Image(systemName: model.supportsBrowsing ? "folder" : "arrow.triangle.branch").foregroundStyle(palette.accent)
            Text(selectedSourceSummary ?? model.remoteURL).font(.system(size: 11, design: .monospaced))
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
        .foregroundStyle(palette.secondaryText).padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.horizontal, WorkbenchLayout.cardInset).padding(.vertical, 16).background(palette.surface)
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
                .padding(.horizontal, WorkbenchLayout.cardInset).padding(.top, WorkbenchLayout.cardInset).padding(.bottom, 14)
            }
            transferControls
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
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
        .padding(.horizontal, WorkbenchLayout.cardInset).padding(.vertical, 16)
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
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.selection.opacity(0.56), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private func pageHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 24, weight: .semibold))
                .frame(height: WorkbenchLayout.titleRowHeight, alignment: .leading)
            Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            content().padding(.horizontal, 12).frame(height: 34)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func inlineField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                .lineLimit(1).frame(width: 62, alignment: .leading)
            TextField(title, text: text).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct RemoteDirectoryTree: View {
    let listing: RemoteDirectoryListing
    let listings: [String: RemoteDirectoryListing]
    let expandedURLs: Set<String>
    let selectedURL: String?
    let palette: AppPalette
    let filter: String
    let toggle: (RemoteDirectoryEntry) -> Void
    let toggleRoot: () -> Void
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            directoryColumnHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    directoryRow(name: listing.url, url: listing.url, depth: 0, isRoot: true)
                    if expandedURLs.contains(listing.url) || !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        RemoteDirectoryChildren(
                            entries: listing.entries, listings: listings, expandedURLs: expandedURLs,
                            selectedURL: selectedURL, palette: palette, filter: filter,
                            toggle: toggle, select: select, depth: 1
                        )
                    }
                }
                .padding(8)
            }
        }
    }

    private var directoryColumnHeader: some View {
        HStack(spacing: 0) {
            Text("目录名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("最近修订").frame(width: RemoteDirectoryColumns.revision, alignment: .leading)
            Text("提交人").frame(width: RemoteDirectoryColumns.author, alignment: .leading)
            Text("更新时间").frame(width: RemoteDirectoryColumns.date, alignment: .leading)
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 18).frame(height: 38)
        .background(palette.background.opacity(0.72))
    }

    private func directoryRow(name: String, url: String, depth: Int, isRoot: Bool, entry: RemoteDirectoryEntry? = nil) -> some View {
        let selected = selectedURL == url
        return HStack(spacing: 0) {
            Button { if let entry { toggle(entry) } else { toggleRoot() } } label: {
                Image(systemName: expandedURLs.contains(url) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 42)
                    .contentShape(.interaction, Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expandedURLs.contains(url) ? "收起根目录" : "展开根目录")
            Button { select(url) } label: {
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(palette.accent).frame(width: 14)
                        Text(isRoot ? "仓库根目录" : name).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    metadataColumns(for: entry)
                }
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .frame(height: 44)
                .contentShape(.interaction, Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 18 + 6).padding(.trailing, 12).frame(height: 44)
        .background(selected ? palette.selection.opacity(0.74) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func metadataColumns(for entry: RemoteDirectoryEntry?) -> some View {
        Group {
            metadataValue(entry?.latestRevision.map { "r\($0)" }).frame(width: RemoteDirectoryColumns.revision, alignment: .leading)
            metadataValue(entry?.latestAuthor).frame(width: RemoteDirectoryColumns.author, alignment: .leading)
            metadataValue(entry?.latestDate.map(RemoteDirectoryColumns.numericDate)).frame(width: RemoteDirectoryColumns.date, alignment: .leading)
        }
    }

    private func metadataValue(_ value: String?) -> some View {
        Text(value?.isEmpty == false ? value! : "—")
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.secondaryText)
            .lineLimit(1).truncationMode(.tail)
    }
}

private enum RemoteDirectoryColumns {
    static let revision: CGFloat = 78
    static let author: CGFloat = 112
    static let date: CGFloat = 150

    static func numericDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }
}

private struct RemoteDirectoryChildren: View {
    let entries: [RemoteDirectoryEntry]
    let listings: [String: RemoteDirectoryListing]
    let expandedURLs: Set<String>
    let selectedURL: String?
    let palette: AppPalette
    let filter: String
    let toggle: (RemoteDirectoryEntry) -> Void
    let select: (String) -> Void
    let depth: Int

    var body: some View {
        ForEach(entries.filter(isVisible)) { entry in
            row(entry)
            if entry.isDirectory, displaysChildren(of: entry), let child = listings[entry.url] {
                RemoteDirectoryChildren(
                    entries: child.entries, listings: listings, expandedURLs: expandedURLs,
                    selectedURL: selectedURL, palette: palette, filter: filter,
                    toggle: toggle, select: select, depth: depth + 1
                )
            }
        }
    }

    private var normalizedFilter: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isVisible(_ entry: RemoteDirectoryEntry) -> Bool {
        guard !normalizedFilter.isEmpty else { return true }
        if entry.name.localizedCaseInsensitiveContains(normalizedFilter) { return true }
        guard entry.isDirectory, let children = listings[entry.url]?.entries else { return false }
        return children.contains(where: isVisible)
    }

    private func displaysChildren(of entry: RemoteDirectoryEntry) -> Bool {
        expandedURLs.contains(entry.url) || (!normalizedFilter.isEmpty && isVisible(entry))
    }

    @ViewBuilder private func row(_ entry: RemoteDirectoryEntry) -> some View {
        if entry.isDirectory {
            let selected = selectedURL == entry.url
            HStack(spacing: 0) {
                Button { toggle(entry) } label: {
                    Image(systemName: expandedURLs.contains(entry.url) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 42)
                        .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expandedURLs.contains(entry.url) ? "收起" : "展开") \(entry.name)")
                Button { select(entry.url) } label: {
                    HStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(palette.accent).frame(width: 14)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        metadataColumns(for: entry)
                    }
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .frame(height: 44)
                    .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 18 + 6).padding(.trailing, 12).frame(height: 44)
            .background(selected ? palette.selection.opacity(0.74) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            HStack(spacing: 0) {
                Color.clear.frame(width: 18)
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundStyle(palette.secondaryText).frame(width: 14)
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                metadataColumns(for: entry)
            }
            .font(.system(size: 14)).foregroundStyle(palette.secondaryText)
            .padding(.leading, CGFloat(depth) * 18 + 6).padding(.trailing, 12).frame(height: 44)
        }
    }

    private func metadataColumns(for entry: RemoteDirectoryEntry) -> some View {
        Group {
            metadataValue(entry.latestRevision.map { "r\($0)" }).frame(width: RemoteDirectoryColumns.revision, alignment: .leading)
            metadataValue(entry.latestAuthor).frame(width: RemoteDirectoryColumns.author, alignment: .leading)
            metadataValue(entry.latestDate.map(RemoteDirectoryColumns.numericDate)).frame(width: RemoteDirectoryColumns.date, alignment: .leading)
        }
    }

    private func metadataValue(_ value: String?) -> some View {
        Text(value?.isEmpty == false ? value! : "—")
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.secondaryText)
            .lineLimit(1).truncationMode(.tail)
    }
}
