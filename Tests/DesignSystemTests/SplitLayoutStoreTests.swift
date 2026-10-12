import Foundation
import Testing
@testable import DesignSystem

struct SplitLayoutStoreTests {
    @Test
    func restoresValuesFromTheSameNamespacedKey() {
        let defaults = makeDefaults()
        let store = SplitLayoutStore(defaults: defaults, namespace: "test.split")
        store.save(342.5, for: "history.sidebar")

        let restored = SplitLayoutStore(defaults: defaults, namespace: "test.split")
        #expect(restored.value(for: "history.sidebar") == 342.5)
    }

    @Test
    func isolatesKeysAndNamespaces() {
        let defaults = makeDefaults()
        let first = SplitLayoutStore(defaults: defaults, namespace: "test.first")
        let second = SplitLayoutStore(defaults: defaults, namespace: "test.second")
        first.save(240, for: "sidebar")
        first.save(390, for: "history.height")

        #expect(first.value(for: "sidebar") == 240)
        #expect(first.value(for: "history.height") == 390)
        #expect(second.value(for: "sidebar") == nil)
    }

    @Test
    func ignoresInvalidValuesAndEmptyKeys() {
        let defaults = makeDefaults()
        let store = SplitLayoutStore(defaults: defaults, namespace: "test.invalid")
        store.save(-1, for: "sidebar")
        store.save(.infinity, for: "sidebar")
        store.save(240, for: "   ")

        #expect(store.value(for: "sidebar") == nil)
        #expect(store.value(for: "   ") == nil)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "SplitLayoutStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
