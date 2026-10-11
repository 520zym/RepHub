import Foundation

public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let git = ProviderID(rawValue: "git")
    public static let svn = ProviderID(rawValue: "svn")
}

public struct RepositoryCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let status = Self(rawValue: 1 << 0)
    public static let diff = Self(rawValue: 1 << 1)
    public static let history = Self(rawValue: 1 << 2)
    public static let branches = Self(rawValue: 1 << 3)
    public static let commitGraph = Self(rawValue: 1 << 4)
    public static let fetch = Self(rawValue: 1 << 5)
    public static let update = Self(rawValue: 1 << 6)
    public static let fileHistory = Self(rawValue: 1 << 7)
    public static let synchronization = Self(rawValue: 1 << 8)
}

public struct RepositoryBinding: Identifiable, Hashable, Sendable {
    public var id: String { providerID.rawValue + ":" + root.standardizedFileURL.path }
    public let providerID: ProviderID
    public let providerName: String
    public let root: URL
    public let currentBranch: String
    public let remoteURL: String?
    public let capabilities: RepositoryCapabilities

    public init(providerID: ProviderID, providerName: String, root: URL, currentBranch: String = "", remoteURL: String? = nil, capabilities: RepositoryCapabilities) {
        self.providerID = providerID; self.providerName = providerName; self.root = root
        self.currentBranch = currentBranch; self.remoteURL = remoteURL; self.capabilities = capabilities
    }
}

public enum FileChangeKind: String, CaseIterable, Sendable {
    case added, modified, deleted, renamed, copied, untracked, conflicted, typeChanged, unknown
    public var symbol: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .conflicted: "!"
        case .typeChanged: "T"
        case .unknown: "·"
        }
    }
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let kind: FileChangeKind
    public let isStaged: Bool
    public let isUnstaged: Bool
    public var name: String { (path as NSString).lastPathComponent }
    public init(path: String, kind: FileChangeKind, originalPath: String? = nil, isStaged: Bool = false, isUnstaged: Bool = true) {
        self.path = path; self.kind = kind; self.originalPath = originalPath
        self.isStaged = isStaged; self.isUnstaged = isUnstaged
    }
}

public struct Revision: Identifiable, Hashable, Sendable {
    public let id: String
    public let author: String
    public let date: Date
    public let message: String
    public let parents: [String]
    public let references: [String]
    public var shortID: String { id.hasPrefix("r") ? id : String(id.prefix(8)) }
    public var subject: String { message.components(separatedBy: .newlines).first ?? message }
    public init(id: String, author: String, date: Date, message: String, parents: [String] = [], references: [String] = []) {
        self.id = id; self.author = author; self.date = date; self.message = message
        self.parents = parents; self.references = references
    }
}

public struct BranchReference: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case local, remote, tag }
    public var id: String { kind.rawValue + ":" + name }
    public let name: String
    public let revisionID: String
    public let kind: Kind
    public let isCurrent: Bool
    public init(name: String, revisionID: String, kind: Kind, isCurrent: Bool = false) {
        self.name = name; self.revisionID = revisionID; self.kind = kind; self.isCurrent = isCurrent
    }
}

public struct RepositoryPatch: Sendable {
    public let text: String
    public let isTruncated: Bool
    public init(text: String, isTruncated: Bool = false) { self.text = text; self.isTruncated = isTruncated }
}

public enum VersionControlError: Error, LocalizedError, Sendable {
    case toolUnavailable(String)
    case invalidRepository(String)
    case executionFailed(String)
    case timedOut(String)
    case unsupported(String)
    case invalidData(String)
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case .toolUnavailable(let name): "未找到 \(name) 工具，请安装或检查工具路径。"
        case .invalidRepository(let detail): "无法识别工作副本：\(detail)"
        case .executionFailed(let detail): detail
        case .timedOut(let name): "\(name) 操作超时，请检查服务连接及工作区实际状态。"
        case .unsupported(let detail): detail
        case .invalidData(let detail): "无法解析版本控制数据：\(detail)"
        case .outputTooLarge: "工具输出超过读取上限，请缩小查询范围。"
        }
    }
}
