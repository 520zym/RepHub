import AppKit
import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

/// 新建工作副本的短生命周期状态。输入框中的认证信息只保留在内存；成功使用后才交给受保护的凭据存储。
@MainActor
@Observable
public final class RepositoryAcquisitionModel {
    public enum WizardStep: Int, CaseIterable {
        case connection
        case browse
        case destination
        case review

        var title: String {
            switch self {
            case .connection: "连接"
            case .browse: "选择目录"
            case .destination: "本地位置"
            case .review: "确认"
            }
        }
    }

    public private(set) var options: [RepositoryAcquisitionOption] = []
    public var selectedProviderID: ProviderID?
    public var remoteURL = ""
    public var username = ""
    public var password = ""
    public private(set) var isPasswordVisible = false
    public var destinationParent: URL?
    public var directoryName = ""
    public private(set) var listings: [String: RemoteDirectoryListing] = [:]
    public private(set) var rootListingURL: String?
    public private(set) var expandedURLs: Set<String> = []
    public var selectedRemoteURL: String?
    public private(set) var isLoadingOptions = false
    public private(set) var isBrowsing = false
    public private(set) var isAcquiring = false
    public private(set) var isCancelling = false
    public private(set) var progressMessage = ""
    public let transferProgress = TransferProgressState()
    public private(set) var result: RepositoryAcquisitionResult?
    public private(set) var errorMessage: String?
    public private(set) var wizardStep: WizardStep = .connection
    public private(set) var isLoadingSavedCredentials = false
    public private(set) var historyNotice: String?

    private let service: RepositoryService
    private let remoteHistory: RemoteRepositoryHistoryStore
    private var browsingTask: Task<Void, Never>?
    private var acquisitionTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var requestID = 0
    private var directoryNameIsSuggested = true
    private var hasStartedAcquisition = false
    private var credentialRequestID = 0
    private var credentialInputRevision = 0
    private var activeCredentialServer: String?

    public init(service: RepositoryService,
                remoteHistory: RemoteRepositoryHistoryStore = RemoteRepositoryHistoryStore()) {
        self.service = service
        self.remoteHistory = remoteHistory
    }

    isolated deinit {
        browsingTask?.cancel()
        acquisitionTask?.cancel()
        credentialTask?.cancel()
    }

    public var selectedOption: RepositoryAcquisitionOption? {
        options.first { $0.providerID == selectedProviderID }
    }

    public var supportsBrowsing: Bool { selectedOption?.supportsBrowsing == true }
    public var supportsCredentials: Bool { selectedOption?.supportsCredentials == true }
    public var isBusy: Bool { isBrowsing || isAcquiring }
    public var usesBrowseStep: Bool { supportsBrowsing }
    public var transferHasFinished: Bool { result != nil || (hasStartedAcquisition && errorMessage != nil) }
    public var destinationURL: URL? {
        guard let destinationParent, !directoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return destinationParent.appendingPathComponent(directoryName.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
    }
    public var recentRemoteEntries: [RemoteRepositoryHistoryEntry] {
        guard let selectedProviderID else { return [] }
        return remoteHistory.entries(for: selectedProviderID)
    }
    public var savedAccounts: [SavedRepositoryAccount] { remoteHistory.accounts(for: remoteURL) }

    public func prepare() {
        // 已成功获取后再次打开入口，开始新一轮选择；地址仍可从历史中取回。
        if !isBusy, case .succeeded? = result?.outcome { reset() }
        if !options.isEmpty {
            scheduleCredentialAutofillIfNeeded()
            return
        }
        guard !isLoadingOptions else { return }
        isLoadingOptions = true
        Task { [weak self, service] in
            let options = await service.acquisitionOptions()
            guard let self else { return }
            self.options = options
            self.selectedProviderID = self.selectedProviderID ?? options.first?.providerID
            self.isLoadingOptions = false
            self.scheduleCredentialAutofillIfNeeded()
        }
    }

    public func selectProvider(_ providerID: ProviderID) {
        guard selectedProviderID != providerID else { return }
        selectedProviderID = providerID
        wizardStep = .connection
        isPasswordVisible = false
        historyNotice = nil
        clearCredentials()
        activeCredentialServer = nil
        credentialRequestID += 1
        credentialTask?.cancel()
        invalidateRemoteTree()
        scheduleCredentialAutofillIfNeeded()
    }

    /// 仅由地址输入框和最近地址菜单调用；自动填充不反向调用它，以免覆盖用户手动修改。
    public func setRemoteURLFromUser(_ value: String) {
        remoteURL = value
        historyNotice = nil
        remoteLocationChanged()
        scheduleCredentialAutofillIfNeeded()
        if !supportsBrowsing, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateSuggestedDirectoryName(for: value)
        }
    }

