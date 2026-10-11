import Observation
import SwiftUI

/// 应用外观模式独立于应用主题与代码主题；`.system` 时由场景环境决定实际颜色。
public enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

/// 应用层配色，不参与代码语法与差异的颜色解析。
public enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case jade
    case graphite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .jade: "温润翡翠"
        case .graphite: "石墨灰"
        }
    }
}

/// 固定代码配色可以和应用有效外观不同，例如浅色应用内使用深色代码阅读区。
public enum CodeThemeChoice: String, CaseIterable, Identifiable, Codable {
    case automatic
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "跟随外观"
        case .light: "浅色代码"
        case .dark: "深色代码"
        }
    }
}

public struct AppPalette {
    public let background: Color
    public let surface: Color
    public let sidebar: Color
    public let text: Color
    public let secondaryText: Color
    public let border: Color
    public let accent: Color
    public let selection: Color
    public let added: Color
    public let removed: Color

    public init(background: Color, surface: Color, sidebar: Color, text: Color, secondaryText: Color, border: Color, accent: Color, selection: Color, added: Color, removed: Color) {
        self.background = background
        self.surface = surface
        self.sidebar = sidebar
        self.text = text
        self.secondaryText = secondaryText
        self.border = border
        self.accent = accent
        self.selection = selection
        self.added = added
        self.removed = removed
    }
}

public struct CodePalette {
    public let background: Color
    public let foreground: Color
    public let secondary: Color
    public let lineNumber: Color
    public let keyword: Color
    public let string: Color
    public let comment: Color
    public let type: Color
    public let number: Color
    public let addedBackground: Color
    public let removedBackground: Color
    public let addedForeground: Color
    public let removedForeground: Color
    public let selection: Color
    public let isDark: Bool

    public init(background: Color, foreground: Color, secondary: Color, lineNumber: Color, keyword: Color, string: Color, comment: Color, type: Color, number: Color, addedBackground: Color, removedBackground: Color, addedForeground: Color, removedForeground: Color, selection: Color, isDark: Bool) {
        self.background = background
        self.foreground = foreground
        self.secondary = secondary
        self.lineNumber = lineNumber
        self.keyword = keyword
        self.string = string
        self.comment = comment
        self.type = type
        self.number = number
        self.addedBackground = addedBackground
        self.removedBackground = removedBackground
        self.addedForeground = addedForeground
        self.removedForeground = removedForeground
        self.selection = selection
        self.isDark = isDark
    }
}

/// 主题偏好仅写入提供的 `UserDefaults`，不持有也不影响仓库、AI 或任务状态。
@MainActor
@Observable
public final class AppearanceStore {
    private enum StorageKey {
        static let appTheme = "rephub.appearance.appTheme"
        static let mode = "rephub.appearance.mode"
        static let codeTheme = "rephub.appearance.codeTheme"
    }

    private let defaults: UserDefaults

    public var appTheme: AppTheme {
        didSet { defaults.set(appTheme.rawValue, forKey: StorageKey.appTheme) }
    }

    public var mode: AppearanceMode {
        didSet { defaults.set(mode.rawValue, forKey: StorageKey.mode) }
    }

