import SwiftUI
import DesignSystem

/// 详情栏先显示少量引用，其余标签原地展开；过多标签在原区域滚动，保留文件列表空间。
struct RevisionReferenceLabels: View {
    let references: [String]
    let visibleLimit: Int
    let maximumExpandedHeight: CGFloat
    let palette: AppPalette
    @State private var showsAllReferences = false
    @State private var expandedContentHeight: CGFloat = 24

    var body: some View {
        Group {
            if showsAllReferences {
                ScrollView(.vertical) {
                    tags
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedContentHeight = $0 }
                }
                .frame(height: min(expandedContentHeight, maximumExpandedHeight))
                .scrollDisabled(expandedContentHeight <= maximumExpandedHeight)
            } else {
                tags
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: references) { _, _ in
            showsAllReferences = false
            expandedContentHeight = 24
        }
    }

    private var tags: some View {
        ReferenceTagLayout(spacing: 6) {
            ForEach(showsAllReferences ? references : Array(references.prefix(visibleLimit)), id: \.self) { reference in
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
                Button { showsAllReferences.toggle() } label: {
                    HStack(spacing: 4) {
                        if showsAllReferences { Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold)) }
                        Text(showsAllReferences ? "收起" : "+\(references.count - visibleLimit)")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).frame(height: 24)
                    .foregroundStyle(palette.secondaryText)
                    .background(palette.secondaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(showsAllReferences ? "收起分支与标签" : "展开全部 \(references.count) 个分支与标签")
                .accessibilityLabel(showsAllReferences ? "收起分支与标签" : "展开全部 \(references.count) 个分支与标签")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
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
