import SwiftUI
import DesignSystem

struct ErrorStrip: View {
    let message: String
    let palette: AppPalette
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .padding(.top, 3)
        } label: {
            Label(summary, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
        }
        .tint(palette.removed)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(palette.removed.opacity(0.10))
        .help(message)
    }

    private var summary: String {
        message.split(whereSeparator: \.isNewline).first.map(String.init) ?? "仓库读取失败"
    }
}
