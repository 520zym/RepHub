import VersionControlCore

/// 管理动作无论成功、失败或取消，均携带重新识别后的完整工作区快照。
public struct WorkspaceManagementResult: Sendable {
    public let result: RepositoryManagementResult
    public let workspace: Workspace
    public let snapshots: [BindingSnapshot]

    public init(result: RepositoryManagementResult, workspace: Workspace, snapshots: [BindingSnapshot]) {
        self.result = result
        self.workspace = workspace
        self.snapshots = snapshots
    }
}
