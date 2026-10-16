import SwiftUI
import DesignSystem

/// 原生多行提交说明编辑器。固定可视高度后由 `TextEditor` 自己滚动，
/// 不把长说明截断，也不让外层滚动区抢走编辑滚动事件。
struct CommitMessageEditor: View {
    @Binding var text: String
    let palette: AppPalette
    let placeholder: String
    let height: CGFloat
    let isEnabled: Bool
    let help: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .accessibilityLabel("提交说明")
                .help(help)
                .disabled(!isEnabled)

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(palette.controlBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
