import SwiftUI
import DesignSystem

struct ErrorStrip: View {
    let message: String
    let palette: AppPalette
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(palette.text)
            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.removed.opacity(0.10))
            .textSelection(.enabled)
    }
}
