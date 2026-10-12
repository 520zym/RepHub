import SwiftUI
import DesignSystem
import VersionControlCore

/// 同目录双来源保留简洁分段按钮；不同目录或更多来源用菜单，避免长路径挤坏侧栏。
struct RepositorySourcePicker: View {
    let bindings: [RepositoryBinding]
    let selectedID: String?
    let select: (RepositoryBinding) -> Void
    let palette: AppPalette

    var body: some View {
        if Set(bindings.map(\.root)).count > 1 || bindings.count > 2 {
            Menu {
                ForEach(bindings) { binding in
                    Button { select(binding) } label: {
                        if binding.id == selectedID { Label(binding.displayLabel, systemImage: "checkmark") }
                        else { Text(binding.displayLabel) }
                    }
                    .help(binding.root.path)
                }
            } label: {
                Text(selected?.displayLabel ?? "选择版本控制来源")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(palette.accent)
            .help(selected?.root.path ?? "选择版本控制来源")
        } else {
            WorkbenchSegmentedPicker(title: "版本控制来源", selection: Binding(
                get: { selectedID },
                set: { id in if let binding = bindings.first(where: { $0.id == id }) { select(binding) } }
            ), options: bindings.map { .init(Optional($0.id), $0.providerID == .svn ? "SVN" : $0.providerName) }, palette: palette)
        }
    }

    private var selected: RepositoryBinding? { bindings.first { $0.id == selectedID } }
}
