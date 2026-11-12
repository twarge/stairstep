import Foundation

/// Carries the user's viewing preferences between their devices through
/// iCloud's key-value store.
///
/// Settings stay in `UserDefaults`, where every `@AppStorage` reads them; this
/// only copies a fixed list of keys in both directions. What describes one
/// device rather than the person stays put: sidebar and toolbar layout, the
/// renderer choice, and anything whose default differs by platform.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    static let syncedKeys: [String] = [
        "reverseHorizontalRotation",
        "cameraProjection",
        "showsGrid",
        "showsAxes",
        "showsFloor",
        "showsWireframe",
        "usesOriginalColors",
        "usesColoredAccentLights",
        StairsSectionColor.storageKey,
    ]

    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, store: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.store = store
    }

    /// Begins syncing. Without the iCloud entitlement, or signed out of
    /// iCloud, the store simply never reports or accepts anything.
    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.pull(keys: keys ?? Self.syncedKeys) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        })
        store.synchronize()
        pull(keys: Self.syncedKeys)
    }

    /// Cloud to device, for keys the cloud has a value for.
    private func pull(keys: [String]) {
        for key in keys where Self.syncedKeys.contains(key) {
            guard let value = store.object(forKey: key) as? NSObject,
                  (defaults.object(forKey: key) as? NSObject) != value
            else { continue }
            defaults.set(value, forKey: key)
        }
    }

    /// Device to cloud, for keys the user has actually set. A registered
    /// default is not a choice and must not overwrite one made elsewhere.
    private func push() {
        let chosen = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for key in Self.syncedKeys {
            guard let value = chosen[key] as? NSObject,
                  (store.object(forKey: key) as? NSObject) != value
            else { continue }
            store.set(value, forKey: key)
        }
    }
}
