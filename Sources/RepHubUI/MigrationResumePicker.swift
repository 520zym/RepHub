import SwiftUI
import DesignSystem
import RepositoryApplication

/// 仅显示受限索引中由 RepHub 登记的保留目录。选择后仍会由服务层核验。
struct MigrationResumePicker: View {
    let title: String
    let records: [MigrationResumeStore.Record]
    let palette: AppPalette
    let resume: (MigrationResumeStore.Record) -> Void
    let remove: (MigrationResumeStore.Record) -> Void
    let choose: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text("列出本机保留的迁移检查点；继续前会重新核验检查点与工作副本状态。")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if records.isEmpty {
                ContentUnavailableView("未找到已登记的迁移", systemImage: "tray", description: Text("仍可手动选择之前的保留目录或 checkpoint.json。"))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(records) { record in
                    let checkpointState = checkpointState(record.checkpointURL)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.source).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(record.location).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
                        HStack {
                            Text(record.progress)
                            Spacer()
                            Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        }.font(.system(size: 10)).foregroundStyle(palette.secondaryText)
                        if checkpointState != .usable {
                            Label(checkpointState == .missing ? "检查点已缺失；可移除列表记录，或手动选择仍存在的保留目录。" : "检查点为空或不可读；继续前无法验证，请选择有效保留目录。", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 10)).foregroundStyle(palette.removed)
                        }
                        HStack {
                            Button("继续") { resume(record) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary, compact: true)).disabled(checkpointState != .usable)
                            Button("移除列表") { remove(record) }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                                .help("仅移除本机列表记录，不删除保留目录或检查点。")
                        }
                    }.padding(.vertical, 4)
                }.listStyle(.inset)
            }
            HStack {
                Button("选择保留目录或检查点…", action: choose).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                Spacer()
                Button("取消", action: dismiss).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
            }
        }
        .padding(22).frame(width: 610, height: 410)
        .background(palette.background).foregroundStyle(palette.text)
    }

    private enum CheckpointState { case usable, missing, unreadable }
    private func checkpointState(_ url: URL) -> CheckpointState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) > 0 else { return .unreadable }
        return .usable
    }
}
