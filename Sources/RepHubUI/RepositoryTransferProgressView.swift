import SwiftUI
import Foundation
import DesignSystem
import VersionControlCore

/// 获取和更新共用的实时进度面板。没有工具输出时明确显示等待状态，不伪造完成百分比。
struct RepositoryTransferProgressView: View {
    let progress: TransferProgressState
    let palette: AppPalette
    let source: String?
    let destination: String?
    let isCancelling: Bool
    let cancelTitle: String
    let cancel: (() -> Void)?

    @State private var followsLatest = true

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let source { summaryRow(title: "来源", value: source) }
            if let destination { summaryRow(title: "保存到", value: destination) }
            phaseStatus
            recordList
            HStack {
                if progress.isActive {
                    activityStatus
                }
                Spacer()
                if let cancel {
                    Button(isCancelling ? "正在取消…" : cancelTitle, action: cancel)
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                        .disabled(isCancelling)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.sidebar.opacity(0.46), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var phaseStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                if progress.isActive && !isCancelling {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isCancelling ? "stop.circle" : "circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
                Text(progress.phase.isEmpty ? "正在准备…" : progress.phase)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .tint(palette.accent)
                Text(String(format: "当前阶段 %.0f%%", fraction * 100))
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            if let detail = progress.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    .lineLimit(2).truncationMode(.middle).help(detail)
            }
        }
    }

    @ViewBuilder private var recordList: some View {
        if progress.records.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(isCancelling ? "正在请求停止传输…" : (progress.isActive ? "等待服务器返回进度" : "没有收到文件或传输记录"))
                    .font(.system(size: 12, weight: .medium))
                Text(progress.isActive ? "连接和协商阶段可能暂时没有逐文件输出。" : "本次操作未提供可展示的逐文件信息。")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("传输记录 \(progress.totalRecordCount)")
                        .font(.system(size: 12, weight: .medium))
                    Text("显示最近 \(progress.records.count) 条")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    Spacer()
                    Toggle("跟随最新", isOn: $followsLatest)
                        .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(progress.records) { record in
                                recordRow(record)
                            }
                            Color.clear.frame(height: 1).id("transfer-progress-end")
                        }
                    }
                    .frame(height: 170)
                    .onChange(of: progress.totalRecordCount) { _, _ in
                        guard followsLatest else { return }
                        proxy.scrollTo("transfer-progress-end", anchor: .bottom)
                    }
                    .onChange(of: followsLatest) { _, enabled in
                        guard enabled else { return }
                        proxy.scrollTo("transfer-progress-end", anchor: .bottom)
                    }
                }
                Text("记录可能包含目录和状态信息，不表示已完成文件数。")
                    .font(.system(size: 10)).foregroundStyle(palette.secondaryText)
            }
        }
    }

    private func recordRow(_ record: RepositoryProgressRecord) -> some View {
        let value = record.path ?? record.message
        let isFile: Bool
        switch record.kind {
        case .file: isFile = true
        case .information: isFile = false
        }
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: isFile ? "doc" : "info.circle")
                .font(.system(size: 10)).foregroundStyle(isFile ? palette.accent : palette.secondaryText)
                .frame(width: 13)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle).help(value)
            if record.path != nil && record.message != value {
                Text(record.message)
                    .font(.system(size: 10)).foregroundStyle(palette.secondaryText)
                    .lineLimit(1).truncationMode(.tail).help(record.message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(palette.surface.opacity(0.58), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func summaryRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondaryText).frame(width: 36, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(value)
        }
    }

    private var activityStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let origin = progress.lastActivityAt ?? progress.startedAt ?? context.date
            let idleSeconds = max(0, Int(context.date.timeIntervalSince(origin)))
            let elapsedSeconds = max(0, Int(context.date.timeIntervalSince(progress.startedAt ?? context.date)))
            Text("已用 \(elapsedSeconds) 秒 · " + (idleSeconds == 0 ? "刚刚有活动" : "最后活动 \(idleSeconds) 秒前"))
        }
        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
    }
}
