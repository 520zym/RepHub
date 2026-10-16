import Foundation
import VersionControlCore

/// 搁置的业务入口。具体 Git stash 或 SVN 本地快照只留在适配器层。
public extension RepositoryService {
    func shelfPreview(in binding: RepositoryBinding, includeUntracked: Bool) async throws -> RepositoryShelfPreview {
        guard !isPerformingOperation else { throw VersionControlError.unsupported("已有仓库操作正在执行，请稍后再试。") }
        guard let adapter = try provider(for: binding) as? any RepositoryShelfProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持搁置。")
        }
        guard let current = try await adapter.detect(at: binding.root), current.id == binding.id,
              current.currentBranch == binding.currentBranch, current.remoteURL == binding.remoteURL else {
            throw VersionControlError.invalidRepository("仓库位置、分支或远端已经改变，请刷新后重新操作。")
        }
        return try await adapter.shelfPreview(in: current, includeUntracked: includeUntracked)
    }

    func shelves(in binding: RepositoryBinding) async throws -> [RepositoryShelfRecord] {
        guard !isPerformingOperation else { throw VersionControlError.unsupported("已有仓库操作正在执行，请稍后再试。") }
        guard let adapter = try provider(for: binding) as? any RepositoryShelfProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持搁置。")
        }
        guard let current = try await adapter.detect(at: binding.root), current.id == binding.id else {
            throw VersionControlError.invalidRepository("仓库位置已改变，请刷新后重新操作。")
        }
        return try await adapter.shelves(in: current)
    }

    func createShelf(in binding: RepositoryBinding, name: String, includeUntracked: Bool,
                     mode: RepositoryShelfMode, expectedStateToken: String) async throws -> RepositoryShelfRecord {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.createShelfUnlocked(in: binding, name: name, includeUntracked: includeUntracked,
                                               mode: mode, expectedStateToken: expectedStateToken)
        }
    }

    private func createShelfUnlocked(in binding: RepositoryBinding, name: String, includeUntracked: Bool,
                                     mode: RepositoryShelfMode, expectedStateToken: String) async throws -> RepositoryShelfRecord {
        try validateShelfName(name)
        guard !isPerformingOperation else { throw VersionControlError.unsupported("已有仓库操作正在执行，请稍后再试。") }
        guard let adapter = try provider(for: binding) as? any RepositoryShelfProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持搁置。")
        }
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        guard let current = try await adapter.detect(at: binding.root), current.id == binding.id,
              current.currentBranch == binding.currentBranch, current.remoteURL == binding.remoteURL else {
            throw VersionControlError.invalidRepository("仓库位置、分支或远端已经改变，请刷新后重新操作。")
        }
        let preview = try await adapter.shelfPreview(in: current, includeUntracked: includeUntracked)
        guard preview.stateToken == expectedStateToken else {
            throw VersionControlError.invalidRepository("工作区修改已变化，请重新查看搁置预览。")
        }
        return try await adapter.createShelf(in: current, name: name, includeUntracked: includeUntracked,
                                             mode: mode, expectedStateToken: expectedStateToken)
    }

    func restoreShelf(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws -> RepositoryShelfRestoreResult {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.restoreShelfUnlocked(in: binding, record: record)
        }
    }

    private func restoreShelfUnlocked(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws -> RepositoryShelfRestoreResult {
        guard record.providerID == binding.providerID else { throw VersionControlError.invalidRepository("搁置记录与当前仓库类型不一致。") }
        guard !isPerformingOperation else { throw VersionControlError.unsupported("已有仓库操作正在执行，请稍后再试。") }
        guard let adapter = try provider(for: binding) as? any RepositoryShelfProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持搁置。")
        }
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        guard let current = try await adapter.detect(at: binding.root), current.id == binding.id,
              current.currentBranch == binding.currentBranch, current.remoteURL == binding.remoteURL else {
            throw VersionControlError.invalidRepository("仓库位置、分支或远端已经改变，请刷新后重新操作。")
        }
        return try await adapter.restoreShelf(in: current, record: record)
    }

    func deleteShelf(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.deleteShelfUnlocked(in: binding, record: record)
        }
    }

    private func deleteShelfUnlocked(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws {
        guard record.providerID == binding.providerID else { throw VersionControlError.invalidRepository("搁置记录与当前仓库类型不一致。") }
        guard !isPerformingOperation else { throw VersionControlError.unsupported("已有仓库操作正在执行，请稍后再试。") }
        guard let adapter = try provider(for: binding) as? any RepositoryShelfProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持搁置。")
        }
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        guard let current = try await adapter.detect(at: binding.root), current.id == binding.id else {
            throw VersionControlError.invalidRepository("仓库位置已改变，请刷新后重新操作。")
        }
        try await adapter.deleteShelf(in: current, record: record)
    }

    private func validateShelfName(_ name: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw VersionControlError.invalidRepository("请输入不超过 512 字节的搁置名称。")
        }
    }
}
