import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

@MainActor
@Observable
public final class PartialCommitModel {
    public enum Phase: Equatable { case idle, loading, ready, previewing, committing, finished, failed }

    public private(set) var phase: Phase = .idle
    public private(set) var preparation: RepositoryPartialCommitPreparation?
    public private(set) var preview: RepositoryPartialCommitPreview?
    public private(set) var result: RepositoryCommitResult?
    public private(set) var errorMessage: String?
    public var message = ""
    public private(set) var selectedLines: [String: Set<String>] = [:]
    public private(set) var wholeFiles: Set<String> = []
    public var isBusy: Bool { phase == .loading || phase == .previewing || phase == .committing }

    private let service: RepositoryService
    public let binding: RepositoryBinding
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(service: RepositoryService, binding: RepositoryBinding, path: String? = nil) {
        self.service = service; self.binding = binding
        if let path { selectedLines[path] = [] }
    }

    isolated deinit { task?.cancel() }

    public func load() {
        guard !isBusy else { return }
        generation += 1; let current = generation
        phase = .loading; preview = nil; result = nil; errorMessage = nil
        task = Task { [service, binding, weak self] in
            do {
                let prepared = try await service.preparePartialCommit(in: binding)
                guard let self, self.generation == current else { return }
                self.preparation = prepared
                if self.selectedLines.isEmpty {
                    for file in prepared.files {
                        switch file.mode {
                        case .lineSelection:
                            self.selectedLines[file.path] = Set(file.hunks.flatMap(\.lines).filter(\.selectable).map(\.id))
                        case .fileOnly:
                            break
                        }
                    }
                } else {
                    let available = Set(prepared.files.map(\.path))
                    self.selectedLines = self.selectedLines.filter { available.contains($0.key) }
                }
                self.phase = .ready
            } catch is CancellationError {
                guard let self, self.generation == current else { return }; self.phase = .idle
            } catch {
                guard let self, self.generation == current else { return }; self.errorMessage = error.localizedDescription; self.phase = .failed
            }
        }
    }

    public func isSelected(_ line: RepositoryPartialCommitLine, file: RepositoryPartialCommitFile) -> Bool {
        selectedLines[file.path]?.contains(line.id) == true
    }

    public func toggle(_ line: RepositoryPartialCommitLine, file: RepositoryPartialCommitFile) {
        guard line.selectable, !isBusy else { return }
        var lines = selectedLines[file.path] ?? []
        if lines.contains(line.id) { lines.remove(line.id) } else { lines.insert(line.id) }
        selectedLines[file.path] = lines; preview = nil
    }

    public func toggleHunk(_ hunk: RepositoryPartialCommitHunk, file: RepositoryPartialCommitFile) {
        guard !isBusy else { return }
        let ids = Set(hunk.lines.filter(\.selectable).map(\.id)); guard !ids.isEmpty else { return }
        var selected = selectedLines[file.path] ?? []
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
        selectedLines[file.path] = selected; preview = nil
    }

    public func toggleWholeFile(_ file: RepositoryPartialCommitFile) {
        guard !isBusy else { return }
        if wholeFiles.contains(file.path) { wholeFiles.remove(file.path) } else { wholeFiles.insert(file.path) }
        preview = nil
    }

    public func buildPreview() {
        guard phase == .ready, let request = request() else { return }
        generation += 1; let current = generation; phase = .previewing; errorMessage = nil
        task = Task { [service, binding, weak self] in
            do {
                let value = try await service.previewPartialCommit(request, in: binding)
                guard let self, self.generation == current else { return }; self.preview = value; self.phase = .ready
            } catch is CancellationError {
                guard let self, self.generation == current else { return }; self.phase = .ready
            } catch {
                guard let self, self.generation == current else { return }; self.errorMessage = error.localizedDescription; self.phase = .ready
            }
        }
    }

    public func commit(completed: @escaping @MainActor (RepositoryCommitResult) -> Void) {
        guard phase == .ready, preview != nil, let request = request(), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        generation += 1; let current = generation; phase = .committing; errorMessage = nil
        task = Task { [service, binding, weak self] in
            do {
                let value = try await service.commitPartial(request, in: binding, progress: { _ in })
                guard let self, self.generation == current else { return }; self.result = value; self.phase = .finished; completed(value)
            } catch is CancellationError {
                guard let self, self.generation == current else { return }; self.errorMessage = "部分提交已取消。"; self.phase = .failed
            } catch {
                guard let self, self.generation == current else { return }; self.errorMessage = error.localizedDescription; self.phase = .failed
            }
        }
    }

    public func request() -> RepositoryPartialCommitRequest? {
        guard let preparation else { return nil }
        let selections = preparation.files.compactMap { file -> RepositoryPartialCommitSelection? in
            switch file.mode {
            case .lineSelection:
                let lines = selectedLines[file.path] ?? []
                return lines.isEmpty ? nil : RepositoryPartialCommitSelection(path: file.path, fingerprint: file.fingerprint, selectedLineIDs: lines)
            case .fileOnly:
                return nil
            }
        }
        guard !selections.isEmpty else { return nil }
        return RepositoryPartialCommitRequest(bindingID: preparation.binding.id, baseRevision: preparation.baseRevision,
                                              stateToken: preparation.stateToken, selections: selections, message: message)
    }
}
