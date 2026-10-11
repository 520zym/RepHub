import SwiftUI
import DesignSystem
import VersionControlCore

/// 写操作入口刻意只提供一个目标选择，避免双版本控制工作区出现不透明的并行更新。
struct RepositoryOperationView: View {
    @Bindable var model: WorkspaceModel
    let palette: AppPalette
    let dismiss: () -> Void

    @State private var selectedBindingID: String
    @State private var selectedKind: RepositoryOperationKind

    init(model: WorkspaceModel, palette: AppPalette, dismiss: @escaping () -> Void) {
        self.model = model
        self.palette = palette
        self.dismiss = dismiss
        let firstBinding = model.selectedBinding ?? model.workspace?.bindings.first
        _selectedBindingID = State(initialValue: firstBinding?.id ?? "")
        _selectedKind = State(initialValue: firstBinding?.capabilities.contains(.update) == true ? .update : .fetch)
    }

    private var bindings: [RepositoryBinding] { model.workspace?.bindings ?? [] }
    private var selectedBinding: RepositoryBinding? { bindings.first { $0.id == selectedBindingID } }
    private var supportedKinds: [RepositoryOperationKind] {
        guard let selectedBinding else { return [] }
        return RepositoryOperationKind.allCases.filter { model.supports($0, for: selectedBinding) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isOperationInProgress {
                progressContent
            } else if let result = model.operationResult {
                resultContent(result)
            } else {
                setupContent
            }
        }
        .frame(width: 520)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .onChange(of: selectedBindingID) { _, _ in
            guard let first = supportedKinds.first else { return }
            if !supportedKinds.contains(selectedKind) { selectedKind = first }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: model.operationResult == nil && !model.isOperationInProgress ? "arrow.triangle.2.circlepath" : outcomeIcon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(model.operationResult == nil && !model.isOperationInProgress ? palette.accent : outcomeColor)
                .frame(width: 30, height: 30)
                .background(palette.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.operationResult == nil ? "更新工作区" : "操作结果")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.isOperationInProgress
                     ? "一次只更新一个版本控制来源"
                     : (model.operationResult == nil ? "选择一个来源和要执行的操作" : "已保留本次操作的实际结果"))
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if !model.isOperationInProgress {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                .accessibilityLabel("关闭更新窗口")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(palette.surface)
    }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if bindings.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("更新目标").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
                    WorkbenchSegmentedPicker(
                        title: "更新目标",
                        selection: $selectedBindingID,
                        options: bindings.map {
                            .init($0.id, $0.providerName == "Subversion" ? "SVN" : $0.providerName)
                        },
                        palette: palette
                    )
                    .accessibilityHint("一次只能选择一个版本控制来源")
                }
            }

            if !supportedKinds.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("操作").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
                    WorkbenchSegmentedPicker(
                        title: "更新操作",
                        selection: $selectedKind,
                        options: supportedKinds.map { .init($0, $0.title) },
                        palette: palette
                    )
                }
            }

            if let binding = selectedBinding {
                bindingDetails(binding)
                actionExplanation(binding)
            } else {
                Text("当前工作区没有可更新的版本控制来源。")
                    .font(.system(size: 13)).foregroundStyle(palette.secondaryText)
            }

            HStack {
                Spacer()
                Button("取消", action: dismiss)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                Button(selectedKind.title) {
                    if let binding = selectedBinding { model.performOperation(selectedKind, on: binding) }
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                .disabled(selectedBinding == nil || !supportedKinds.contains(selectedKind))
            }
        }
        .padding(22)
    }

    private func bindingDetails(_ binding: RepositoryBinding) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow("版本控制", binding.providerName == "Subversion" ? "SVN" : binding.providerName)
            if !binding.currentBranch.isEmpty { detailRow("当前分支", binding.currentBranch) }
            detailRow("本地目录", binding.root.path)
            if let remote = binding.remoteURL { detailRow("远端", remoteSummary(remote)) }
        }
        .padding(.vertical, 4)
        .background(palette.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).frame(width: 58, alignment: .leading).foregroundStyle(palette.secondaryText)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(value)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 13).padding(.vertical, 7)
    }

    private func actionExplanation(_ binding: RepositoryBinding) -> some View {
        Text(actionText(for: binding))
            .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(palette.selection.opacity(0.46), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.operationProgressMessage.isEmpty ? "正在执行操作…" : model.operationProgressMessage)
                    .font(.system(size: 13, weight: .medium))
            }
            Text(model.isOperationCancelling
                 ? "取消不会回滚已经完成的远端或工作区步骤。正在读取真实状态，请勿关闭窗口或重复操作。"
                 : "正在执行所选操作；完成后会重新读取工作区状态。")
                .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.isOperationCancelling ? "正在取消…" : "取消操作", action: model.cancelOperation)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                    .disabled(model.isOperationCancelling)
            }
        }
        .padding(22).frame(minHeight: 190, alignment: .topLeading)
    }

    private func resultContent(_ result: RepositoryOperationResult) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 8) {
                Image(systemName: outcomeIcon).foregroundStyle(outcomeColor)
                Text(result.summary)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.outcome == .cancelled {
                Text("取消不会回滚已完成的步骤；下方状态为取消后重新读取的工作区结果。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
            }
            if !model.operationRefreshIssues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("操作已结束，但重新读取部分来源时出现问题", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(model.operationRefreshIssues, id: \.self) { issue in
                                Text(issue)
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxHeight: 96)
                }
                .padding(11)
                .background(palette.removed.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if !result.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("涉及文件 \(result.changedFiles.count)").font(.system(size: 12, weight: .medium))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(result.changedFiles) { file in
                                HStack(spacing: 8) {
                                    Text(file.kind.symbol).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(file.kind == .deleted || file.kind == .conflicted ? palette.removed : palette.accent)
                                    Text(file.path).lineLimit(1).truncationMode(.middle)
                                }
                                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 120)
                }
                .padding(12).background(palette.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if !result.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("查看详情") {
                    ScrollView(.vertical) {
                        Text(result.details)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 4)
                    }
                    .frame(maxHeight: 180)
                    .padding(.top, 8)
                }
                .font(.system(size: 12, weight: .medium))
            }
            HStack { Spacer(); Button("完成", action: dismiss).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary)) }
        }
        .padding(22).frame(minHeight: 190, alignment: .topLeading)
    }

    private var outcomeIcon: String {
        switch model.operationResult?.outcome {
        case .succeeded: "checkmark.circle.fill"
        case .conflicts: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case nil: "arrow.triangle.2.circlepath"
        }
    }

    private var outcomeColor: Color {
        switch model.operationResult?.outcome {
        case .succeeded: palette.accent
        case .conflicts, .failed: palette.removed
        case .cancelled, nil: palette.secondaryText
        }
    }

    private func actionText(for binding: RepositoryBinding) -> String {
        switch selectedKind {
        case .fetch:
            return "获取会读取 \(binding.providerName) 远端最新引用，不修改当前工作区文件。"
        case .update:
            return binding.providerID == .svn
                ? "更新会将 SVN 仓库的变更合并到本地工作副本；发生冲突时将保留冲突文件供后续处理。"
                : "更新只允许快进当前分支；存在已跟踪本地修改、分叉或进行中的合并时会停止，不会自动暂存、重置或变基。"
        }
    }

    private func remoteSummary(_ value: String) -> String {
        if let url = URL(string: value), url.isFileURL { return "本地 · " + url.path }
        if let components = URLComponents(string: value), let host = components.host {
            let port = components.port.map { ":\($0)" } ?? ""
            return host + port + components.path
        }
        // SSH 的 SCP 写法无法由 URLComponents 解析，避免在界面显示潜在用户名。
        if let at = value.lastIndex(of: "@") {
            return String(value[value.index(after: at)...].prefix(while: { $0 != "?" && $0 != "#" }))
        }
        return value.hasPrefix("/") ? "本地 · " + value : "已配置远端"
    }
}
