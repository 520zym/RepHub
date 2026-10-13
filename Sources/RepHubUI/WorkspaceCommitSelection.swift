import Foundation
import VersionControlCore

/// 勾选按实际工作副本路径关联，同目录的 Git/SVN 共享选择，独立工作副本互不混淆。
/// 只保存选择意图；可提交性及目录展开由各目标的提交预检确认。
struct WorkspaceCommitSelection {
    /// 选择属于工作副本根，而不是绝对文件路径。这样 `/repo` 与 `/repo/sub`
    /// 即使碰巧包含同一绝对路径，也不会把两个独立版本库当成共管目录。
    private var selectedByRoot: [String: Set<String>] = [:]
    private var knownByBinding: [String: Set<String>] = [:]
    private var rootByBinding: [String: String] = [:]

    mutating func reconcile(changes: [FileChange], in binding: RepositoryBinding) {
        let root = rootID(for: binding)
        let available = Set(changes.filter { $0.kind != .conflicted }.map(\.path))
        let otherKnown = known(in: root, excluding: binding.id)
        var selected = selectedByRoot[root] ?? []
        if let previous = knownByBinding[binding.id] {
            selected.subtract(previous.subtracting(available).subtracting(otherKnown))
        } else {
            // 第一次看到此来源时选择其变更；共管路径沿用用户已作出的勾选。
            selected.formUnion(available.subtracting(otherKnown))
        }
        selectedByRoot[root] = selected
        knownByBinding[binding.id] = available
        rootByBinding[binding.id] = root
    }

    func paths(in binding: RepositoryBinding) -> Set<String> {
        let root = rootID(for: binding)
        let selected = selectedByRoot[root] ?? []
        // 已加载目标只能得到自己已确认存在且可提交的路径；尚未读取的同根目标
        // 则可复用同一工作副本中已有来源的选择，供后续预检确认。
        let eligible = knownByBinding[binding.id] ?? known(in: root, excluding: binding.id)
        return selected.intersection(eligible)
    }

    mutating func setPaths(_ paths: Set<String>, in binding: RepositoryBinding) {
        let known = knownByBinding[binding.id] ?? []
        let root = rootID(for: binding)
        var selected = selectedByRoot[root] ?? []
        selected.subtract(known)
        selected.formUnion(paths.intersection(known))
        selectedByRoot[root] = selected
    }

    func pathsByBinding(_ bindings: [RepositoryBinding]) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: bindings.map { ($0.id, paths(in: $0)) })
    }

    func count(in bindings: [RepositoryBinding]) -> Int {
        Set(bindings.flatMap { binding in
            paths(in: binding).map { "\(rootID(for: binding))\u{1F}\($0)" }
        }).count
    }

    private func known(in root: String, excluding bindingID: String) -> Set<String> {
        knownByBinding.reduce(into: Set<String>()) { result, pair in
            guard pair.key != bindingID, rootByBinding[pair.key] == root else { return }
            result.formUnion(pair.value)
        }
    }

    private func rootID(for binding: RepositoryBinding) -> String {
        binding.root.standardizedFileURL.path
    }
}
