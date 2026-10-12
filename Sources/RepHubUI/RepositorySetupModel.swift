import AppKit
import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

/// 未受版本控制文件夹的初始化状态。认证信息仅在本次初始化任务中保留于内存。
@MainActor
@Observable
public final class RepositorySetupModel {
    public private(set) var options: [RepositorySetupOption] = []
    public var selectedProviderID: ProviderID?
    public var directory: URL?
    public var remoteURL = ""
    public var username = ""
    public var password = ""
    public var message = "初始化仓库"
    public var initialBranch = "main"
    public private(set) var isLoadingOptions = false
    public private(set) var isExecuting = false
    public private(set) var isCancelling = false
    public private(set) var progressMessage = ""
    public let transferProgress = TransferProgressState()
    public private(set) var result: RepositorySetupResult?
    public private(set) var errorMessage: String?

    private let service: RepositoryService
    private var task: Task<Void, Never>?
    private var optionsTask: Task<Void, Never>?
    private var requestID = 0

    public init(service: RepositoryService) { self.service = service }

    isolated deinit { task?.cancel(); optionsTask?.cancel() }

    public var selectedOption: RepositorySetupOption? {
        options.first { $0.providerID == selectedProviderID }
    }

    public var requiresRemote: Bool { selectedOption?.requiresRemote == true }
    public var isBusy: Bool { isLoadingOptions || isExecuting }

    public func prepare(directory: URL) {
        guard !isExecuting else { return }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        result = nil
        errorMessage = nil
        guard options.isEmpty, !isLoadingOptions else { return }
        requestID += 1
        let token = requestID
        isLoadingOptions = true
        optionsTask?.cancel()
        optionsTask = Task { [weak self, service] in
            let options = await service.setupOptions()
            guard let self, self.requestID == token else { return }
            self.options = options
            self.selectedProviderID = self.selectedProviderID ?? options.first?.providerID
            self.isLoadingOptions = false
        }
    }

    public func selectProvider(_ providerID: ProviderID) {
        guard !isExecuting, selectedProviderID != providerID else { return }
        selectedProviderID = providerID
        result = nil
        errorMessage = nil
    }

    public func chooseDirectory() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要初始化的文件夹"
        panel.message = "此文件夹必须尚未受 Git 或 SVN 管理"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepare(directory: url)
    }

    public func initialize() {
        guard !isBusy, let directory, let providerID = selectedProviderID else { return }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            errorMessage = "请填写初始化说明。"
            return
        }
        let remote: RemoteRepositoryLocation?
        if requiresRemote {
            let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                errorMessage = "请填写新的 SVN 仓库地址。"
                return
            }
            let credentials = (!username.isEmpty || !password.isEmpty)
                ? RepositoryCredentials(username: username, password: password) : nil
            remote = RemoteRepositoryLocation(url: url, credentials: credentials)
        } else {
            remote = nil
        }
        let branch = initialBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requiresRemote, branch.isEmpty {
            errorMessage = "请填写 Git 初始分支名称。"
            return
        }

        requestID += 1
        let token = requestID
        let request = RepositorySetupRequest(providerID: providerID, directory: directory, remote: remote,
                                             message: trimmedMessage, initialBranch: branch)
        isExecuting = true
        isCancelling = false
        result = nil
        errorMessage = nil
        progressMessage = "正在准备初始化…"
        transferProgress.begin(progressMessage)
        task = Task { [weak self, service] in
            do {
                let result = try await service.initialize(request) { progress in
                    await MainActor.run {
                        guard let self, self.requestID == token else { return }
                        self.progressMessage = progress.message
                        self.transferProgress.consume(progress)
                    }
                }
                guard let self, self.requestID == token else { return }
                self.isExecuting = false
                self.isCancelling = false
                self.result = result
                self.progressMessage = result.summary
                self.transferProgress.finish(result.summary)
                if result.outcome == .succeeded {
                    self.password = ""
                }
            } catch is CancellationError {
                guard let self, self.requestID == token else { return }
                self.isExecuting = false
                self.isCancelling = false
                self.errorMessage = "初始化已取消，请重新打开文件夹核对状态。"
                self.transferProgress.finish("初始化已取消")
            } catch {
                guard let self, self.requestID == token else { return }
                self.isExecuting = false
                self.isCancelling = false
                self.errorMessage = error.localizedDescription
                self.transferProgress.finish("初始化未完成")
            }
        }
    }

    public func cancel() {
        guard isExecuting, !isCancelling else { return }
        isCancelling = true
        progressMessage = "正在取消并等待版本控制工具返回状态…"
        transferProgress.consume(RepositoryOperationProgress(progressMessage))
        task?.cancel()
    }

    public func dismiss() {
        guard !isExecuting else { return }
        requestID += 1
        task?.cancel()
        optionsTask?.cancel()
        result = nil
        errorMessage = nil
        progressMessage = ""
        username = ""
        password = ""
        transferProgress.clear()
    }
}
