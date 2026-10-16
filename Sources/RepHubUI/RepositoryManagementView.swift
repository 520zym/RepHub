import AppKit
import SwiftUI
import DesignSystem
import VersionControlCore
import RepositoryApplication

/// 仓库管理按操作语义拆分，避免把推送、分支、暂存和冲突处理混在同一张大表单中。
struct RepositoryManagementView: View {
    enum Tab: Hashable { case actions, comparison }

    @Bindable var model: RepositoryManagementModel
    let palette: AppPalette
    @Bindable var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    let dismiss: () -> Void
    let completed: @MainActor @Sendable (WorkspaceManagementResult) -> Void
    var editConflict: ((String) -> Void)? = nil
    @State private var tab: Tab = .actions
    @State private var selectedPaths = Set<String>()
    @State private var selectedConflicts = Set<String>()
    @State private var remote = ""
    @State private var remoteName = "origin"
    @State private var remoteURL = ""
    @State private var authorName = ""
    @State private var authorEmail = ""
    @State private var pushBranch = ""
    @State private var setUpstream = false
    @State private var showsPushPreview = false
    @State private var newBranch = ""
    @State private var branchStart = ""
    @State private var selectedBranch = ""
    @State private var mergeMessage = ""
    @State private var fromRevision = ""
    @State private var toRevision = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isLoading { loading }
            else if model.isExecuting { progress }
            else if let response = model.result { outcome(response) }
            else if let context = model.context { content(context) }
            else { unavailable }
        }
        .workbenchSheet(minWidth: 700, idealWidth: 820, minHeight: 520, idealHeight: 620)
        .background(palette.background).foregroundStyle(palette.text)
        .onChange(of: model.context?.stateToken) { _, _ in syncInputs() }
        .onChange(of: model.comparisonSeed) { _, _ in applyComparisonSeed() }
        .onAppear { applyComparisonSeed() }
        .interactiveDismissDisabled(model.isExecuting)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(palette.accent)
                .frame(width: 31, height: 31).background(palette.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("仓库管理").font(.system(size: 15, weight: .semibold))
                Text(model.selectedBinding?.displayLabel ?? "读取当前仓库状态")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    .help(model.selectedBinding?.root.path ?? "仓库管理")
            }
            Spacer()
            if !model.isExecuting {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18).background(palette.surface)
        .help(model.selectedBinding?.root.path ?? "仓库管理")
    }

    private func content(_ context: RepositoryManagementContext) -> some View {
        VStack(spacing: 0) {
            WorkbenchSegmentedPicker(title: "仓库管理", selection: $tab,
                                     options: [.init(.actions, "操作"), .init(.comparison, "比较")], palette: palette)
                .padding(.horizontal, 22).padding(.vertical, 14)
            if tab == .actions { actions(context) } else { comparisons(context) }
        }
    }

    private func actions(_ context: RepositoryManagementContext) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if context.binding.capabilities.contains(.conflictResolution), !context.conflicts.isEmpty { conflictSection(context) }
                if context.binding.providerID == .git { repositoryConfiguration(context) }
                if context.binding.capabilities.contains(.push) { pushSection(context) }
                if context.binding.capabilities.contains(.branchManagement) { branchSection(context) }
                if context.binding.capabilities.contains(.staging) { stagingSection(context) }
                if !hasVisibleAction(in: context) {
                    ContentUnavailableView(
                        "没有待处理冲突",
                        systemImage: "checkmark.shield",
                        description: Text("当前工作副本状态正常。可切换到“比较”查看两个修订之间的差异。")
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                }
                if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(palette.removed) }
            }
            .padding(.horizontal, 22).padding(.bottom, 22)
        }
    }

    private func repositoryConfiguration(_ context: RepositoryManagementContext) -> some View {
        section("仓库配置") {
            DisclosureGroup(context.remotes.isEmpty ? "配置首个远端" : "配置远端") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("名称，例如 origin", text: $remoteName).textFieldStyle(.plain).fieldBackground(palette)
                    TextField("远端 URL", text: $remoteURL).textFieldStyle(.plain).fieldBackground(palette)
                    Text("仅写入当前仓库的 remote 配置，不会修改全局 Git 设置。")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    HStack { Spacer(); Button("保存远端") { execute(.setRemote(name: remoteName, url: remoteURL)) }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(remoteName.isEmpty || remoteURL.isEmpty) }
                }.padding(.top, 7)
            }
            .font(.system(size: 12, weight: .medium)).tint(palette.accent)
            DisclosureGroup("提交身份") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("姓名", text: $authorName).textFieldStyle(.plain).fieldBackground(palette)
                    TextField("邮箱", text: $authorEmail).textFieldStyle(.plain).fieldBackground(palette)
                    Text("仅写入当前仓库的 user.name 和 user.email。")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    HStack { Spacer(); Button("保存身份") { execute(.setIdentity(name: authorName, email: authorEmail)) }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(authorName.isEmpty || authorEmail.isEmpty) }
                }.padding(.top, 7)
            }
            .font(.system(size: 12, weight: .medium)).tint(palette.accent)
        }
    }

    private func pushSection(_ context: RepositoryManagementContext) -> some View {
        section("推送") {
            if context.remotes.isEmpty {
                Text("先配置远端再推送。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
            } else {
                HStack(spacing: 10) {
                    Text("远端").font(.system(size: 12)).foregroundStyle(palette.secondaryText).frame(width: 64, alignment: .leading)
                    Picker("远端", selection: $remote) { ForEach(context.remotes) { Text($0.name).tag($0.name) } }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                if let endpoint = selectedRemote(in: context) {
                    Text("推送地址：\(endpoint.pushURL ?? endpoint.url)")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                        .textSelection(.enabled)
                }
                TextField("目标分支", text: $pushBranch).textFieldStyle(.plain)
                    .padding(.horizontal, 10).frame(height: 30).background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Toggle("设置为上游分支", isOn: $setUpstream).font(.system(size: 12))
                if showsPushPreview {
                    Text("将推送当前提交到 \(remote)/\(pushBranch)\(setUpstream ? "，并设置上游" : "")。实际推送地址：\(selectedRemote(in: context)?.pushURL ?? selectedRemote(in: context)?.url ?? "未配置")。请确认后执行。")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true)
                        .padding(10).background(palette.selection.opacity(0.45), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                HStack { Spacer(); Button(showsPushPreview ? "确认推送" : "查看推送目标") {
                    if showsPushPreview { execute(.push(remote: remote, branch: pushBranch, setUpstream: setUpstream)) }
                    else { showsPushPreview = true }
                }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(remote.isEmpty || pushBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }

    private func branchSection(_ context: RepositoryManagementContext) -> some View {
        section("分支与合并") {
            if context.headRevision == nil {
                Text("先完成首次提交，随后即可创建、切换或合并分支。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
            } else {
                HStack(spacing: 8) {
                    TextField("新分支名称", text: $newBranch).textFieldStyle(.plain).fieldBackground(palette)
                    TextField("起点", text: $branchStart).textFieldStyle(.plain).fieldBackground(palette)
                    Button("创建") { execute(.createBranch(name: newBranch, startPoint: branchStart)) }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(newBranch.isEmpty || branchStart.isEmpty)
                }
                if !context.branches.isEmpty {
                    HStack(spacing: 10) {
                        Text("已有分支").font(.system(size: 12)).foregroundStyle(palette.secondaryText).frame(width: 64, alignment: .leading)
                        Picker("已有分支", selection: $selectedBranch) { ForEach(context.branches) { Text($0.name).tag($0.name) } }
                            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("切换") { execute(.switchBranch(name: selectedBranch)) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(selectedBranch.isEmpty)
                        Button("合并到当前分支") { execute(.merge(reference: selectedBranch)) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(selectedBranch.isEmpty)
                    }
                }
                if context.canFinishMerge {
                    HStack {
                        TextField("合并说明", text: $mergeMessage).textFieldStyle(.plain).fieldBackground(palette)
                        Button("完成合并") { execute(.finishMerge(message: mergeMessage)) }
                            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(mergeMessage.isEmpty)
                    }
                }
            }
        }
    }

    private func stagingSection(_ context: RepositoryManagementContext) -> some View {
        section("暂存区") {
            Text("选择文件后可查看真实暂存差异。")
                .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(context.changes) { change in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { selectedPaths.contains(change.path) }, set: { selected in
                                if selected { selectedPaths.insert(change.path) } else { selectedPaths.remove(change.path) }
                            })) { Text(change.path).lineLimit(1).truncationMode(.middle) }
                                .toggleStyle(.checkbox).font(.system(size: 12))
                            if change.isStaged { Text("已暂存").font(.system(size: 10)).foregroundStyle(palette.accent) }
                            Button("差异") { model.loadStagedDiff(path: change.path) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack {
                Button("暂存所选") { execute(.stage(paths: Array(selectedPaths))) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary)).disabled(selectedPaths.isEmpty)
                Button("取消暂存") { execute(.unstage(paths: Array(selectedPaths))) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet)).disabled(selectedPaths.isEmpty)
                Spacer()
            }
            if model.isLoadingStagedPatch { ProgressView().controlSize(.small) }
            if let patch = model.stagedPatch { patchPreview(patch) }
        }
    }

    private func conflictSection(_ context: RepositoryManagementContext) -> some View {
        section("冲突") {
            Text("文本冲突可在内置编辑器中对比、编辑并保存；也可在外部处理后标记已解决。")
                .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            ForEach(context.conflicts) { conflict in
                HStack(spacing: 7) {
                    Toggle(conflict.path, isOn: Binding(get: { selectedConflicts.contains(conflict.path) }, set: { selected in
                        if selected { selectedConflicts.insert(conflict.path) } else { selectedConflicts.remove(conflict.path) }
                    }))
                    .toggleStyle(.checkbox).font(.system(size: 12)).disabled(!conflict.canMarkResolved)
                    if let editConflict {
                        Button("编辑冲突") { editConflict(conflict.path) }
                            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                    }
                    Button("外部打开") { openConflict(conflict.path) }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                }
            }
            HStack {
                Button("重新检查") { reloadContext() }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                Spacer(); Button("标记已解决") { execute(.markResolved(paths: Array(selectedConflicts))) }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(selectedConflicts.isEmpty) }
        }
    }

    private func comparisons(_ context: RepositoryManagementContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("较旧版本", text: $fromRevision).textFieldStyle(.plain).fieldBackground(palette)
                Image(systemName: "arrow.right").foregroundStyle(palette.secondaryText)
                TextField("较新版本", text: $toRevision).textFieldStyle(.plain).fieldBackground(palette)
                Button("比较") { model.compare(from: fromRevision, to: toRevision) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)).disabled(fromRevision.isEmpty || toRevision.isEmpty)
            }
            if model.isComparing { ProgressView("正在比较版本…").controlSize(.small).font(.system(size: 12)) }
            if let error = model.comparisonError { Text(error).font(.system(size: 12)).foregroundStyle(palette.removed) }
            if let comparison = model.comparison {
                Text("\(shortRevision(comparison.fromRevision)) → \(shortRevision(comparison.toRevision)) · 变更路径 \(comparison.files.count) 个")
                    .font(.system(size: 12, weight: .medium))
                    .help("完整修订：\(comparison.fromRevision) → \(comparison.toRevision)")
                HStack(spacing: 0) {
                    List(comparison.files, selection: Binding(get: { model.comparisonPath }, set: { path in if let path { model.loadComparisonDiff(path: path) } })) { file in
                        Text(file.path == "." ? "仓库根目录（属性）" : file.path)
                            .font(.system(size: 12)).lineLimit(1)
                            .help(file.path == "." ? "当前工作副本对应的仓库目录自身属性" : file.path)
                    }
                    .scrollContentBackground(.hidden)
                    .background(palette.sidebar)
                    .frame(width: 280)
                    Group { if model.isLoadingComparisonPatch { ProgressView().padding() } else if let patch = model.comparisonPatch { patchPreview(patch) } else { Text("选择一个文件查看真实差异。").font(.system(size: 12)).foregroundStyle(palette.secondaryText).padding() } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(codePalette.background)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else { Spacer() }
        }
        .padding(.horizontal, 22).padding(.bottom, 22)
    }

    private var loading: some View { VStack { Spacer(); ProgressView("正在读取仓库管理状态…"); Spacer() }.font(.system(size: 12)).frame(maxWidth: .infinity) }
    private var unavailable: some View { VStack { Spacer(); Text(model.errorMessage ?? "无法读取仓库管理状态。").font(.system(size: 12)).foregroundStyle(palette.secondaryText); Spacer() }.frame(maxWidth: .infinity) }
    private var progress: some View { VStack(alignment: .leading, spacing: 14) { RepositoryTransferProgressView(progress: model.transferProgress, palette: palette, source: model.selectedBinding?.root.path, destination: nil, isCancelling: model.isCancelling, cancelTitle: "取消操作", cancel: model.cancel, showsFileRecords: false); Text("取消不会回滚已完成的仓库步骤；结束后会重新读取状态。").font(.system(size: 11)).foregroundStyle(palette.secondaryText) }.padding(22) }
    private func outcome(_ response: WorkspaceManagementResult) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(response.result.summary, systemImage: response.result.outcome == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(response.result.outcome == .succeeded ? palette.accent : palette.removed)
                    if !response.result.details.isEmpty {
                        Text(response.result.details).font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if response.result.outcome == .unknown {
                        Text("结果尚未确认，请刷新并核对后再决定是否重试。")
                            .font(.system(size: 12)).foregroundStyle(palette.removed)
                    }
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("继续管理", action: reloadContext).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                Button("完成", action: dismiss).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(palette.surface)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchLayout.sectionGap) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WorkbenchLayout.cardInset)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkbenchLayout.cornerRadius, style: .continuous))
    }
    private func patchPreview(_ patch: RepositoryPatch) -> some View {
        HighlightedPatchPreview(text: patch.text, path: model.comparisonPath, palette: codePalette)
    }
    private var codePalette: CodePalette { appearance.codePalette(for: appearance.preferredColorScheme ?? systemColorScheme) }
    private func execute(_ action: RepositoryManagementAction) { model.execute(action, completed: completed) }
    private func openConflict(_ path: String) {
        guard let binding = model.selectedBinding else { return }
        Task {
            do {
                let url = try await WorkspaceFileService().editableFileURL(in: binding.root, path: path)
                guard model.selectedBinding?.id == binding.id else { return }
                NSWorkspace.shared.open(url)
            } catch {
                guard model.selectedBinding?.id == binding.id else { return }
                model.reportError("无法打开冲突文件：\(error.localizedDescription)")
            }
        }
    }
    private func selectedRemote(in context: RepositoryManagementContext) -> RepositoryRemote? {
        context.remotes.first { $0.name == remote }
    }
    private func shortRevision(_ value: String) -> String { value.count > 12 ? String(value.prefix(12)) : value }
    private func reloadContext() {
        guard let workspace = model.workspace, let binding = model.selectedBinding else { return }
        model.prepare(in: workspace, binding: binding)
    }
    private func hasVisibleAction(in context: RepositoryManagementContext) -> Bool {
        context.binding.providerID == .git
            || context.binding.capabilities.contains(.push)
            || context.binding.capabilities.contains(.branchManagement)
            || context.binding.capabilities.contains(.staging)
            || !context.conflicts.isEmpty
    }
    private func applyComparisonSeed() {
        guard let seed = model.comparisonSeed else { return }
        tab = .comparison
        fromRevision = seed.fromRevision ?? ""
        toRevision = seed.toRevision
    }
    private func syncInputs() { guard let context = model.context else { return }; remote = context.remotes.first?.name ?? ""; remoteName = context.remotes.first?.name ?? "origin"; remoteURL = context.remotes.first?.url ?? ""; authorName = context.authorName ?? ""; authorEmail = context.authorEmail ?? ""; pushBranch = context.binding.currentBranch; branchStart = context.headRevision ?? "HEAD"; selectedBranch = context.branches.first?.name ?? ""; fromRevision = model.comparisonSeed?.fromRevision ?? context.headRevision ?? ""; toRevision = model.comparisonSeed?.toRevision ?? context.headRevision ?? ""; selectedPaths = []; selectedConflicts = []; showsPushPreview = false }
}

private extension View {
    func fieldBackground(_ palette: AppPalette) -> some View { self.padding(.horizontal, 10).frame(height: 30).background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous)) }
}
