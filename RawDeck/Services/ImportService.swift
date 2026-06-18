import Foundation
import AppKit

/// Reads a folder of RAWs and builds a [Photo] array for the current session.
///
/// Behavior:
/// - Recursively scans the folder for RAW files (uses ThumbnailService.isLikelyRAW)
/// - Hides macOS hidden files (._foo, .DS_Store) and non-RAW files
/// - Returns a [Photo] sorted by filename (natural sort, so IMG_0001 < IMG_0002)
enum ImportService {

    static func importFolder(at folderURL: URL) -> [Photo] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var photos: [Photo] = []
        for case let fileURL as URL in enumerator {
            // Skip non-RAWs (JPGs, JPEGs, PNGs etc. are not the target)
            guard ThumbnailService.isLikelyRAW(fileURL) else { continue }

            // Skip macOS resource fork files (._IMG_0001.CR3)
            let name = fileURL.lastPathComponent
            if name.hasPrefix("._") { continue }

            photos.append(Photo(url: fileURL))
        }

        // Natural sort: IMG_1 < IMG_2 < IMG_10
        photos.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        return photos
    }
}
