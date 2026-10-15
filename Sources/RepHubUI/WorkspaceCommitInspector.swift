import SwiftUI
import DesignSystem
import VersionControlCore

/// 工作区中的提交草稿；实际提交仍进入已有的逐目标预检与确认流程。
struct WorkspaceCommitInspector: View {
    let palette: AppPalette
    let bindings: [RepositoryBinding]
    @Binding var message: String
    @Binding var targets: Set<String>
    let selectedCount: Int
    let blockedReason: String?
    let aiAvailable: Bool
    let isLocked: Bool
    let collapse: () -> Void
    let prepare: () -> Void
    let prepareAI: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("准备提交").font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 4)
                Button(action: collapse) { Image(systemName: "sidebar.right") }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .accessibilityLabel("收起提交区")
            }
            .padding(.bottom, 8)
            Text("已选 \(selectedCount) 项变更").font(.system(size: 13)).foregroundStyle(palette.secondaryText)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $message)
                            .font(.system(size: 13)).scrollContentBackground(.hidden)
                            .padding(7).frame(minHeight: 150, maxHeight: 200)
                            .accessibilityLabel("提交说明")
                            .help(bindings.count > 1 ? "在这里编辑会更新所有提交目标的说明；可在确认窗口分别修改。" : "编辑本次提交说明，可在确认窗口继续修改。")
                        if message.isEmpty {
                            Text("描述这次修改…").font(.system(size: 13)).foregroundStyle(palette.secondaryText)
                                .padding(.horizontal, 12).padding(.top, 14).allowsHitTesting(false)
                        }
                    }
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))

                    Button(action: prepareAI) { Label("AI 生成", systemImage: "sparkles") }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                        .disabled(!aiAvailable || !canPrepare)
                        .help("进入提交预检，按真实文件范围选择场景并生成说明")

                    VStack(alignment: .leading, spacing: 12) {
                        if bindings.count == 1, let binding = bindings.first {
                            Text("提交到 \(binding.providerID == .svn ? "SVN" : binding.providerName)")
                                .font(.system(size: 13, weight: .semibold))
                                .help(binding.root.path)
                        } else {
                            Text("提交目标").font(.system(size: 13, weight: .semibold))
                            ForEach(bindings) { binding in
                                Toggle(isOn: Binding(
                                    get: { targets.contains(binding.id) },
                                    set: { if $0 { targets.insert(binding.id) } else { targets.remove(binding.id) } }
                                )) {
                                    Text(binding.displayLabel).lineLimit(2).font(.system(size: 13))
                                }
                                .toggleStyle(.checkbox).help(binding.root.path)
                            }
                        }
                        Text(targetDescription).font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("提交范围").font(.system(size: 13, weight: .semibold))
                        Text("仅预选左侧勾选的变更，下一步核对各来源的文件与说明。")
                            .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 9) {
                Button(action: prepare) {
                    Text("提交 \(selectedCount) 项变更…")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 14)
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                .disabled(!canPrepare)
                .help("进入提交预检和确认，不会立即写入仓库")
                Text(blockedReason ?? (targets.isEmpty ? "请选择提交目标" : selectedCount == 0 ? "请先勾选变更" : "核对文件和说明，确认后执行提交。"))
                    .font(.system(size: 11)).foregroundStyle(blockedReason == nil ? palette.secondaryText : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebar)
        .disabled(isLocked)
    }

    private var canPrepare: Bool { !isLocked && blockedReason == nil && !targets.isEmpty && selectedCount > 0 }

    private var targetDescription: String {
        let selected = bindings.filter { targets.contains($0.id) }
        if selected.isEmpty { return "选择要提交的版本控制来源。" }
        return selected.map { binding in
            binding.capabilities.contains(.push)
                ? "\(binding.providerName) 提交到本地\(binding.currentBranch.isEmpty ? "" : " " + binding.currentBranch)。"
                : "\(binding.providerName) 直接提交到服务器。"
        }.joined(separator: "\n")
    }
}
