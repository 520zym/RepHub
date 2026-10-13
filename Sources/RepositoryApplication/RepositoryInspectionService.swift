import Foundation
import VersionControlCore

private struct HistorySearchCursor: Codable {
    let version: Int
    let bindingID: String
    let reference: String?
    let querySignature: String
    let providerCursor: String?
    let scannedCount: Int
}

public extension RepositoryService {
    /// 逐行追溯只接受受版本控制的相对文件路径，适配器负责固定到一个提交版本。
    func blame(in binding: RepositoryBinding, path: String, reference: String? = nil) async throws -> RepositoryBlame {
        try validateManagedPath(path)
        guard let provider = try provider(for: binding) as? any RepositoryInspectionProvider else {
            throw VersionControlError.unsupported("当前版本控制来源暂不支持逐行追溯。")
        }
        try Task.checkCancellation()
        return try await provider.blame(in: binding, path: path, reference: reference)
    }

    /// 从固定的适配器历史分页中按批扫描。一次最多读取 300 条原始提交，调用方可继续到最早历史；
    /// 因此不会只过滤主界面已加载的记录，也不会一次无界加载整个仓库历史。
    func searchHistory(
        in binding: RepositoryBinding,
        query: RepositoryHistorySearchQuery,
        reference: String? = nil,
        cursor: String? = nil
    ) async throws -> RepositoryHistorySearchPage {
        let signature = historySearchSignature(query)
        let state = try decodeHistorySearchCursor(cursor, binding: binding, reference: reference, signature: signature)
        let provider = try provider(for: binding)
        let hasPath = !query.path.isEmpty
        if hasPath { try validateManagedPath(query.path) }
        if hasPath && !(provider is any RepositoryHistoryProvider) {
            throw VersionControlError.unsupported("当前版本控制来源暂不支持按文件路径检索历史。")
        }

        var providerCursor = state?.providerCursor
        var scanned = state?.scannedCount ?? 0
        var result: [Revision] = []
        var remaining = 300
        while remaining > 0 {
            try Task.checkCancellation()
            let pageLimit = min(150, remaining)
            let page: [Revision]
            let next: String?
            if hasPath, let historyProvider = provider as? any RepositoryHistoryProvider {
                let request = HistoryPageRequest(limit: pageLimit, reference: reference, cursor: providerCursor)
                let filePage: FileHistoryPage
                if let paging = historyProvider as? any RepositoryHistoryPagingProvider {
                    filePage = try await paging.fileHistoryPage(in: binding, path: query.path, request: request)
                } else if providerCursor == nil {
                    filePage = FileHistoryPage(entries: try await historyProvider.fileHistory(in: binding, path: query.path, limit: pageLimit, reference: reference))
                } else {
                    throw VersionControlError.unsupported("当前版本控制来源暂不支持继续读取更早的文件提交。")
                }
                page = filePage.entries.map(\.revision)
                next = filePage.nextCursor
            } else {
                let request = HistoryPageRequest(limit: pageLimit, reference: reference, cursor: providerCursor)
                let repositoryPage: RepositoryHistoryPage
                if let paging = provider as? any RepositoryHistoryPagingProvider {
                    repositoryPage = try await paging.historyPage(in: binding, request: request)
                } else if providerCursor == nil {
                    repositoryPage = RepositoryHistoryPage(revisions: try await provider.history(in: binding, limit: pageLimit, reference: reference))
                } else {
                    throw VersionControlError.unsupported("当前版本控制来源暂不支持继续读取更早的提交。")
                }
                page = repositoryPage.revisions
                next = repositoryPage.nextCursor
            }
            scanned += page.count
            remaining -= page.count
            result += page.filter(query.matches)
            providerCursor = next
            if next == nil || page.isEmpty { break }
        }
        let nextCursor = providerCursor.map {
            encodeHistorySearchCursor(HistorySearchCursor(
                version: 1, bindingID: binding.id, reference: normalizedSearchReference(reference),
                querySignature: signature, providerCursor: $0, scannedCount: scanned
            ))
        }
        return RepositoryHistorySearchPage(
            revisions: result, nextCursor: nextCursor, scannedCount: scanned, isComplete: nextCursor == nil
        )
    }

    private func normalizedSearchReference(_ reference: String?) -> String? {
        let value = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func historySearchSignature(_ query: RepositoryHistorySearchQuery) -> String {
        let from = query.fromDate.map { String($0.timeIntervalSince1970) } ?? ""
        let to = query.toDate.map { String($0.timeIntervalSince1970) } ?? ""
        return [query.text, query.author, query.path, from, to].joined(separator: "\u{1F}")
    }

    private func decodeHistorySearchCursor(
        _ raw: String?, binding: RepositoryBinding, reference: String?, signature: String
    ) throws -> HistorySearchCursor? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.count <= 512 * 1024,
              let data = Data(base64Encoded: raw),
              let cursor = try? JSONDecoder().decode(HistorySearchCursor.self, from: data),
              cursor.version == 1, cursor.bindingID == binding.id,
              cursor.reference == normalizedSearchReference(reference),
              cursor.querySignature == signature, cursor.scannedCount >= 0 else {
            throw VersionControlError.invalidData("历史搜索游标不属于当前仓库或查询条件，请重新搜索。")
        }
        return cursor
    }

    private func encodeHistorySearchCursor(_ cursor: HistorySearchCursor) -> String {
        // JSON 中的 providerCursor 可能来自 Git 或 SVN，仅作为不透明数据保存和回传。
        let data = (try? JSONEncoder().encode(cursor)) ?? Data()
        return data.base64EncodedString()
    }
}