    public var codeTheme: CodeThemeChoice {
        didSet { defaults.set(codeTheme.rawValue, forKey: StorageKey.codeTheme) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appTheme = AppTheme(rawValue: defaults.string(forKey: StorageKey.appTheme) ?? "") ?? .jade
        mode = AppearanceMode(rawValue: defaults.string(forKey: StorageKey.mode) ?? "") ?? .system
        codeTheme = CodeThemeChoice(rawValue: defaults.string(forKey: StorageKey.codeTheme) ?? "") ?? .automatic
    }

    /// `nil` 表示交给 SwiftUI 的场景环境跟随系统。
    public var preferredColorScheme: ColorScheme? {
        switch mode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public func palette(for colorScheme: ColorScheme) -> AppPalette {
        switch (appTheme, colorScheme) {
        case (.jade, .light): Self.jadeLight
        case (.jade, .dark): Self.jadeDark
        case (.graphite, .light): Self.graphiteLight
        case (.graphite, .dark): Self.graphiteDark
        @unknown default: Self.jadeLight
        }
    }

    public func codePalette(for colorScheme: ColorScheme) -> CodePalette {
        switch codeTheme {
        case .automatic: colorScheme == .dark ? Self.codeDark : Self.codeLight
        case .light: Self.codeLight
        case .dark: Self.codeDark
        }
    }
}

private extension AppearanceStore {
    static let jadeLight = AppPalette(
        background: Color(red: 0.965, green: 0.973, blue: 0.956),
        surface: .white,
        sidebar: Color(red: 0.942, green: 0.963, blue: 0.944),
        text: Color(red: 0.075, green: 0.130, blue: 0.125),
        secondaryText: Color(red: 0.365, green: 0.435, blue: 0.420),
        border: Color(red: 0.824, green: 0.866, blue: 0.838),
        accent: Color(red: 0.000, green: 0.485, blue: 0.350),
        selection: Color(red: 0.852, green: 0.945, blue: 0.901),
        added: Color(red: 0.000, green: 0.530, blue: 0.315),
        removed: Color(red: 0.805, green: 0.265, blue: 0.285)
    )

    static let jadeDark = AppPalette(
        background: Color(red: 0.055, green: 0.086, blue: 0.078),
        surface: Color(red: 0.085, green: 0.125, blue: 0.114),
        sidebar: Color(red: 0.070, green: 0.110, blue: 0.098),
        text: Color(red: 0.905, green: 0.944, blue: 0.919),
        secondaryText: Color(red: 0.620, green: 0.704, blue: 0.667),
        border: Color(red: 0.185, green: 0.260, blue: 0.235),
        accent: Color(red: 0.290, green: 0.790, blue: 0.575),
        selection: Color(red: 0.105, green: 0.285, blue: 0.220),
        added: Color(red: 0.285, green: 0.820, blue: 0.520),
        removed: Color(red: 1.000, green: 0.500, blue: 0.510)
    )

    static let graphiteLight = AppPalette(
        background: Color(red: 0.958, green: 0.962, blue: 0.970),
        surface: Color(red: 0.995, green: 0.996, blue: 0.998),
        sidebar: Color(red: 0.925, green: 0.935, blue: 0.944),
        text: Color(red: 0.090, green: 0.105, blue: 0.125),
        secondaryText: Color(red: 0.350, green: 0.385, blue: 0.430),
        border: Color(red: 0.790, green: 0.812, blue: 0.840),
        accent: Color(red: 0.205, green: 0.385, blue: 0.650),
        selection: Color(red: 0.855, green: 0.905, blue: 0.980),
        added: Color(red: 0.075, green: 0.500, blue: 0.320),
        removed: Color(red: 0.745, green: 0.250, blue: 0.300)
    )

    static let graphiteDark = AppPalette(
        background: Color(red: 0.060, green: 0.067, blue: 0.082),
        surface: Color(red: 0.095, green: 0.106, blue: 0.128),
        sidebar: Color(red: 0.075, green: 0.084, blue: 0.103),
        text: Color(red: 0.920, green: 0.930, blue: 0.950),
        secondaryText: Color(red: 0.635, green: 0.670, blue: 0.725),
        border: Color(red: 0.205, green: 0.222, blue: 0.260),
        accent: Color(red: 0.430, green: 0.650, blue: 0.985),
        selection: Color(red: 0.145, green: 0.225, blue: 0.365),
        added: Color(red: 0.330, green: 0.770, blue: 0.540),
        removed: Color(red: 1.000, green: 0.510, blue: 0.560)
    )

    static let codeLight = CodePalette(
        background: Color(red: 0.990, green: 0.993, blue: 0.988),
        foreground: Color(red: 0.095, green: 0.145, blue: 0.180),
        secondary: Color(red: 0.380, green: 0.450, blue: 0.490),
        lineNumber: Color(red: 0.510, green: 0.570, blue: 0.610),
        keyword: Color(red: 0.620, green: 0.155, blue: 0.840),
        string: Color(red: 0.650, green: 0.320, blue: 0.120),
        comment: Color(red: 0.420, green: 0.520, blue: 0.510),
        type: Color(red: 0.000, green: 0.330, blue: 0.770),
        number: Color(red: 0.730, green: 0.400, blue: 0.080),
        addedBackground: Color(red: 0.885, green: 0.975, blue: 0.913),
        removedBackground: Color(red: 1.000, green: 0.910, blue: 0.910),
        addedForeground: Color(red: 0.000, green: 0.400, blue: 0.230),
        removedForeground: Color(red: 0.720, green: 0.100, blue: 0.145),
        selection: Color(red: 0.820, green: 0.900, blue: 1.000),
        isDark: false
    )

    static let codeDark = CodePalette(
        background: Color(red: 0.080, green: 0.098, blue: 0.115),
        foreground: Color(red: 0.875, green: 0.910, blue: 0.925),
        secondary: Color(red: 0.600, green: 0.665, blue: 0.700),
        lineNumber: Color(red: 0.430, green: 0.505, blue: 0.550),
        keyword: Color(red: 0.830, green: 0.520, blue: 1.000),
        string: Color(red: 0.990, green: 0.665, blue: 0.430),
        comment: Color(red: 0.455, green: 0.630, blue: 0.575),
        type: Color(red: 0.350, green: 0.695, blue: 1.000),
        number: Color(red: 1.000, green: 0.705, blue: 0.390),
        addedBackground: Color(red: 0.075, green: 0.255, blue: 0.170),
        removedBackground: Color(red: 0.300, green: 0.105, blue: 0.125),
        addedForeground: Color(red: 0.460, green: 0.945, blue: 0.660),
        removedForeground: Color(red: 1.000, green: 0.620, blue: 0.650),
        selection: Color(red: 0.150, green: 0.290, blue: 0.435),
        isDark: true
    )
}
