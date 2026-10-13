import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

@MainActor @Observable
public final class RepositoryShelfModel {
    public private(set) var preview: RepositoryShelfPreview?
    public private(set) var records: [RepositoryShelfRecord] = []
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var errorMessage: String?
    public var name = "未完成改动"
    public var includeUntracked = true
    public var mode: RepositoryShelfMode = .saveOnly

    private let service: RepositoryService
    public let binding: RepositoryBinding

    public init(service: RepositoryService, binding: RepositoryBinding) {
        self.service = service; self.binding = binding
    }

    public func load() {
        let previousMessage = message
        run { [service, binding] in try await service.shelves(in: binding) } receive: { [weak self] value in
            self?.records = value; self?.message = previousMessage
        }
    }
    public func loadThenPrepare() async {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; message = nil
        do {
            records = try await service.shelves(in: binding)
            preview = try await service.shelfPreview(in: binding, includeUntracked: includeUntracked)
        } catch is CancellationError { message = "操作已取消。" }
        catch { errorMessage = error.localizedDescription }
        isBusy = false
    }
    public func prepare() { guard !isBusy else { return }; preview = nil; run { [service, binding, includeUntracked] in try await service.shelfPreview(in: binding, includeUntracked: includeUntracked) } receive: { [weak self] value in self?.preview = value } }
    public func save() {
        guard let preview else { prepare(); return }
        run { [service, binding, name, includeUntracked, mode] in
            try await service.createShelf(in: binding, name: name, includeUntracked: includeUntracked,
                                         mode: mode, expectedStateToken: preview.stateToken)
        } receive: { [weak self] value in
            guard let self else { return }; self.message = "已保存“\(value.name)”。"; self.preview = nil; self.load()
        }
    }
    public func restore(_ record: RepositoryShelfRecord) {
        run { [service, binding] in try await service.restoreShelf(in: binding, record: record) } receive: { [weak self] result in
            self?.message = result.summary
        }
    }
    public func delete(_ record: RepositoryShelfRecord) {
        run { [service, binding] in try await service.deleteShelf(in: binding, record: record) } receive: { [weak self] _ in
            self?.message = "已删除“\(record.name)”。"; self?.load()
        }
    }

    private func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T,
                                  receive: @escaping @MainActor (T) -> Void) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; message = nil
        Task {
            do {
                let result = try await operation()
                self.isBusy = false
                receive(result)
                return
            }
            catch is CancellationError { self.message = "操作已取消。" }
            catch { self.errorMessage = error.localizedDescription }
            self.isBusy = false
        }
    }
}
