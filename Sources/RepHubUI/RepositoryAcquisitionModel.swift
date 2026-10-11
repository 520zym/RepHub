import AppKit
import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

/// 新建工作副本的短生命周期状态。输入认证信息只保留在内存中，不写入界面设置或磁盘。
@MainActor
@Observable
public final class RepositoryAcquisitionModel {
    public private(set) var options: [RepositoryAcquisitionOption] = []
    public var selectedProviderID: ProviderID?
    public var remoteURL = ""
    public var username = ""
    public var password = ""
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
    public private(set) var result: RepositoryAcquisitionResult?
    public private(set) var errorMessage: String?

    private let service: RepositoryService
    private var browsingTask: Task<Void, Never>?
    private var acquisitionTask: Task<Void, Never>?
    private var requestID = 0
    private var directoryNameIsSuggested = true

    public init(service: RepositoryService) {
        self.service = service
    }

    isolated deinit {
        browsingTask?.cancel()
        acquisitionTask?.cancel()
    }

    public var selectedOption: RepositoryAcquisitionOption? {
        options.first { $0.providerID == selectedProviderID }
    }

    public var supportsBrowsing: Bool { selectedOption?.supportsBrowsing == true }
    public var supportsCredentials: Bool { selectedOption?.supportsCredentials == true }
    public var isBusy: Bool { isBrowsing || isAcquiring }
    public var destinationURL: URL? {
        guard let destinationParent, !directoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return destinationParent.appendingPathComponent(directoryName.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
    }

    public func prepare() {
        guard options.isEmpty, !isLoadingOptions else { return }
        isLoadingOptions = true
        Task { [weak self, service] in
            let options = await service.acquisitionOptions()
            guard let self else { return }
            self.options = options
            self.selectedProviderID = self.selectedProviderID ?? options.first?.providerID
            self.isLoadingOptions = false
        }
    }

    public func selectProvider(_ providerID: ProviderID) {
        guard selectedProviderID != providerID else { return }
        selectedProviderID = providerID
        invalidateRemoteTree()
    }

    /// URL 与身份信息都会影响 SVN 服务端可见目录，因此不能继续使用此前读取的树。
    public func remoteLocationChanged() {
        invalidateRemoteTree()
        result = nil
        errorMessage = nil
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
        selectedRemoteURL = entry.url
        updateSuggestedDirectoryName(for: entry.url)
        if expandedURLs.contains(entry.url) {
            expandedURLs.remove(entry.url)
        } else if listings[entry.url] != nil {
            expandedURLs.insert(entry.url)
        } else {
            browse(url: entry.url, providerID: selectedProviderID, makesSelection: true)
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
        isAcquiring = true
        isCancelling = false
        progressMessage = "正在准备\(option.actionTitle)…"
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
                    }
                }
                guard let self, self.requestID == token else { return }
                self.isAcquiring = false
                self.isCancelling = false
                self.result = result
                self.progressMessage = result.summary
                if case .succeeded = result.outcome {
                    self.clearCredentials()
                    onSuccess(result.destination)
                }
            } catch is CancellationError {
                guard let self, self.requestID == token else { return }
                self.isAcquiring = false
                self.isCancelling = false
                self.errorMessage = "已取消，正在保留已产生的临时目录供检查。"
            } catch {
                guard let self, self.requestID == token else { return }
                self.isAcquiring = false
                self.isCancelling = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func cancel() {
        guard isBusy, !isCancelling else { return }
        isCancelling = true
        progressMessage = isAcquiring ? "正在取消并保留已下载内容…" : "正在取消目录读取…"
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
        username = ""
        password = ""
        destinationParent = nil
        directoryName = ""
        directoryNameIsSuggested = true
        invalidateRemoteTree()
        result = nil
        errorMessage = nil
        progressMessage = ""
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
