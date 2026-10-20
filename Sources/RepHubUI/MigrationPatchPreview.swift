import SwiftUI
import DesignSystem
import VersionControlCore

/// 两种迁移路径共用的差异阅读器。滚动内容至少填满视口，长行横向滚动。
struct MigrationPatchPreview: View {
    let patch: RepositoryPatch
    let palette: AppPalette

    private let lines: [PatchDisplayLine]

    init(patch: RepositoryPatch, palette: AppPalette) {
        self.patch = patch
        self.palette = palette
        lines = PatchLineParser.parse(patch.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if patch.isTruncated {
                Label("此提交差异较大，仅显示部分内容；可在“文件”页逐项核对最终结果。", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.selection.opacity(0.35))
            }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if patch.text.hasPrefix("文件变更摘要") {
                            Text(patch.text).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                                .padding(16)
                        } else {
                            header
                            ForEach(lines.indices, id: \.self) { index in
                                row(lines[index])
                            }
                        }
                    }
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface)
    }

    private var header: some View {
        HStack(spacing: 0) {
            numberLabel("旧")
            numberLabel("新")
            Text("提交差异").font(.system(size: 10, weight: .medium)).padding(.leading, 10)
            Spacer(minLength: 16)
        }
        .foregroundStyle(palette.secondaryText)
        .frame(height: 28)
        .background(palette.sidebar.opacity(0.5))
    }

    private func row(_ line: PatchDisplayLine) -> some View {
        HStack(spacing: 0) {
            numberLabel(line.oldLine.map(String.init) ?? "")
            numberLabel(line.newLine.map(String.init) ?? "")
            Text(line.text.isEmpty ? " " : line.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 10)
            Spacer(minLength: 16)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(height: 24, alignment: .leading)
        .background(background(line))
    }

    private func numberLabel(_ value: String) -> some View {
        Text(value).font(.system(size: 10, design: .monospaced))
            .foregroundStyle(palette.secondaryText)
            .frame(width: 48, alignment: .trailing).padding(.trailing, 8)
    }

    private func background(_ line: PatchDisplayLine) -> Color {
        if line.newLine != nil && line.oldLine == nil { return palette.added.opacity(0.12) }
        if line.oldLine != nil && line.newLine == nil { return palette.removed.opacity(0.12) }
        if line.text.hasPrefix("@@") { return palette.selection.opacity(0.45) }
        if line.text.hasPrefix("diff --git") { return palette.sidebar.opacity(0.65) }
        return .clear
    }
}
