import Foundation
import AppKit

/// Reads a folder of RAWs and returns the file URLs the caller should
/// wrap in `Photo` instances.
///
/// Behavior:
/// - Recursively scans the folder for RAW files (uses ThumbnailService.isLikelyRAW)
/// - Hides macOS hidden files (._foo, .DS_Store) and non-RAW files
/// - Returns a `[URL]` sorted by filename (natural sort, so IMG_0001 < IMG_0002)
///
/// We deliberately return `[URL]` instead of `[Photo]` so this function
/// can run on a background task. `Photo` is `@MainActor` (its
/// `@Published` properties are mutated from views and the store), so
/// constructing one off-main would trip Swift's concurrency checker.
/// The caller (`PhotoStore.importFolder`) hops back to the main actor
/// after this returns and builds the `[Photo]` there.
enum ImportService {

    static func importFolder(at folderURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            // Skip non-RAWs (JPGs, JPEGs, PNGs etc. are not the target)
            guard ThumbnailService.isLikelyRAW(fileURL) else { continue }

            // Skip macOS resource fork files (._IMG_0001.CR3)
            let name = fileURL.lastPathComponent
            if name.hasPrefix("._") { continue }

            urls.append(fileURL)
        }

        // Natural sort: IMG_1 < IMG_2 < IMG_10
        urls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return urls
    }
}