import Foundation

public struct RepositorySetupOption: Identifiable, Sendable {
    public var id: ProviderID { providerID }
    public let providerID: ProviderID
    public let title: String
    public let requiresRemote: Bool
    public init(providerID: ProviderID, title: String, requiresRemote: Bool) {
        self.providerID = providerID; self.title = title; self.requiresRemote = requiresRemote
    }
}

/// 单选适配器。SVN 向明确的新远端路径导入，然后生成工作副本；原始文件需保留备份。
public struct RepositorySetupRequest: Sendable {
    public let providerID: ProviderID
    public let directory: URL
    public let remote: RemoteRepositoryLocation?
    public let message: String
    public let initialBranch: String
    public init(providerID: ProviderID, directory: URL, remote: RemoteRepositoryLocation? = nil,
                message: String = "初始化仓库", initialBranch: String = "main") {
        self.providerID = providerID; self.directory = directory; self.remote = remote
        self.message = message; self.initialBranch = initialBranch
    }
}

public struct RepositorySetupResult: Sendable {
    public let outcome: RepositoryManagementOutcome
    public let directory: URL
    public let summary: String
    public let details: String
    public let backupDirectory: URL?
    public init(outcome: RepositoryManagementOutcome, directory: URL, summary: String,
                details: String = "", backupDirectory: URL? = nil) {
        self.outcome = outcome; self.directory = directory; self.summary = summary
        self.details = details; self.backupDirectory = backupDirectory
    }
}

public protocol RepositorySetupProvider: VersionControlProvider {
    var setupOption: RepositorySetupOption { get }
    func initialize(_ request: RepositorySetupRequest,
                    progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositorySetupResult
}
