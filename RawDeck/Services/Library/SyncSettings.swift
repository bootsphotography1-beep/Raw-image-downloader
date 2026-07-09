import Foundation
import Combine

/// User-persisted sync configuration. Stored in `UserDefaults` under the key
/// `sync.backend`. Backed by an `ObservableObject` so the Settings window can
/// `@Published` the active backend and any open UI re-renders when the user
/// switches.
///
/// We deliberately do NOT persist the resolved URL — `SyncBackend.resolveRootURL()`
/// returns `nil` if the carrier isn't available at the moment of resolution
/// (signed out, app missing). Persisting the URL would let the picker return
/// a stale path and crash the watcher.
@MainActor
final class SyncSettings: ObservableObject {

    @Published var active: SyncBackend {
        didSet {
            guard oldValue != active else { return }
            UserDefaults.standard.set(active.rawValue, forKey: Self.backendKey)
            // Notify subscribers (PhotoStore's `startWatchingLibrary` reruns).
            NotificationCenter.default.post(name: .syncBackendDidChange, object: nil)
        }
    }

    /// Persisted as soon as the user picks one. `nil` until first launch picks
    /// a backend (the Settings window's first-run UI handles that).
    static let backendKey = "sync.backend"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.backendKey)
        if let raw, let parsed = SyncBackend(rawValue: raw) {
            self.active = parsed
        } else {
            self.active = .iCloudDrive  // first-run default
        }
    }

    /// True if this backend is available *right now* (iCloud signed in,
    /// Google Photos app installed). Drives the disabled state on the picker.
    func isAvailable(_ backend: SyncBackend) -> Bool {
        backend.resolveRootURL() != nil
    }
}

extension Notification.Name {
    static let syncBackendDidChange = Notification.Name("RawDeck.syncBackendDidChange")
}
