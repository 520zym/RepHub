import SwiftUI

/// 工作台按钮的层级。保持静态控件的边界一致，避免不同区域各自使用系统默认样式。
public enum WorkbenchButtonRole {
    case quiet
    case secondary
    case primary
}

/// 供工具栏、提交栏和检查器复用的原生按钮样式。
/// `Button` 本身仍保留系统的键盘与辅助功能语义。
public struct WorkbenchButtonStyle: ButtonStyle {
    private let palette: AppPalette
    private let role: WorkbenchButtonRole
    private let compact: Bool

    public init(palette: AppPalette, role: WorkbenchButtonRole = .secondary, compact: Bool = false) {
        self.palette = palette
        self.role = role
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        WorkbenchButtonBody(
            configuration: configuration,
            palette: palette,
            role: role,
            height: compact ? 28 : 34
        )
    }
}

private struct WorkbenchButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let palette: AppPalette
    let role: WorkbenchButtonRole
    let height: CGFloat
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        guard isEnabled else { return palette.secondaryText.opacity(0.72) }
        return role == .primary ? palette.primaryText : palette.text
    }

    private var fill: Color {
        guard isEnabled else { return role == .quiet ? .clear : palette.sidebar.opacity(0.72) }
        switch role {
        case .quiet:
            return configuration.isPressed ? palette.neutralSelection : (isHovering ? palette.controlBackground : .clear)
        case .secondary:
            return configuration.isPressed || isHovering ? palette.neutralSelection : palette.controlBackground
        case .primary:
            return palette.primaryFill.opacity(configuration.isPressed ? 0.80 : (isHovering ? 0.90 : 1))
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.94 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

/// 分段选择器中的一个选项。
public struct WorkbenchSegment<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String

    public var id: Value { value }

    public init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// 轻量的原生分段选择器。每个选项都是独立 `Button`，不会叠加系统 `Picker` 的外框。
public struct WorkbenchSegmentedPicker<Value: Hashable>: View {
    private let title: String
    @Binding private var selection: Value
    private let options: [WorkbenchSegment<Value>]
    private let palette: AppPalette
    private let compact: Bool

    public init(
        title: String,
        selection: Binding<Value>,
        options: [WorkbenchSegment<Value>],
        palette: AppPalette,
        compact: Bool = false
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.palette = palette
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: compact ? 12 : 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? palette.primaryText : palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 24 : 28)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? palette.primaryFill : .clear)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title)：\(option.title)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: compact ? 28 : 32)
        .background(palette.controlBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(options.first(where: { $0.value == selection })?.title ?? "")
        .onMoveCommand { direction in
            guard let index = options.firstIndex(where: { $0.value == selection }) else { return }
            let next: Int
            switch direction {
            case .left: next = max(0, index - 1)
            case .right: next = min(options.count - 1, index + 1)
            default: return
            }
            selection = options[next].value
        }
    }
}

/// 工作台内统一的搜索框，不使用带额外容器的系统 `TextFieldStyle`。
public struct WorkbenchSearchField: View {
    private let placeholder: String
    @Binding private var text: String
    private let palette: AppPalette
    @FocusState private var isFocused: Bool

    public init(_ placeholder: String, text: Binding<String>, palette: AppPalette) {
        self.placeholder = placeholder
        _text = text
        self.palette = palette
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(isFocused ? palette.selection.opacity(0.65) : palette.controlBackground,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
