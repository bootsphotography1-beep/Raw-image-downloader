import Foundation

/// Where the RawDeck library lives on disk.
///
/// v1 supports three backends, all of which reduce to **a single on-disk URL**.
/// The same `LibraryWatcher` (FSEventStream) works against any of them. We
/// deliberately do NOT route to the raw Google Photos API or PHPhotoLibrary — a
/// local-folder backend (whether iCloud Drive or the Google Photos Mac client's
/// local mirror) is one code path and avoids months of API integration for the
/// same v1 behavior.
///
/// Migration between backends is a tree `mv` (atomic per-subtree). See
/// `LibraryMigrator`. v2 can layer the raw API behind the same enum without
/// breaking callers.
enum SyncBackend: String, Codable, CaseIterable, Identifiable {
    /// The default. Lives under
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/RawDeck/`.
    case iCloudDrive

    /// Google Photos Mac client's local mirror folder. Path depends on the
    /// version of the Google Photos Mac client installed; we resolve via the
    /// well-known container rather than hard-coding. If the client isn't
    /// installed, `resolveRootURL()` returns `nil` and the picker disables this
    /// option.
    case googlePhotosMirror

    /// Local folder on disk, no cloud carrier. Useful for dev/test and for
    /// users who don't have iCloud or Google Photos available. We default a
    /// sandboxed location under `Application Support/RawDeck/library/`.
    case localFolder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iCloudDrive:       return "iCloud Drive"
        case .googlePhotosMirror: return "Google Photos (local mirror)"
        case .localFolder:        return "Local Folder"
        }
    }

    var helpText: String {
        switch self {
        case .iCloudDrive:
            return "Photos live in your iCloud Drive. Both this Mac and any "
                 + "device signed into the same iCloud account see the same library."
        case .googlePhotosMirror:
            return "Photos live in your Google Photos Mac client's local mirror. "
                 + "Requires the Google Photos desktop app to be signed in."
        case .localFolder:
            return "Photos live on this Mac only. No cloud sync. Useful for testing."
        }
    }

    /// The on-disk URL of the backend's root, or `nil` if the carrier
    /// isn't available (e.g. iCloud signed out, Google Photos app missing).
    ///
    /// The root URL is the parent of `Library/`, `Inbox/`, and `Trash/`. We
    /// ensure the root exists on first call (lazy-create) so callers can
    /// `.appendingPathComponent("Inbox")` immediately.
    func resolveRootURL() -> URL? {
        switch self {
        case .iCloudDrive:
            guard let containerURL = FileManager.default
                .url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("RawDeck", isDirectory: true)
            else { return nil }
            return ensureDirectoryExists(at: containerURL)

        case .googlePhotosMirror:
            // The Google Photos Mac client (>=2.0) keeps its local mirror under
            // a Group Container. We probe a couple of known paths; if neither
            // exists we return nil and the picker disables this option.
            let candidates = [
                "~/Library/Group Containers/GPGooglePhotosSync/RawDeck",
                "~/Library/Application Support/Google/Photos Sync/RawDeck"
            ].map { ($0 as NSString).expandingTildeInPath }

            for candidate in candidates {
                // Probe: if the parent exists, we can create ours.
                let parent = (candidate as NSString).deletingLastPathComponent
                if FileManager.default.fileExists(atPath: parent) {
                    return ensureDirectoryExists(at: URL(fileURLWithPath: candidate,
                                                         isDirectory: true))
                }
            }
            return nil

        case .localFolder:
            let support = try! FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return ensureDirectoryExists(at: support.appendingPathComponent("RawDeck/library",
                                                                            isDirectory: true))
        }
    }

    private func ensureDirectoryExists(at url: URL) -> URL? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            catch { return nil }
        }
        return url
    }
}
