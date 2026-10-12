import AICore
import DesignSystem
import SwiftUI

/// 只读的 AI 差异运行面板。调用方负责在用户明确点击入口后准备上下文。
public struct AIRunView: View {
    @Bindable private var model: AIRunModel
    private let palette: AppPalette
    private let codePalette: CodePalette
    private let dismiss: () -> Void
    private let applyOutput: ((String) -> Void)?

    public init(model: AIRunModel, palette: AppPalette, codePalette: CodePalette, dismiss: @escaping () -> Void, apply: ((String) -> Void)? = nil) {
        self.model = model
        self.palette = palette
        self.codePalette = codePalette
        self.dismiss = dismiss
        self.applyOutput = apply
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                sourcePane
                    .frame(width: 286)
                    .background(palette.sidebar.opacity(0.62))
                VStack(spacing: 0) {
                    configuration
                    output
                    footer
                }
                .background(palette.background)
            }
        }
        .frame(width: 900, height: 620)
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .background(palette.background)
        .interactiveDismissDisabled(model.isBusy)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: model.kind == .commitMessage ? "text.badge.checkmark" : "sparkle.magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 31, height: 31)
                .background(palette.selection.opacity(0.64), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.kind == .commitMessage ? "AI 生成提交说明" : "AI 代码审查")
                    .font(.system(size: 15, weight: .semibold))
                Text("仅分析明确选中的文本差异；不会修改仓库或执行提交。")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if !model.isBusy {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .accessibilityLabel("关闭 AI 面板")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 17)
        .background(palette.surface)
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.kind == .commitMessage ? "提交文件" : "审查范围")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.sourceLabel.isEmpty ? "尚未准备差异" : model.sourceLabel)
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText).lineLimit(1)
                }
                Spacer()
                if model.canEditFileSelection {
                    Menu {
                        Button("全选") { model.selectAllPaths() }
                        Button("清空") { model.clearPathSelection() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .help("全选或清空文件")
                }
            }
            .padding(.horizontal, 16).padding(.top, 16)

            Text(model.kind == .commitMessage
                 ? "与提交窗口当前勾选的文件保持一致。"
                 : "\(model.selectedPaths.count) / \(model.paths.count) 个文件已选择")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.paths, id: \.self) { path in
                        Button {
                            model.togglePath(path)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.selectedPaths.contains(path) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(model.selectedPaths.contains(path) ? palette.accent : palette.secondaryText.opacity(0.8))
                                Text(path).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(model.selectedPaths.contains(path) ? palette.selection.opacity(0.62) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canEditFileSelection)
                        .accessibilityLabel(path)
                        .accessibilityValue(model.selectedPaths.contains(path) ? "已选择" : "未选择")
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("场景").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondaryText)
                    Picker("场景", selection: Binding(get: { model.sceneID }, set: { model.selectScene($0) })) {
                        if model.scenes.isEmpty { Text("尚未配置场景").tag(UUID?.none) }
                        ForEach(model.scenes) { scene in Text(scene.name).tag(Optional(scene.id)) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity).disabled(model.isBusy || model.scenes.isEmpty)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("连接").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondaryText)
                    Picker("连接", selection: Binding(get: { model.connectionID }, set: { model.selectConnection($0) })) {
                        if model.connections.isEmpty { Text("尚未配置连接").tag(UUID?.none) }
                        ForEach(model.connections) { connection in Text(connection.name).tag(Optional(connection.id)) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity).disabled(model.isBusy || model.connections.isEmpty)
                }
            }
            if let connection = model.selectedConnection {
                connectionDescription(connection)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3")
                    Text("配置模型 API 或本机 Codex / Claude Code 后，才会发送你确认的差异。")
                    Spacer()
                    SettingsLink { Text("配置 AI…") }
                        .font(.system(size: 11, weight: .medium))
                }
                .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                .padding(9).background(palette.sidebar.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.horizontal, 18).padding(.top, 15).padding(.bottom, 12)
        .background(palette.surface.opacity(0.62))
    }

    private func connectionDescription(_ connection: AIConnection) -> some View {
        let text: String
        switch connection.kind {
        case .openAICompatible, .openAIResponses, .anthropicMessages:
            text = "\(connection.preset?.title ?? connection.kind.title) · \(model.effectiveModel) · \(connection.baseURL)"
        case .codexCLI, .claudeCLI:
            text = "本机 CLI · \(model.effectiveModel.isEmpty ? "工具默认模型" : model.effectiveModel) · 仅提供所选差异"
        }
        return Label(text, systemImage: connection.kind.isAPI ? "network" : "terminal")
            .font(.system(size: 11)).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("结果").font(.system(size: 13, weight: .semibold))
                if model.isStale {
                    Label("差异已变化", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.removed)
                }
                Spacer()
                if !model.output.isEmpty, !model.isBusy {
                    Button("重新核对") { model.revalidate() }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(palette.removed)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.removed.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            ScrollView {
                if model.output.isEmpty {
                    ContentUnavailableView(model.isBusy ? "正在等待结果" : "尚未运行", systemImage: model.isBusy ? "ellipsis.message" : "sparkles",
                                            description: Text(model.isBusy ? "结果会在这里逐步显示。" : "确认场景、连接与文件范围后再开始。"))
                        .frame(maxWidth: .infinity, minHeight: 210)
                } else {
                    AICodeOutputView(output: model.output, palette: codePalette, isRunning: model.isBusy)
                        .padding(12)
                }
            }
            .background(palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            if model.hasStartedRequest { usageSummary }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let usage = model.tokenUsage, usage.hasReportedTokens {
                Text("Token · 输入 \(count(usage.inputTokens)) · 输出 \(count(usage.outputTokens)) · 合计 \(count(usage.totalTokens))")
                    .monospacedDigit()
                if usage.cachedInputTokens != nil || usage.cacheCreationInputTokens != nil || usage.reasoningTokens != nil {
                    Text("其中：\(usageDetails(usage))").monospacedDigit()
                }
                if let actualModel = usage.model, !actualModel.isEmpty {
                    Text("响应模型：\(actualModel)").lineLimit(1).truncationMode(.middle)
                }
            } else {
                Text(model.isBusy ? "Token 用量将在响应返回后显示" : "服务未返回 Token 用量，未计为零")
            }
        }
        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 3).padding(.top, 2)
    }

    private func count(_ value: Int?) -> String { value.map { $0.formatted() } ?? "未返回" }

    private func usageDetails(_ usage: AITokenUsage) -> String {
        var parts: [String] = []
        if let value = usage.cachedInputTokens { parts.append("缓存命中 \(value.formatted())") }
        if let value = usage.cacheCreationInputTokens { parts.append("缓存写入 \(value.formatted())") }
        if let value = usage.reasoningTokens { parts.append("推理 \(value.formatted())") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !model.progress.isEmpty {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.progress).font(.system(size: 11)).foregroundStyle(model.isStale ? palette.removed : palette.secondaryText)
            }
            Spacer()
            if model.isBusy {
                Button("取消") { model.cancel() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
            } else {
                Button("关闭", action: dismiss)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                if model.kind == .commitMessage, let applyOutput, !model.output.isEmpty, !model.isStale {
                    Button("填入提交说明") { model.apply { value in applyOutput(value) } }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                }
                Button(model.output.isEmpty ? model.actionTitle : "重新生成") { model.run() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                    .disabled(!model.canRun)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(palette.surface)
    }
}