    public func selectRecentRemote(_ entry: RemoteRepositoryHistoryEntry) {
        guard entry.providerID == selectedProviderID else { return }
        setRemoteURLFromUser(entry.url)
    }

    public func setUsernameFromUser(_ value: String) {
        credentialRequestID += 1
        credentialTask?.cancel()
        isLoadingSavedCredentials = false
        historyNotice = nil
        credentialInputRevision += 1
        username = value
        password = ""
        hidePassword()
        remoteLocationChanged()
    }

    public func setPasswordFromUser(_ value: String) {
        credentialRequestID += 1
        credentialTask?.cancel()
        isLoadingSavedCredentials = false
        historyNotice = nil
        credentialInputRevision += 1
        password = value
        remoteLocationChanged()
    }

    public func selectSavedAccount(_ account: SavedRepositoryAccount) {
        guard supportsCredentials,
              RemoteRepositoryHistoryStore.credentialServer(for: remoteURL) == account.server else { return }
        hidePassword()
        clearCredentials()
        invalidateRemoteTree()
        activeCredentialServer = account.server
        loadSavedCredentials(username: account.username, server: account.server)
    }

    public func removeRecentRemote(_ entry: RemoteRepositoryHistoryEntry) { remoteHistory.remove(entry) }

    public func removeSavedAccount(_ account: SavedRepositoryAccount) {
        // “忘记”必须使正在返回的旧密码失效，不能在删除后又填回输入框。
        credentialRequestID += 1
        credentialTask?.cancel()
        isLoadingSavedCredentials = false
        let token = credentialRequestID
        let inputRevision = credentialInputRevision
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.remoteHistory.removeAccount(account)
                guard self.credentialRequestID == token,
                      self.credentialInputRevision == inputRevision else { return }
                if self.username == account.username,
                   RemoteRepositoryHistoryStore.credentialServer(for: self.remoteURL) == account.server {
                    self.clearCredentials()
                    self.invalidateRemoteTree()
                }
            } catch {
                self.historyNotice = "无法忘记 SVN 账号：\(error.localizedDescription)"
            }
        }
    }

    /// URL 与身份信息都会影响 SVN 服务端可见目录，因此不能继续使用此前读取的树。
    public func remoteLocationChanged() {
        invalidateRemoteTree()
        result = nil
        errorMessage = nil
    }

    /// 密码只允许在当前短生命周期界面中临时显示，切换步骤、关闭或开始传输时会恢复遮挡。
    public func togglePasswordVisibility() {
        guard supportsCredentials, !isBusy else { return }
        isPasswordVisible.toggle()
    }

    public func hidePassword() {
        isPasswordVisible = false
    }

    public func advanceWizard() {
        guard !isBusy, !isLoadingSavedCredentials else { return }
        errorMessage = nil
        switch wizardStep {
        case .connection:
            guard !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "请先输入远程仓库地址。"
                return
            }
            hidePassword()
            if supportsBrowsing {
                wizardStep = .browse
                // 第一次进入目录页即读取根目录；从上一步返回后保留已经浏览的树。
                if rootListingURL == nil { browseRoot() }
            } else {
                wizardStep = .destination
            }
        case .browse:
            guard selectedRemoteURL != nil else {
                errorMessage = "请选择要检出的 SVN 文件夹。"
                return
            }
            wizardStep = .destination
        case .destination:
            guard destinationParent != nil else {
                errorMessage = "请选择本地保存位置。"
                return
            }
            guard !directoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "请填写新的本地文件夹名称。"
                return
            }
            wizardStep = .review
        case .review:
            break
        }
    }

    public func goBackInWizard() {
        guard !isBusy else { return }
        errorMessage = nil
        hidePassword()
        switch wizardStep {
        case .connection: break
        case .browse: wizardStep = .connection
        case .destination: wizardStep = supportsBrowsing ? .browse : .connection
        case .review: wizardStep = .destination
        }
    }

    public func retryTransfer() {
        guard !isBusy else { return }
        result = nil
        errorMessage = nil
        transferProgress.clear()
        progressMessage = ""
        hasStartedAcquisition = false
        wizardStep = .review
    }

    public func chooseDestinationParent() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择本地位置"
        panel.message = "将在此文件夹中创建新的工作副本目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let destinationParent { panel.directoryURL = destinationParent }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationParent = url.standardizedFileURL.resolvingSymlinksInPath()
        result = nil
        errorMessage = nil
    }

    public func browseRoot() {
        guard !isAcquiring else { return }
        let normalizedURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else {
            errorMessage = "请先输入远程仓库地址。"
            return
        }
        guard let selectedProviderID else { return }
        invalidateRemoteTree()
        browse(url: normalizedURL, providerID: selectedProviderID, makesSelection: true)
    }

    public func toggleDirectory(_ entry: RemoteDirectoryEntry) {
        guard entry.isDirectory, let selectedProviderID, !isAcquiring else { return }
        if expandedURLs.contains(entry.url) {
            expandedURLs.remove(entry.url)
        } else if listings[entry.url] != nil {
            expandedURLs.insert(entry.url)
        } else {
            // 展开目录不等于把它设为检出目标；只有点目录名称才会改变选择。
            browse(url: entry.url, providerID: selectedProviderID, makesSelection: false)
        }
    }

    public func toggleRootDirectory() {
        guard let rootListingURL else { return }
        if expandedURLs.contains(rootListingURL) { expandedURLs.remove(rootListingURL) }
        else { expandedURLs.insert(rootListingURL) }
    }

    public func selectDirectory(_ url: String) {
        selectedRemoteURL = url
        updateSuggestedDirectoryName(for: url)
        result = nil
        errorMessage = nil
    }

    public func setDirectoryName(_ name: String) {
        directoryName = name
        directoryNameIsSuggested = false
    }

    public func acquire(onSuccess: @escaping @MainActor (URL) -> Void) {
        guard !isBusy, let option = selectedOption else { return }
        let sourceURL: String
        if option.supportsBrowsing {
            sourceURL = selectedRemoteURL ?? remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sourceURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !sourceURL.isEmpty else { errorMessage = "请先输入远程仓库地址。"; return }
        guard let destinationParent else { errorMessage = "请选择本地保存位置。"; return }
        let name = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "请填写新的本地文件夹名称。"; return }

        let credentials = supportsCredentials && (!username.isEmpty || !password.isEmpty)
            ? RepositoryCredentials(username: username, password: password) : nil
        let location = RemoteRepositoryLocation(url: sourceURL, credentials: credentials)
        requestID += 1
        let token = requestID
        hasStartedAcquisition = true
        isAcquiring = true
        hidePassword()
        isCancelling = false
        progressMessage = "正在准备\(option.actionTitle)…"
        transferProgress.begin(progressMessage)
        result = nil
        errorMessage = nil
        acquisitionTask = Task { [weak self, service] in
            do {
                let result = try await service.acquire(
                    providerID: option.providerID,
                    location: location,
                    destinationParent: destinationParent,
                    directoryName: name
                ) { progress in
                    await MainActor.run {
                        guard let self, self.requestID == token else { return }
                        self.progressMessage = progress.message
                        self.transferProgress.consume(progress)
                    }
                }
                guard let self, self.requestID == token else { return }
                self.isAcquiring = false
                self.isCancelling = false
                self.result = result
                self.progressMessage = result.summary
                self.transferProgress.finish(result.summary)
                if case .succeeded = result.outcome {
                    await self.recordSuccessfulRemoteUse(providerID: option.providerID, url: sourceURL,
                                                         credentials: credentials)
                    // 密码保存可在关闭窗口后才完成；此时不能再清空新界面或触发旧的导航回调。
                    guard self.requestID == token else { return }
                    self.clearCredentials()
                    onSuccess(result.destination)
                }
            } catch is CancellationError {
                guard let self, self.requestID == token else { return }
                self.isAcquiring = false
                self.isCancelling = false
                self.errorMessage = "已取消，正在保留已产生的临时目录供检查。"
                self.transferProgress.finish("获取已取消")
            } catch {
                guard let self, self.requestID == token else { return }
                self.isAcquiring = false
                self.isCancelling = false
                self.errorMessage = error.localizedDescription
                self.transferProgress.finish("获取未完成")
            }
        }
    }

    public func cancel() {
        guard isBusy, !isCancelling else { return }
        isCancelling = true
        progressMessage = isAcquiring ? "正在取消并保留已下载内容…" : "正在取消目录读取…"
        if isAcquiring { transferProgress.consume(RepositoryOperationProgress(progressMessage)) }
        if isBrowsing && !isAcquiring {
            // 目录读取是纯读操作；立即使迟到响应失效，避免已取消的旧树重新出现。
            requestID += 1
            isBrowsing = false
            isCancelling = false
            browsingTask?.cancel()
        } else {
            acquisitionTask?.cancel()
        }
    }

    public func reset() {
        guard !isBusy else { return }
        remoteURL = ""
        clearCredentials()
        activeCredentialServer = nil
        credentialRequestID += 1
        credentialTask?.cancel()
        isLoadingSavedCredentials = false
        isPasswordVisible = false
        historyNotice = nil
        destinationParent = nil
        directoryName = ""
        directoryNameIsSuggested = true
        invalidateRemoteTree()
        result = nil
        errorMessage = nil
        progressMessage = ""
        hasStartedAcquisition = false
        wizardStep = .connection
        transferProgress.clear()
    }

    private func browse(url: String, providerID: ProviderID, makesSelection: Bool) {
        requestID += 1
        let token = requestID
        let credentials = supportsCredentials && (!username.isEmpty || !password.isEmpty)
            ? RepositoryCredentials(username: username, password: password) : nil
        let location = RemoteRepositoryLocation(url: url, credentials: credentials)
        isBrowsing = true
        isCancelling = false
        errorMessage = nil
        progressMessage = "正在读取目录…"
        browsingTask?.cancel()
        browsingTask = Task { [weak self, service] in
            do {
                let listing = try await service.browseRemote(providerID: providerID, location: location)
                guard let self, self.requestID == token else { return }
                self.listings[listing.url] = listing
                if self.rootListingURL == nil { self.rootListingURL = listing.url }
                self.expandedURLs.insert(listing.url)
                if makesSelection {
                    self.selectedRemoteURL = listing.url
                    self.updateSuggestedDirectoryName(for: listing.url)
                }
                self.isBrowsing = false
                self.progressMessage = ""
                // 仅浏览用户最初输入的根地址成功后记忆；展开子目录不会污染地址历史。
                if makesSelection {
                    await self.recordSuccessfulRemoteUse(providerID: providerID, url: self.remoteURL,
                                                         credentials: credentials)
                }
            } catch is CancellationError {
                guard let self, self.requestID == token else { return }
                self.isBrowsing = false
                self.isCancelling = false
                self.progressMessage = ""
            } catch {
                guard let self, self.requestID == token else { return }
                self.isBrowsing = false
                self.isCancelling = false
                self.errorMessage = error.localizedDescription
                self.progressMessage = ""
            }
        }
    }

    private func invalidateRemoteTree() {
        requestID += 1
        browsingTask?.cancel()
        listings = [:]
        rootListingURL = nil
        expandedURLs = []
        selectedRemoteURL = nil
        isBrowsing = false
        isCancelling = false
        progressMessage = ""
    }

    private func clearCredentials() {
        username = ""
        password = ""
        credentialInputRevision += 1
    }

    /// 关闭窗口时清除内存中短生命周期的凭据；成功保存的历史不受影响。
    public func endSession() {
        hidePassword()
        clearCredentials()
        activeCredentialServer = nil
        requestID += 1
        credentialRequestID += 1
        credentialTask?.cancel()
        isLoadingSavedCredentials = false
    }

    private func scheduleCredentialAutofillIfNeeded() {
        let server = RemoteRepositoryHistoryStore.credentialServer(for: remoteURL)
        // 同服务器只按服务器维度读取凭据。路径编辑期间保留正在进行的读取，也不覆盖手工修改。
        if supportsCredentials, let server, activeCredentialServer == server { return }
        credentialRequestID += 1
        credentialTask?.cancel()
        isLoadingSavedCredentials = false
        let token = credentialRequestID
        guard supportsCredentials, let server else {
            activeCredentialServer = nil
            clearCredentials()
            return
        }
        // 继续编辑同一服务器内的路径时，不重新覆盖用户已编辑的账号或密码。
        guard activeCredentialServer != server else { return }
        activeCredentialServer = server
        clearCredentials()
        let inputRevision = credentialInputRevision
        let url = remoteURL
        isLoadingSavedCredentials = true
        credentialTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, let self else { return }
            do {
                let credentials = try await self.remoteHistory.credentials(for: url)
                guard !Task.isCancelled,
                      self.credentialRequestID == token,
                      self.activeCredentialServer == server,
                      self.credentialInputRevision == inputRevision,
                      RemoteRepositoryHistoryStore.credentialServer(for: self.remoteURL) == server else { return }
                self.isLoadingSavedCredentials = false
                if let credentials {
                    self.username = credentials.username
                    self.password = credentials.password
                }
            } catch {
                guard self.credentialRequestID == token else { return }
                self.isLoadingSavedCredentials = false
                self.historyNotice = "无法读取已记住的 SVN 账号：\(error.localizedDescription)"
            }
        }
    }

    private func loadSavedCredentials(username expectedUsername: String, server: String) {
        credentialRequestID += 1
        credentialTask?.cancel()
        let token = credentialRequestID
        let inputRevision = credentialInputRevision
        let url = remoteURL
        isLoadingSavedCredentials = true
        credentialTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try await self.remoteHistory.credentials(for: url, username: expectedUsername)
                guard !Task.isCancelled,
                      self.credentialRequestID == token,
                      self.activeCredentialServer == server,
                      self.credentialInputRevision == inputRevision,
                      RemoteRepositoryHistoryStore.credentialServer(for: self.remoteURL) == server else { return }
                self.isLoadingSavedCredentials = false
                if let credentials {
                    self.username = credentials.username
                    self.password = credentials.password
                }
            } catch {
                guard self.credentialRequestID == token else { return }
                self.isLoadingSavedCredentials = false
                self.historyNotice = "无法读取已记住的 SVN 账号：\(error.localizedDescription)"
            }
        }
    }

    private func recordSuccessfulRemoteUse(providerID: ProviderID, url: String,
                                           credentials: RepositoryCredentials?) async {
        let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        remoteHistory.record(providerID: providerID, url: normalized)
        guard providerID == .svn, let credentials,
              !credentials.username.isEmpty, !credentials.password.isEmpty else { return }
        do {
            try await remoteHistory.remember(credentials, for: normalized)
        } catch {
            historyNotice = "地址已记住，但无法保存 SVN 密码：\(error.localizedDescription)"
        }
    }

    private func suggestedDirectoryName(for url: String) -> String {
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var name = trimmed.split(separator: "/").last.map(String.init) ?? ""
        name = name.removingPercentEncoding ?? name
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? "working-copy" : name
    }

    private func updateSuggestedDirectoryName(for url: String) {
        guard directoryNameIsSuggested || directoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        directoryName = suggestedDirectoryName(for: url)
        directoryNameIsSuggested = true
    }
}
