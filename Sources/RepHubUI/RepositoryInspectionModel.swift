import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

@MainActor
@Observable
final class RepositoryInspectionModel {
    enum Mode: Hashable { case blame, historySearch }

    let binding: RepositoryBinding
    let path: String?
    var mode: Mode
    var queryText = ""
    var queryAuthor = ""
    var queryPath = ""
    var useFromDate = false
    var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    var useToDate = false
    var toDate = Date.now
    private(set) var blame: RepositoryBlame?
    private(set) var blameTokens: [[SyntaxHighlighting.Token]] = []
    private(set) var searchResults: [Revision] = []
    private(set) var searchCursor: String?
    private(set) var scannedCount = 0
    private(set) var isSearchComplete = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let service: RepositoryService
    private var task: Task<Void, Never>?
    private var requestID = 0

    init(service: RepositoryService, binding: RepositoryBinding, path: String?) {
        self.service = service
        self.binding = binding
        self.path = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = path?.isEmpty == false ? .blame : .historySearch
        self.queryPath = path ?? ""
    }

    isolated deinit { task?.cancel() }

    var canBlame: Bool { path?.isEmpty == false }
    var currentQuery: RepositoryHistorySearchQuery {
        let inclusiveEnd: Date? = {
            guard useToDate else { return nil }
            let start = Calendar.current.startOfDay(for: toDate)
            return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: start)
        }()
        return RepositoryHistorySearchQuery(text: queryText, author: queryAuthor, path: queryPath,
                                     fromDate: useFromDate ? Calendar.current.startOfDay(for: fromDate) : nil,
                                     toDate: inclusiveEnd)
    }

    func loadInitial() {
        if mode == .blame { loadBlame() } else { search(reset: true) }
    }

    func selectMode(_ mode: Mode) {
        guard self.mode != mode, !isLoading else { return }
        self.mode = mode; errorMessage = nil
        if mode == .blame { loadBlame() } else { search(reset: true) }
    }

    func loadBlame() {
        guard let path, !path.isEmpty else {
            errorMessage = "请从已受版本控制的文件中打开逐行追溯。"
            return
        }
        begin { [service, binding] in
            let blame = try await service.blame(in: binding, path: path)
            let tokens = await Task.detached(priority: .userInitiated) {
                let text = blame.lines.map(\.content).joined(separator: "\n")
                guard text.utf8.count <= 524_288 else { return [[SyntaxHighlighting.Token]]() }
                return SyntaxHighlighting.tokenize(text, language: SyntaxHighlighting.language(for: path))
            }.value
            return (blame, tokens)
        } receive: { model, value in
            model.blame = value.0
            model.blameTokens = value.1
        }
    }

    func search(reset: Bool) {
        guard !isLoading else { return }
        let query = currentQuery
        let cursor = reset ? nil : searchCursor
        if !reset, cursor == nil { return }
        if reset {
            searchResults = []; searchCursor = nil; scannedCount = 0; isSearchComplete = false
        }
        begin { [service, binding] in
            try await service.searchHistory(in: binding, query: query, cursor: cursor)
        } receive: { model, page in
            if reset { model.searchResults = page.revisions }
            else { model.searchResults += page.revisions.filter { candidate in !model.searchResults.contains(where: { $0.id == candidate.id }) } }
            model.searchCursor = page.nextCursor
            model.scannedCount = page.scannedCount
            model.isSearchComplete = page.isComplete
        }
    }

    func cancel() { task?.cancel() }

    private func begin<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value,
        receive: @escaping @MainActor (RepositoryInspectionModel, Value) -> Void
    ) {
        requestID += 1
        let token = requestID
        task?.cancel(); isLoading = true; errorMessage = nil
        task = Task { [weak self] in
            do {
                let value = try await operation()
                guard !Task.isCancelled, let self, self.requestID == token else { return }
                self.isLoading = false; receive(self, value)
            } catch is CancellationError {
                guard let self, self.requestID == token else { return }
                self.isLoading = false
            } catch {
                guard !Task.isCancelled, let self, self.requestID == token else { return }
                self.isLoading = false; self.errorMessage = error.localizedDescription
            }
        }
    }
}
