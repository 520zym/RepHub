import SwiftUI
import Observation
import DesignSystem
import RepositoryApplication
import VersionControlCore

@MainActor
@Observable
public final class IgnoreRuleModel {
    public enum Phase: Equatable { case idle, loading, ready, previewing, applying, finished, failed }
    public private(set) var phase: Phase = .idle
    public private(set) var preparation: RepositoryIgnorePreparation?
    public private(set) var preview: RepositoryIgnorePreview?
    public private(set) var result: RepositoryIgnoreResult?
    public private(set) var errorMessage: String?
    private var previewToken: String?
    public var selectedPath: String?
    public var rule = ""
    public var scope: RepositoryIgnoreScope = .currentDirectory
    public var isBusy: Bool { phase == .loading || phase == .previewing || phase == .applying }
    private let service: RepositoryService
    public let binding: RepositoryBinding
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(service: RepositoryService, binding: RepositoryBinding, path: String? = nil) {
        self.service = service; self.binding = binding; self.selectedPath = path
    }
    isolated deinit { task?.cancel() }
    public var selectedCandidate: RepositoryIgnoreCandidate? { preparation?.candidates.first { $0.path == selectedPath } }

    public func load() {
        guard !isBusy else { return }; generation += 1; let current = generation; phase = .loading; preview = nil; errorMessage = nil
        task = Task { [service, binding, weak self] in
            do {
                let value = try await service.prepareIgnore(in: binding)
                guard let self, self.generation == current else { return }
                self.preparation = value
                if self.selectedCandidate == nil { self.selectedPath = value.candidates.first?.path }
                if let candidate = self.selectedCandidate { self.scope = candidate.scopes.contains(.currentDirectory) ? .currentDirectory : .repository; self.rule = self.defaultRule(for: candidate, scope: self.scope) }
                self.phase = .ready
            } catch is CancellationError { guard let self, self.generation == current else { return }; self.phase = .idle }
            catch { guard let self, self.generation == current else { return }; self.errorMessage = error.localizedDescription; self.phase = .failed }
        }
    }
    public func select(_ candidate: RepositoryIgnoreCandidate) { guard !isBusy else { return }; selectedPath = candidate.path; scope = candidate.scopes.contains(.currentDirectory) ? .currentDirectory : .repository; rule = defaultRule(for: candidate, scope: scope); preview = nil; previewToken = nil; errorMessage = nil }
    public func setScope(_ value: RepositoryIgnoreScope) {
        guard !isBusy, let candidate = selectedCandidate else { return }
        scope = value; rule = defaultRule(for: candidate, scope: value); preview = nil; previewToken = nil
    }
    public func request() -> RepositoryIgnoreRequest? {
        guard let candidate = selectedCandidate else { return nil }
        return RepositoryIgnoreRequest(bindingID: binding.id, candidate: candidate, rule: rule, scope: scope, previewToken: previewToken)
    }
    public func buildPreview() {
        guard phase == .ready, let request = request() else { return }; generation += 1; let current = generation; phase = .previewing; errorMessage = nil
        task = Task { [service, binding, weak self] in
            do { let value = try await service.previewIgnore(request, in: binding); guard let self, self.generation == current else { return }; self.preview = value; self.previewToken = value.stateToken; self.phase = .ready }
            catch is CancellationError { guard let self, self.generation == current else { return }; self.phase = .ready }
            catch { guard let self, self.generation == current else { return }; self.errorMessage = error.localizedDescription; self.phase = .ready }
        }
    }
    private func defaultRule(for candidate: RepositoryIgnoreCandidate, scope: RepositoryIgnoreScope) -> String {
        scope == .currentDirectory ? (candidate.defaultRule.split(separator: "/").last.map(String.init) ?? candidate.defaultRule) : candidate.defaultRule
    }
    public func apply(completed: @escaping @MainActor (RepositoryIgnoreResult) -> Void) {
        guard phase == .ready, let request = request() else { return }; generation += 1; let current = generation; phase = .applying; errorMessage = nil
        task = Task { [service, binding, weak self] in
            do { let value = try await service.applyIgnore(request, in: binding, progress: { _ in }); guard let self, self.generation == current else { return }; self.result = value; self.phase = .finished; completed(value) }
            catch is CancellationError { guard let self, self.generation == current else { return }; self.errorMessage = "添加忽略规则已取消。"; self.phase = .failed }
            catch { guard let self, self.generation == current else { return }; self.errorMessage = error.localizedDescription; self.phase = .failed }
        }
    }
}

public struct IgnoreRuleView: View {
    @Bindable private var model: IgnoreRuleModel
    private let palette: AppPalette
    private let dismiss: () -> Void
    private let completed: @MainActor (RepositoryIgnoreResult) -> Void
    private let onBusyChange: ((Bool) -> Void)?

    public init(model: IgnoreRuleModel, palette: AppPalette, dismiss: @escaping () -> Void,
                completed: @escaping @MainActor (RepositoryIgnoreResult) -> Void = { _ in },
                onBusyChange: ((Bool) -> Void)? = nil) {
        self.model = model; self.palette = palette; self.dismiss = dismiss; self.completed = completed; self.onBusyChange = onBusyChange
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 3) { Text("添加忽略规则").font(.headline); Text("规则只写入本地工作副本，不会自动提交。 ").font(.caption).foregroundStyle(palette.secondaryText) }; Spacer(); Button("关闭", action: dismiss).disabled(model.isBusy) }
                .padding(18).background(palette.surface)
            switch model.phase {
            case .loading: ProgressView("正在读取未跟踪文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed: ContentUnavailableView("无法添加忽略规则", systemImage: "exclamationmark.triangle", description: Text(model.errorMessage ?? "请刷新后重试。"))
            default: editor
            }
        }.frame(width: 680, height: 460).background(palette.background).foregroundStyle(palette.text)
            .task { model.load() }.onChange(of: model.isBusy, initial: true) { _, busy in onBusyChange?(busy) }
    }
    private var editor: some View {
        HStack(spacing: 0) {
            List(model.preparation?.candidates ?? [], id: \.path, selection: $model.selectedPath) { candidate in
                Button { model.select(candidate) } label: { Text(candidate.path).font(.system(.caption, design: .monospaced)) }.buttonStyle(.plain)
            }.frame(width: 250)
            Divider().opacity(0.25)
            VStack(alignment: .leading, spacing: 13) {
                Text(model.preparation?.notice ?? "").font(.caption).foregroundStyle(palette.secondaryText)
                TextField("忽略规则", text: $model.rule).textFieldStyle(.roundedBorder)
                if let candidate = model.selectedCandidate {
                    Picker("作用范围", selection: Binding(get: { model.scope }, set: { model.setScope($0) })) { ForEach(Array(candidate.scopes), id: \.self) { scope in Text(scope.title).tag(scope) } }.pickerStyle(.segmented)
                }
                if model.phase == .previewing { ProgressView("正在生成写入预览…") }
                else if let preview = model.preview {
                    Text(preview.targetDescription).font(.caption.weight(.semibold))
                    Text(preview.after.isEmpty ? "（将清空规则）" : preview.after).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8).background(palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else { Spacer() }
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                HStack { Spacer(); Button("预览") { model.buildPreview() }.disabled(model.isBusy || model.request() == nil); Button("写入规则") { model.apply(completed: completed) }.buttonStyle(.borderedProminent).disabled(model.isBusy || model.request() == nil) }
            }.padding(18)
        }
    }
}
