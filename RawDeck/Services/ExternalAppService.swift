import Foundation
import AppKit
import UniformTypeIdentifiers

/// Opens files in external applications (Pixelmator Pro by default).
///
/// `NSWorkspace.shared.open(_:)` with a file URL triggers macOS's
/// "Open With" mechanism. If Pixelmator Pro is registered as the
/// default handler for that file type, the file opens there. If not,
/// the system asks the user which app to use the first time.
enum ExternalAppService {

    /// Bundle identifier for Pixelmator Pro. If this app is installed,
    /// we can launch it directly via `NSWorkspace.openApplication`.
    static let pixelmatorBundleID = "com.pixelmatorteam.pixelmator.x"

    /// Open a single photo in Pixelmator Pro.
    /// Returns true on success, false if Pixelmator Pro isn't installed.
    @discardableResult
    static func openInPixelmator(_ url: URL) -> Bool {
        // Try to open Pixelmator Pro directly first
        if let pixelmatorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pixelmatorBundleID) {
            // Use `open` with the app URL + file URL to force the right app
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: pixelmatorURL, configuration: config) { _, error in
                if let error = error {
                    NSLog("RawDeck: failed to open in Pixelmator: \(error)")
                }
            }
            return true
        }
        // Fallback: just open with default app
        NSWorkspace.shared.open(url)
        return false
    }

    /// Reveal a file in Finder (highlighted).
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Move a file to the macOS Trash (recoverable from Trash, NOT deleted permanently).
    /// Returns true on success.
    @discardableResult
    static func moveToTrash(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            NSLog("RawDeck: failed to trash \(url.lastPathComponent): \(error)")
            return false
        }
    }
}
