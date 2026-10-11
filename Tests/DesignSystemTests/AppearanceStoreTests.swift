import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct AppearanceStoreTests {
    @Test
    func persistsAllIndependentPreferences() {
        let defaults = makeDefaults()
        let store = AppearanceStore(defaults: defaults)
        store.appTheme = .graphite
        store.mode = .dark
        store.codeTheme = .light

        let restored = AppearanceStore(defaults: defaults)
        #expect(restored.appTheme == .graphite)
        #expect(restored.mode == .dark)
        #expect(restored.codeTheme == .light)
        #expect(restored.preferredColorScheme == .dark)
    }

    @Test
    func fixedCodeThemeDoesNotFollowApplicationAppearance() {
        let defaults = makeDefaults()
        let store = AppearanceStore(defaults: defaults)
        store.mode = .light
        store.codeTheme = .dark

        #expect(store.codePalette(for: .light).isDark)
        store.mode = .dark
        #expect(store.codePalette(for: .dark).isDark)

        store.codeTheme = .light
        #expect(!store.codePalette(for: .dark).isDark)
    }

    @Test
    func automaticCodeThemeUsesResolvedColorScheme() {
        let store = AppearanceStore(defaults: makeDefaults())
        store.codeTheme = .automatic

        #expect(!store.codePalette(for: .light).isDark)
        #expect(store.codePalette(for: .dark).isDark)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppearanceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
