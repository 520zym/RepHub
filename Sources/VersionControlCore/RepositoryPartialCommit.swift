import Foundation

/// Git 的部分提交预览。该对象保存的是适配器生成的补丁选择，不让界面解释 Git index。
public struct RepositoryPartialCommitLine: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case context, addition, deletion }

    public let id: String
    public let text: String
    public let kind: Kind
    /// 上下文行只用于补丁定位，不能单独勾选。
    public let selectable: Bool

    public init(id: String, text: String, kind: Kind, selectable: Bool) {
        self.id = id; self.text = text; self.kind = kind; self.selectable = selectable
    }
}

public struct RepositoryPartialCommitHunk: Identifiable, Hashable, Sendable {
    public let id: String
    public let header: String
    public let lines: [RepositoryPartialCommitLine]
    public init(id: String, header: String, lines: [RepositoryPartialCommitLine]) {
        self.id = id; self.header = header; self.lines = lines
    }
}

public enum RepositoryPartialCommitMode: Sendable, Equatable {
    case lineSelection
    /// 新增、删除、改名、二进制等不能可靠拆行时，仍可明确选择整个文件。
    case fileOnly(reason: String)
}

public struct RepositoryPartialCommitFile: Identifiable, Sendable {
    public let path: String
    public var id: String { path }
    public let fingerprint: String
    public let mode: RepositoryPartialCommitMode
    public let hunks: [RepositoryPartialCommitHunk]
    public let fullPatch: RepositoryPatch

    public init(path: String, fingerprint: String, mode: RepositoryPartialCommitMode,
                hunks: [RepositoryPartialCommitHunk], fullPatch: RepositoryPatch) {
        self.path = path; self.fingerprint = fingerprint; self.mode = mode; self.hunks = hunks; self.fullPatch = fullPatch
    }
}

public struct RepositoryPartialCommitPreparation: Sendable {
    public let binding: RepositoryBinding
    public let baseRevision: String?
    public let stateToken: String
    public let files: [RepositoryPartialCommitFile]
    public let notice: String
    public init(binding: RepositoryBinding, baseRevision: String?, stateToken: String,
                files: [RepositoryPartialCommitFile], notice: String) {
        self.binding = binding; self.baseRevision = baseRevision; self.stateToken = stateToken
        self.files = files; self.notice = notice
    }
}

/// `selectedLineIDs` 只包含变更行；空集合表示该文件不会进入提交。
public struct RepositoryPartialCommitSelection: Hashable, Sendable {
    public let path: String
    public let fingerprint: String
    public let selectedLineIDs: Set<String>
    public let selectWholeFile: Bool
    public init(path: String, fingerprint: String, selectedLineIDs: Set<String> = [], selectWholeFile: Bool = false) {
        self.path = path; self.fingerprint = fingerprint
        self.selectedLineIDs = selectedLineIDs; self.selectWholeFile = selectWholeFile
    }
}

public struct RepositoryPartialCommitRequest: Sendable {
    public let bindingID: String
    public let baseRevision: String?
    public let stateToken: String
    public let selections: [RepositoryPartialCommitSelection]
    public let message: String
    public init(bindingID: String, baseRevision: String?, stateToken: String,
                selections: [RepositoryPartialCommitSelection], message: String) {
        self.bindingID = bindingID; self.baseRevision = baseRevision; self.stateToken = stateToken
        self.selections = selections; self.message = message
    }
}

public struct RepositoryPartialCommitPreview: Sendable {
    public let patch: RepositoryPatch
    public let selectedPaths: [String]
    public init(patch: RepositoryPatch, selectedPaths: [String]) {
        self.patch = patch; self.selectedPaths = selectedPaths
    }
}

public protocol RepositoryPartialCommitProvider: VersionControlProvider {
    func preparePartialCommit(in binding: RepositoryBinding) async throws -> RepositoryPartialCommitPreparation
    func previewPartialCommit(_ request: RepositoryPartialCommitRequest, in binding: RepositoryBinding) async throws -> RepositoryPartialCommitPreview
    func commitPartial(_ request: RepositoryPartialCommitRequest, in binding: RepositoryBinding,
                       progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryCommitResult
}
