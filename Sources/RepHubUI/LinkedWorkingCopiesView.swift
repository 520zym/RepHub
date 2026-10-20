import SwiftUI
import DesignSystem

/// 移除关联只更新当前工作区绑定，不删除或同步目录中的文件。
struct LinkedWorkingCopiesView: View {
    @Bindable var model: WorkspaceModel
    let palette: AppPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("已关联工作副本").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("完成") { model.showsLinkedWorkspaces = false }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
            }
            Text("各目录分别保存版本控制状态。移除关联不会删除本地文件。")
                .font(.system(size: 12)).foregroundStyle(palette.secondaryText)
            if model.workspace?.linkedDirectories.isEmpty != false {
                ContentUnavailableView("没有已关联工作副本", systemImage: "folder")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.workspace?.linkedDirectories ?? [], id: \.self) { directory in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(directory.lastPathComponent).font(.system(size: 13, weight: .medium))
                                    Text(directory.path).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button("移除关联") { model.removeLinkedDirectory(directory) }
                                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                                    .disabled(model.isInteractionLocked || model.isLoading)
                            }
                            .padding(12).background(palette.sidebar.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(palette.removed)
            }
        }
        .padding(22).workbenchSheet(minWidth: 560, idealWidth: 660, minHeight: 320, idealHeight: 420)
        .background(palette.background).foregroundStyle(palette.text)
    }
}
