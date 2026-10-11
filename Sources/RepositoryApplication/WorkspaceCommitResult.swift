import VersionControlCore

public struct WorkspaceCommitResult: Sendable {
    public let results: [RepositoryCommitResult]
    public let workspace: Workspace
    public let snapshots: [BindingSnapshot]
    public init(results: [RepositoryCommitResult], workspace: Workspace, snapshots: [BindingSnapshot]) {
        self.results = results; self.workspace = workspace; self.snapshots = snapshots
    }
}
