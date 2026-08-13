import Foundation
import AppKit
import UniformTypeIdentifiers

/// Opens files in external applications.
///
/// Default target: Pixelmator Pro.
///
/// Detection strategy (in order):
/// 1. Look up the app by canonical Pixelmator Pro bundle ID
///    (`com.pixelmatorteam.pixelmator.pro`).
/// 2. Look up the legacy/non-Pro bundle ID
///    (`com.pixelmatorteam.pixelmator.x`) — some older installs still
///    register under this ID even after upgrading to Pro in-place.
/// 3. Scan `/Applications` and `~/Applications` for any `.app` whose
///    name contains "Pixelmator" — covers installs that didn't
///    register with Launch Services (rare but happens with manually
///    copied apps).
///
/// If found, we use `NSWorkspace.open(_:withApplicationAt:)` to launch
/// the explicit app URL — that bypasses Launch Services' file-type
/// routing, so the user's system default for `.CR2`/`.NEF`/etc. (which
/// could be Photoshop, Affinity, Lightroom, etc.) is irrelevant.
///
/// If NOT found, we return `false` and DO NOT fall back to
/// `NSWorkspace.shared.open(url)` — that fallback was the previous
/// behavior and it silently routed to whatever the system default was
/// (often Photoshop for users who set that as their default RAW
/// handler), which caused a confusing "I clicked Open in Pixelmator
/// but it opened in Photoshop" UX. The caller is expected to surface
/// the failure via an alert with a "Get Pixelmator" call-to-action.
enum ExternalAppService {

    /// Known bundle IDs for Pixelmator / Pixelmator Pro. Tried in order;
    /// the first match wins. The Pro app historically has shipped under
    /// multiple IDs depending on version and install method.
    static let pixelmatorBundleIDs: [String] = [
        "com.pixelmatorteam.pixelmator.pro",  // current Pixelmator Pro
        "com.pixelmatorteam.pixelmator.x",    // legacy / older Pro
    ]

    /// Result of a lookup attempt. Either an app URL (found), or nil
    /// with a reason explaining why it wasn't found (for logging /
    /// user-facing errors).
    enum PixelmatorLookup {
        case found(URL)
        case notInstalled(reason: String)
    }

    /// Find Pixelmator (Pro or older) on this Mac. Walks the known
    /// bundle IDs first, then falls back to a filesystem scan of the
    /// standard Applications directories.
    static func findPixelmator() -> PixelmatorLookup {
        // 1. Bundle ID lookup via Launch Services.
        for bid in pixelmatorBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return .found(url)
            }
        }

        // 2. Filesystem scan — covers edge cases where the app is
        // installed but not registered with Launch Services.
        let fm = FileManager.default
        let searchPaths = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
        ]
        for dir in searchPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.lowercased().contains("pixelmator") && entry.hasSuffix(".app") {
                let appURL = URL(fileURLWithPath: dir).appendingPathComponent(entry)
                // Sanity check: confirm it's actually runnable.
                if fm.isExecutableFile(atPath: appURL.path) {
                    return .found(appURL)
                }
            }
        }

        return .notInstalled(reason: "No app matching 'Pixelmator*' was found in /Applications or ~/Applications.")
    }

    /// Open a single photo in Pixelmator Pro.
    /// Returns true on success, false if Pixelmator Pro isn't installed.
    /// Does NOT silently fall back to the system default — callers
    /// should handle the `false` return with a user-facing alert.
    @discardableResult
    static func openInPixelmator(_ url: URL) -> Bool {
        switch findPixelmator() {
        case .found(let appURL):
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                if let error = error {
                    NSLog("RawDeck: failed to open \(url.lastPathComponent) in Pixelmator: \(error)")
                }
            }
            return true
        case .notInstalled(let reason):
            NSLog("RawDeck: cannot open in Pixelmator — \(reason)")
            return false
        }
    }

    /// Reveal a file in Finder (highlighted).
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Move a file to the macOS Trash (recoverable from Trash, NOT deleted permanently).
    /// Returns the trash outcome — either a success URL (for the caller to
    /// log/inspect) or a string describing why the trash failed (so the
    /// UI can surface "Read-only file system" or "Permission denied" to
    /// the user instead of just "1 failed to move").
    ///
    /// Earlier versions returned `Bool` and discarded the underlying error,
    /// leaving the user to guess why their trash failed. The most common
    /// causes on macOS are:
    ///   - **Read-only volume** (SD card mounted read-only, locked SD slot)
    ///   - **Permission denied** (sandbox, ACL on the file)
    ///   - **File in use** (open in another app, holds an exclusive lock)
    ///   - **Item not found** (file disappeared between when the user
    ///     selected it and when `trashItem` ran)
    /// Surfacing the raw error string lets the user diagnose in seconds
    /// rather than digging through Console.app.
    enum TrashResult {
        case success(URL)
        case failure(String)
    }
    @discardableResult
    static func moveToTrash(_ url: URL) -> TrashResult {
        var resultURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
            if let resultURL = resultURL {
                return .success(resultURL as URL)
            }
            // trashItem succeeded but no resulting URL was supplied (rare).
            // Treat as success with the original URL.
            return .success(url)
        } catch {
            NSLog("RawDeck: failed to trash \(url.lastPathComponent): \(error)")
            return .failure(error.localizedDescription)
        }
    }
}
