import Foundation
import ImageIO
import AVFoundation

/// Moves files from `Inbox/` into `Library/yyyy/mm/dd/...`. EXIF capture
/// date if we can read it, file creation date as a fallback. Leaves the file
/// in `Inbox/` on any failure (don't lose the capture).
///
/// Threading: this struct runs on whatever thread `InboxSorter.move(...)` is
/// called from. It's safe to call from the main actor (file IO is bounded by
/// 2-3 metadata reads per file) — we don't spawn a detached task because the
/// watcher callback that triggers this is already debounced.
enum InboxSorter {

    /// Result of moving one file. `moved` is `false` when the source wasn't in
    /// `Inbox/`, had no readable capture date, or the move failed. The file
    /// stays put in those cases.
    enum SortOutcome {
        case moved(to: URL)
        case leftInInbox(reason: String)
    }

    /// Move a single file from `root.inboxURL` to its dated destination under
    /// `root.libraryURL`. Returns `.leftInInbox` if the file isn't actually
    /// in Inbox/ or can't be classified.
    static func moveIfNeeded(_ url: URL, root: LibraryRoot) -> SortOutcome {
        guard isInInbox(url, root: root) else {
            return .leftInInbox(reason: "Not in Inbox")
        }

        guard let captureDate = readCaptureDate(of: url) else {
            return .leftInInbox(reason: "No capture date")
        }

        let destination = datedDestination(for: captureDate,
                                           root: root,
                                           filename: url.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // If a file with this name already exists at the destination, we
            // append a numeric suffix rather than overwrite. Duplicates only
            // happen if Manual captured the same file twice (rapid fire).
            let finalURL = uniqueDestination(for: destination)
            try FileManager.default.moveItem(at: url, to: finalURL)
            return .moved(to: finalURL)
        } catch {
            return .leftInInbox(reason: "Move failed: \(error.localizedDescription)")
        }
    }

    /// Bulk version. Returns the outcomes in input order.
    static func moveAllInInbox(root: LibraryRoot) -> [SortOutcome] {
        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: root.inboxURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }
        return urls.map { moveIfNeeded($0, root: root) }
    }

    // MARK: - Internals

    private static func isInInbox(_ url: URL, root: LibraryRoot) -> Bool {
        let inboxPath = root.inboxURL.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(inboxPath + "/")
    }

    private static func datedDestination(for date: Date,
                                         root: LibraryRoot,
                                         filename: String) -> URL {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 1970
        let month = String(format: "%02d", comps.month ?? 1)
        let day = String(format: "%02d", comps.day ?? 1)
        return root.libraryURL
            .appendingPathComponent("\(year)", isDirectory: true)
            .appendingPathComponent("\(month)", isDirectory: true)
            .appendingPathComponent("\(day)", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 1...999 {
            let candidate = dir.appendingPathComponent("\(base) (\(n)).\(ext)",
                                                       isDirectory: false)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url  // Give up — caller will overwrite.
    }

    /// Read the capture date from the file's metadata. Uses ImageIO first
    /// (works for `.dng`, `.cr3`, `.nef`, `.arw`, etc.); falls back to file
    /// creation date. Returns `nil` if neither is available.
    private static func readCaptureDate(of url: URL) -> Date? {
        if let exifDate = readEXIFDate(of: url) { return exifDate }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.creationDate] as? Date
    }

    private static func readEXIFDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let str = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
           let parsed = exifDateFormatter.date(from: str) {
            return parsed
        }
        return nil
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}
