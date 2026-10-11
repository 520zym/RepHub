import SwiftUI
import DesignSystem

/// 详情栏只展示少量引用，标签按可用宽度排列，完整列表在浮层中阅读。
struct RevisionReferenceLabels: View {
    let references: [String]
    let visibleLimit: Int
    let palette: AppPalette
    @State private var showsAllReferences = false

    var body: some View {
        ReferenceTagLayout(spacing: 6) {
            ForEach(Array(references.prefix(visibleLimit)), id: \.self) { reference in
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(reference).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(palette.selection.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                .help(reference)
                .accessibilityLabel(reference)
            }
            if references.count > visibleLimit {
                Button { showsAllReferences = true } label: {
                    Text("+\(references.count - visibleLimit)")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 24)
                        .foregroundStyle(palette.secondaryText)
                        .background(palette.secondaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("查看全部 \(references.count) 个分支与标签")
                .accessibilityLabel("查看全部 \(references.count) 个分支与标签")
                .popover(isPresented: $showsAllReferences, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("关联分支与标签 · \(references.count)")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(references, id: \.self) { reference in
                                    Text(reference).font(.system(size: 12))
                                        .foregroundStyle(palette.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                    }
                    .padding(14).frame(width: 300)
                    .background(palette.surface)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: references) { _, _ in showsAllReferences = false }
    }
}

/// 按标签自然宽度换行；单个超长标签限制在容器内，并由 Text 单行省略。
private struct ReferenceTagLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        return arrange(subviews, width: max(1, width)).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: max(1, bounds.width))
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, natural.width), height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: min(width, size.width), height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}
