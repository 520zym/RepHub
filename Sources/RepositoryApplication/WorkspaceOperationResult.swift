import Foundation
import VersionControlCore

/// 操作结果与实际重新读取的工作区分开保存；失败或取消并不代表文件没有变化。
public struct WorkspaceOperationResult: Sendable {
    public let result: RepositoryOperationResult
    public let workspace: Workspace
    public let snapshots: [BindingSnapshot]

    public init(result: RepositoryOperationResult, workspace: Workspace, snapshots: [BindingSnapshot]) {
        self.result = result; self.workspace = workspace; self.snapshots = snapshots
    }
}
