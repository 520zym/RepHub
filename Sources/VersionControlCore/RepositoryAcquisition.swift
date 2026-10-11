import Foundation

/// 获取尚未存在的工作副本，与已有工作副本的更新契约分离。
public protocol RepositoryAcquisitionProvider: VersionControlProvider {
    var acquisitionOption: RepositoryAcquisitionOption { get }
    func browseRemote(_ location: RemoteRepositoryLocation) async throws -> RemoteDirectoryListing
    /// destination 由业务层保留在独立暂存目录内，适配器不得写入其他本地位置。
    func acquire(_ location: RemoteRepositoryLocation, to destination: URL,
                 progress: @escaping RepositoryOperationProgressHandler) async throws
}

public extension RepositoryAcquisitionProvider {
    func browseRemote(_ location: RemoteRepositoryLocation) async throws -> RemoteDirectoryListing {
        throw VersionControlError.unsupported("此版本控制方式不支持远端目录浏览。")
    }
}

public struct RepositoryAcquisitionOption: Identifiable, Sendable {
    public var id: ProviderID { providerID }
    public let providerID: ProviderID
    public let title: String
    public let actionTitle: String
    public let supportsBrowsing: Bool
    public let supportsCredentials: Bool
    public init(providerID: ProviderID, title: String, actionTitle: String,
                supportsBrowsing: Bool = false, supportsCredentials: Bool = false) {
        self.providerID = providerID; self.title = title; self.actionTitle = actionTitle
        self.supportsBrowsing = supportsBrowsing; self.supportsCredentials = supportsCredentials
    }
}

/// 仅在本次应用会话内使用，不编码、不写入配置或命令行参数。
public struct RepositoryCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let username: String
    public let password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
    public var description: String { "RepositoryCredentials(<redacted>)" }
    public var debugDescription: String { description }
}

public struct RemoteRepositoryLocation: Sendable {
    public let url: String
    public let credentials: RepositoryCredentials?
    public init(url: String, credentials: RepositoryCredentials? = nil) {
        self.url = url; self.credentials = credentials
    }
}

public struct RemoteDirectoryEntry: Identifiable, Hashable, Sendable {
    public var id: String { url }
    public let name: String
    public let url: String
    public let isDirectory: Bool
    public init(name: String, url: String, isDirectory: Bool) {
        self.name = name; self.url = url; self.isDirectory = isDirectory
    }
}

public struct RemoteDirectoryListing: Sendable {
    public let url: String
    public let entries: [RemoteDirectoryEntry]
    public init(url: String, entries: [RemoteDirectoryEntry]) { self.url = url; self.entries = entries }
}

public struct RepositoryAcquisitionResult: Sendable {
    public let outcome: RepositoryOperationOutcome
    public let destination: URL
    public let partialDirectory: URL?
    public let summary: String
    public let details: String
    public init(outcome: RepositoryOperationOutcome, destination: URL, partialDirectory: URL? = nil,
                summary: String, details: String = "") {
        self.outcome = outcome; self.destination = destination; self.partialDirectory = partialDirectory
        self.summary = summary; self.details = details
    }
}
