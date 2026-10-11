import SwiftUI
import DesignSystem

struct TreeExpansionControls: View {
    let directoryIDs: [String]
    @Binding var collapsed: Set<String>
    let palette: AppPalette

    var body: some View {
        HStack(spacing: 2) {
            Button {
                collapsed.subtract(Set(directoryIDs))
            } label: {
                Label("全部展开", systemImage: "arrow.down.right.and.arrow.up.left")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
            .help("全部展开")
            .disabled(directoryIDs.isEmpty)

            Button {
                collapsed.formUnion(Set(directoryIDs))
            } label: {
                Label("全部收起", systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
            .help("全部收起")
            .disabled(directoryIDs.isEmpty)
        }
    }
}
