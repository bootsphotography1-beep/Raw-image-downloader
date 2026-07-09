import Foundation

/// Resolves the three subdirectories of the active library root:
/// `Library/`, `Inbox/`, `Trash/`. Each is its own directory at the top level
/// of the active backend's root URL (returned by `SyncBackend.resolveRootURL()`).
///
/// We don't currently create these directories at `init` time — they're created
/// lazily by `SyncBackend.resolveRootURL` and on first watcher event. That keeps
/// the resolver synchronous and side-effect-free for callers who just want to
/// peek at the paths.
struct LibraryRoot {

    let backend: SyncBackend
    let baseURL: URL

    init?(backend: SyncBackend) {
        guard let baseURL = backend.resolveRootURL() else { return nil }
        self.backend = backend
        self.baseURL = baseURL
    }

    var libraryURL: URL { baseURL.appendingPathComponent("Library", isDirectory: true) }
    var inboxURL:   URL { baseURL.appendingPathComponent("Inbox",   isDirectory: true) }
    var trashURL:   URL { baseURL.appendingPathComponent("Trash",   isDirectory: true) }

    /// Ensure the three top-level subdirectories exist. Idempotent. Safe to
    /// call repeatedly. Returns `false` if creation fails (typically a
    /// permissions error on iCloud Drive).
    @discardableResult
    func bootstrap() -> Bool {
        let fm = FileManager.default
        for url in [libraryURL, inboxURL, trashURL] {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }
        return true
    }
}
