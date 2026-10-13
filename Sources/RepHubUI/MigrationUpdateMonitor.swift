import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

/// 仅提示“源 SVN 已出现较新修订”，不执行 update、补迁或任何工作副本写操作。
@MainActor
@Observable
public final class MigrationUpdateMonitor {
    public struct Failure: Identifiable, Equatable {
        public var id: String { directory.standardizedFileURL.path }
        public let directory: URL
        public let message: String
        public let checkedAt: Date
    }

    public private(set) var notices: [MigrationSourceUpdate] = []
    public private(set) var errors: [Failure] = []
    public private(set) var isChecking = false
    public private(set) var isPaused = true

    private let service: WorkingCopyMigrationService
    private var directories: [URL] = []
    private var canCheck: () -> Bool = { true }
    private var loopTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private let interval: Duration
    private var generation = 0
    private var userPaused = false

    public init(service: WorkingCopyMigrationService, interval: Duration = .seconds(300)) {
        self.service = service
        self.interval = interval
    }

    isolated deinit {
        loopTask?.cancel()
        checkTask?.cancel()
    }

    /// 启动五分钟轮询，调用方可用闭包在全局任务、关闭窗口等状态下跳过本轮。
    public func start(directories: [URL], canCheck: @escaping () -> Bool) {
        self.directories = Array(Set(directories.map(\.standardizedFileURL)))
        self.canCheck = canCheck
        let roots = Set(self.directories)
        notices.removeAll { !roots.contains($0.directory.standardizedFileURL) }
        errors.removeAll { !roots.contains($0.directory.standardizedFileURL) }
        loopTask?.cancel()
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
        generation += 1
        let currentGeneration = generation
        // 同目录重新接入（例如切换工作区）不能把用户明确选择的暂停重置掉。
        isPaused = userPaused
        guard !isPaused else { return }
        scheduleLoop(generation: currentGeneration, initialDelay: .seconds(0))
    }

    /// 可由设置或菜单开关调用；暂停不会清空已知提醒，恢复后立即尝试一次。
    public func setPaused(_ paused: Bool) {
        userPaused = paused
        isPaused = paused
        if paused {
            generation += 1
            loopTask?.cancel(); loopTask = nil
            checkTask?.cancel(); checkTask = nil; isChecking = false
        } else if !directories.isEmpty {
            generation += 1
            loopTask?.cancel()
            checkTask?.cancel(); checkTask = nil; isChecking = false
            scheduleLoop(generation: generation, initialDelay: .seconds(0))
        }
    }

    public func resume() { setPaused(false) }

    private func scheduleLoop(generation expectedGeneration: Int, initialDelay: Duration) {
        loopTask = Task { [weak self] in
            if initialDelay > .zero {
                do { try await Task.sleep(for: initialDelay) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.checkNow(expectedGeneration: expectedGeneration)
            while !Task.isCancelled {
                do { try await Task.sleep(for: self.interval) } catch { return }
                guard !Task.isCancelled else { return }
                self.checkNow(expectedGeneration: expectedGeneration)
            }
        }
    }

    /// 暂停自动检查；已发起的只读查询也会被取消。
    public func stop() {
        generation += 1
        loopTask?.cancel(); loopTask = nil
        checkTask?.cancel(); checkTask = nil
        isChecking = false
        isPaused = true
        notices = []
        errors = []
        directories = []
    }

    /// 手动触发一次。无迁移记录、全局繁忙或其他迁移任务繁忙都安静跳过。
    public func checkNow() {
        checkNow(expectedGeneration: generation)
    }

    private func checkNow(expectedGeneration: Int) {
        guard expectedGeneration == generation, !isChecking, !directories.isEmpty else { return }
        // 应用刚启动时 workspace 仍在加载很常见；2 秒后重试，不必等完整的五分钟周期。
        guard canCheck() else {
            scheduleInitialRetry(generation: expectedGeneration)
            return
        }
        isChecking = true
        let directories = self.directories
        let service = self.service
        checkTask = Task { [weak self] in
            var updates: [MigrationSourceUpdate] = []
            var failures: [Failure] = []
            var resolvedDirectories: [URL] = []
            for directory in directories {
                guard !Task.isCancelled else { return }
                do {
                    switch try await service.checkForSourceUpdates(at: directory) {
                    case .update(let update):
                        updates.append(update)
                    case .noMigrationRecord, .current:
                        resolvedDirectories.append(directory)
                    case .skippedBusy:
                        break
                    }
                } catch is CancellationError {
                    return
                } catch {
                    failures.append(Failure(directory: directory, message: error.localizedDescription, checkedAt: Date()))
                }
            }
            guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
            self.merge(updates: updates, resolvedDirectories: resolvedDirectories, failures: failures)
            self.isChecking = false
            self.checkTask = nil
        }
    }

    private func scheduleInitialRetry(generation expectedGeneration: Int) {
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == expectedGeneration,
                  !self.isPaused else { return }
            self.checkNow(expectedGeneration: expectedGeneration)
        }
    }

    private func merge(updates: [MigrationSourceUpdate], resolvedDirectories: [URL], failures: [Failure]) {
        for directory in resolvedDirectories {
            notices.removeAll { $0.directory.standardizedFileURL == directory.standardizedFileURL }
            errors.removeAll { $0.directory.standardizedFileURL == directory.standardizedFileURL }
        }
        for update in updates {
            notices.removeAll { $0.directory.standardizedFileURL == update.directory.standardizedFileURL }
            errors.removeAll { $0.directory.standardizedFileURL == update.directory.standardizedFileURL }
            notices.append(update)
        }
        for failure in failures {
            errors.removeAll { $0.directory.standardizedFileURL == failure.directory.standardizedFileURL }
            errors.append(failure)
        }
        notices.sort { $0.checkedAt > $1.checkedAt }
        errors.sort { $0.checkedAt > $1.checkedAt }
    }
}
