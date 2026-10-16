import SwiftUI
import DesignSystem
import VersionControlCore

/// 初始化只针对未受版本控制的目录。Git 与 SVN 的必要信息按所选方式展开，避免混淆两种写入语义。
struct RepositorySetupView: View {
    @Bindable var model: RepositorySetupModel
    let palette: AppPalette
    let dismiss: () -> Void
    let completed: (RepositorySetupResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isExecuting {
                progress
            } else if let result = model.result {
                outcome(result)
            } else {
                form
            }
        }
        .workbenchSheet(minWidth: 540, idealWidth: 620, minHeight: 460, idealHeight: 540)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .onAppear {
            if let directory = model.directory { model.prepare(directory: directory) }
        }
        .interactiveDismissDisabled(model.isExecuting)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 31, height: 31)
                .background(palette.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("初始化版本控制").font(.system(size: 15, weight: .semibold))
                Text("每个文件夹一次只能选择一种方式")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if !model.isExecuting {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .accessibilityLabel("关闭初始化窗口")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(palette.surface)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                directoryRow
                if model.isLoadingOptions {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取可用版本控制方式…") }
                        .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                } else if !model.options.isEmpty {
                    WorkbenchSegmentedPicker(title: "版本控制方式", selection: providerBinding,
                                             options: model.options.map { .init($0.providerID, $0.title) }, palette: palette)
                    if model.requiresRemote { svnFields } else { gitFields }
                    safetyNote
                    feedback
                    HStack {
                        Spacer()
                        Button("取消", action: dismiss)
                            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                        Button("初始化", action: model.initialize)
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                        .disabled(model.directory == nil || model.selectedOption == nil)
                    }
                } else {
                    Text("当前环境没有可用于初始化的版本控制工具。")
                        .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var directoryRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("目标文件夹").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondaryText)
            HStack(spacing: 8) {
                Text(model.directory?.path ?? "请选择文件夹")
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(model.directory == nil ? palette.secondaryText : palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Button("选择…", action: model.chooseDirectory)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                    .disabled(model.isBusy)
            }
        }
    }

    private var gitFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            field("初始分支") {
                TextField("main", text: $model.initialBranch).textFieldStyle(.plain)
            }
        }
    }

    private var svnFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            field("新的 SVN 地址") {
                TextField("https://server/svn/repository", text: $model.remoteURL)
                    .textFieldStyle(.plain).textSelection(.enabled)
            }
            field("导入说明") {
                TextField("初始化仓库", text: $model.message).textFieldStyle(.plain)
            }
            DisclosureGroup("需要认证") {
                VStack(spacing: 8) {
                    inlineField("用户名", text: $model.username)
                    HStack(spacing: 10) {
                        Text("密码").font(.system(size: 12)).foregroundStyle(palette.secondaryText).frame(width: 44, alignment: .leading)
                        SecureField("仅本次会话使用", text: $model.password).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12, weight: .medium)).tint(palette.accent)
        }
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.requiresRemote ? "archivebox" : "checkmark.shield")
                .foregroundStyle(palette.accent).font(.system(size: 12, weight: .medium))
            Text(model.requiresRemote
                 ? "SVN 会导入到填写的新仓库地址，检出并核对成功后保留原文件夹备份，再打开新的工作副本。取消或未知结果都不会自动重试，请重新打开文件夹核对。"
                 : "Git 会在此文件夹创建新的本地仓库。若发现现有 Git 或 SVN 元数据，初始化会停止。")
                .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(palette.selection.opacity(0.46), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private var feedback: some View {
        if let error = model.errorMessage {
            Text(error).font(.system(size: 12)).foregroundStyle(palette.removed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            RepositoryTransferProgressView(progress: model.transferProgress, palette: palette,
                                           source: model.directory?.path, destination: nil,
                                           isCancelling: model.isCancelling, cancelTitle: "取消初始化", cancel: model.cancel,
                                           showsFileRecords: false)
            Text("取消不会回滚已执行的版本控制步骤；完成后请重新打开文件夹核对状态。")
                .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
        }
        .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func outcome(_ result: RepositorySetupResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(result.summary, systemImage: outcomeIcon(result.outcome))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(outcomeColor(result.outcome))
            if !result.details.isEmpty {
                Text(result.details).font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let backup = result.backupDirectory {
                Text("原文件夹备份：\(backup.path)").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
            if result.outcome == .unknown {
                Text("结果尚未确认，请重新打开该文件夹核对；不要直接重复初始化。")
                    .font(.system(size: 12)).foregroundStyle(palette.removed)
            }
            HStack {
                Spacer()
                if result.outcome == .succeeded {
                    Button("打开工作副本") { completed(result); dismiss() }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                } else {
                    Button("完成", action: dismiss).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                }
            }
        }
        .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var providerBinding: Binding<ProviderID> {
        Binding(get: { model.selectedProviderID ?? model.options.first?.providerID ?? .git }, set: model.selectProvider)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(palette.secondaryText).frame(width: 82, alignment: .leading)
            content().font(.system(size: 12)).padding(.horizontal, 10).frame(height: 30)
                .background(palette.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func inlineField(_ title: String, text: Binding<String>) -> some View {
        field(title) { TextField(title, text: text).textFieldStyle(.plain) }
    }

    private func outcomeIcon(_ value: RepositoryManagementOutcome) -> String {
        switch value { case .succeeded: "checkmark.circle.fill"; case .conflicts: "exclamationmark.triangle.fill"; case .cancelled: "stop.circle"; case .failed: "xmark.circle.fill"; case .unknown: "questionmark.circle" }
    }

    private func outcomeColor(_ value: RepositoryManagementOutcome) -> Color {
        value == .succeeded ? palette.accent : (value == .cancelled ? palette.secondaryText : palette.removed)
    }
}
