import SwiftUI

/// 原生设置页的外观与代码配色入口；调用方在根视图将 `preferredColorScheme` 应用于窗口层。
public struct ThemeSettingsView: View {
    @Bindable private var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme

    public init(appearance: AppearanceStore) {
        self.appearance = appearance
    }

    public var body: some View {
        let palette = appearance.palette(for: effectiveColorScheme)
        let code = appearance.codePalette(for: effectiveColorScheme)

        Form {
            Section("应用外观") {
                Picker("应用主题", selection: $appearance.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Picker("日夜模式", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("代码配色") {
                Picker("代码主题", selection: $appearance.codeTheme) {
                    ForEach(CodeThemeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                CodeThemePreview(palette: code, appPalette: palette)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("外观与代码配色")
    }

    private var effectiveColorScheme: ColorScheme {
        appearance.preferredColorScheme ?? systemColorScheme
    }
}

private struct CodeThemePreview: View {
    let palette: CodePalette
    let appPalette: AppPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(palette.isDark ? "深色代码预览" : "浅色代码预览", systemImage: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(appPalette.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                previewLine("1", "struct ", kind: .keyword, suffix: "Repository: View {")
                previewLine("2", "    let ", kind: .keyword, suffix: "name: String")
                previewLine("3", "    // 当前工作区", kind: .comment, suffix: "")
                previewLine("4", "+   Text(\"RepHub\")", kind: .added, suffix: "")
                previewLine("5", "-   Text(\"旧视图\")", kind: .removed, suffix: "")
            }
            .font(.system(.caption, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(.vertical, 4)
    }

    private enum PreviewKind { case keyword, comment, added, removed }

    private func previewLine(_ number: String, _ text: String, kind: PreviewKind, suffix: String) -> some View {
        HStack(spacing: 8) {
            Text(number).foregroundStyle(palette.lineNumber).frame(width: 16, alignment: .trailing)
            Text(text).foregroundStyle(foreground(for: kind)) + Text(suffix).foregroundStyle(palette.foreground)
        }
        .padding(.horizontal, 4)
        .background(background(for: kind), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func foreground(for kind: PreviewKind) -> Color {
        switch kind {
        case .keyword: palette.keyword
        case .comment: palette.comment
        case .added: palette.addedForeground
        case .removed: palette.removedForeground
        }
    }

    private func background(for kind: PreviewKind) -> Color {
        switch kind {
        case .added: palette.addedBackground
        case .removed: palette.removedBackground
        case .keyword, .comment: .clear
        }
    }
}
