import Foundation
import VersionControlCore

/// 每次弹窗固定来源与路径，后续读写不能被后台选择变化重新指向。
struct WorkspaceToolRequest: Identifiable {
    enum Kind { case inspection, shelves, conflict, partialCommit, ignore }
    let id = UUID()
    let kind: Kind
    let binding: RepositoryBinding
    let path: String?
}
