import Foundation

/// Owns the live-watching lifecycle for a `LibraryRoot` and translates raw
/// `WatcherEvent`s into `PhotoStore` work. Lives on `@MainActor` because the
/// PhotoStore mutations it triggers are main-actor.
///
/// Lifecycle:
/// 1. `start(root:in:)` — install a `LibraryWatcher` against the given root,
///    wire up callbacks, kick an initial `InboxSorter` pass.
/// 2. Watcher events fire `ingest(_:)`. We:
///    - For files landing in `Inbox/`: route them through `InboxSorter` and
///      then through `library.add(movedTo:)`.
///    - For files anywhere else under the root: route them through
///      `library.handleChange(at:)` which adds / removes / updates the
///      corresponding `Photo`.
/// 3. `stop()` — `stop()` the watcher, retain the rest so a backend switch
///    doesn't have to relaunch the whole subsystem.
///
/// The coordinator holds a weak reference to its `PhotoStore` because that
/// store is itself `@MainActor`-owned by AppKit and we don't want to keep
/// it alive across an `App.quit()`.
@MainActor
final class SyncCoordinator {

    /// Posted on the main thread when this coordinator hands an event off to
    /// its store. Useful for the UI ("Syncing 3…" badge in the toolbar).
    static let didIngestEvent = Notification.Name("RawDeck.SyncCoordinator.didIngestEvent")

    private weak var store: PhotoStore?
    private var watcher: LibraryWatcher?
    private var root: LibraryRoot?
    private var backendAtStart: SyncBackend?

    init(store: PhotoStore) {
        self.store = store
    }

    /// Start watching a backend. Idempotent — calling it twice with the same
    /// backend is a no-op; calling it with a different backend stops the old
    /// watcher and starts a new one. Returns `false` if the backend isn't
    /// available (iCloud signed out, etc.) or if we can't start the watcher
    /// (macOS < 14).
    @discardableResult
    func start(in backend: SyncBackend) -> Bool {
        if backend == backendAtStart, watcher != nil { return true }

        // Stop any prior watcher first. Watching two roots simultaneously is
        // possible but not what we want for v1.
        stop()

        guard let root = LibraryRoot(backend: backend) else { return false }
        guard root.bootstrap() else { return false }
        self.root = root
        self.backendAtStart = backend

        // Initial pass: any files already in Inbox/ at startup should be
        // sorted before the watcher fires. This is the same code path the
        // watcher events will hit, so we get exactly the same outcomes.
        ingestInitialInbox(root: root)

        // Wire up the watcher. Gated to macOS 13+ (the project's
        // deployment target) since `FSEventStreamSetDispatchQueue` and
        // the create/start/invalidate triplet are available there. The
        // "Settings → Sync" card on macOS 12 would still be functional
        // for backend selection, just without the watcher itself.
        if #available(macOS 13.0, *) {
            let watcher = LibraryWatcher(rootURL: root.baseURL)
            watcher.onEvent = { [weak self] event in
                // `onEvent` fires on the main queue (we set the dispatch
                // queue to `.main` in `LibraryWatcher`). It's safe to call
                // MainActor-isolated methods directly here.
                MainActor.assumeIsolated {
                    self?.ingest(event)
                }
            }
            if watcher.start() {
                self.watcher = watcher
                return true
            } else {
                return false
            }
        } else {
            // Below macOS 14 we don't have access to the FSEvents API path.
            // The Settings → Sync card surfaces a notice; the manual-import
            // UX remains the only path.
            return false
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        root = nil
        backendAtStart = nil
    }

    /// Manually re-run the inbox sorter. Useful from a "Force sync" button
    /// in Settings.
    func sortInboxNow() {
        guard let root else { return }
        ingestInitialInbox(root: root)
    }

    // MARK: - Internals

    private func ingestInitialInbox(root: LibraryRoot) {
        let outcomes = InboxSorter.moveAllInInbox(root: root)
        for outcome in outcomes {
            switch outcome {
            case .moved(let to):
                store?.noteNewPhotoOnDisk(at: to)
            case .leftInInbox:
                continue
            }
            NotificationCenter.default.post(name: Self.didIngestEvent, object: nil)
        }
    }

    private func ingest(_ event: WatcherEvent) {
        guard let root, let store else { return }

        // Inbox events: route through sorter, then add the moved file.
        let inboxPath = root.inboxURL.standardizedFileURL.path
        let eventPath = event.url.standardizedFileURL.path
        let isInInbox = eventPath.hasPrefix(inboxPath + "/")

        switch event {
        case .created(let url):
            if isInInbox {
                if case .moved(let to) = InboxSorter.moveIfNeeded(url, root: root) {
                    store.noteNewPhotoOnDisk(at: to)
                }
            } else {
                store.noteNewPhotoOnDisk(at: url)
            }
        case .modified(let url):
            store.notePhotoMetadataChanged(at: url)
        case .removed(let url):
            store.notePhotoRemovedFromDisk(at: url)
        case .unknown(let url):
            // Cheap safety net: classify on re-stat and route. Done in case
            // FSEvents flag bits surprise us.
            if FileManager.default.fileExists(atPath: url.path) {
                store.noteNewPhotoOnDisk(at: url)
            } else {
                store.notePhotoRemovedFromDisk(at: url)
            }
        }

        NotificationCenter.default.post(name: Self.didIngestEvent, object: nil)
    }
}
