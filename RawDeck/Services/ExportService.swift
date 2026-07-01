import Foundation
import AppKit

/// Batch-export selected photos as their ORIGINAL files (no re-encoding).
///
/// Use case: the user has culled/rated a folder of RAWs in RawDeck and now
/// wants to copy the keepers to an external drive, an upload folder, or
/// hand them off to a client. This service copies each selected `Photo`'s
/// source file verbatim — the `.cr3` (or `.nef`, `.arw`, `.dng`, …) bytes
/// on disk in the destination folder are byte-identical to the source.
///
/// Why "copy" not "export":
/// - The user explicitly asked for "export as their original cr3/raw file".
/// - Re-encoding a RAW through Camera Raw / Pixelmator / etc. would change
///   the bytes and lose the original sensor data. For a culling app, the
///   whole point is to deliver the untouched originals downstream.
///
/// Concurrency:
/// - Copies run on a detached task so a 1000-photo export doesn't block
///   the UI. We use `withTaskGroup` so progress publishes stay on
///   MainActor (matches the `loadThumbnails` pattern).
///
/// Name collisions:
/// - If the destination already has `IMG_0001.CR3`, we write
///   `IMG_0001-1.CR3`, then `IMG_0001-2.CR3`, etc. Standard "duplicate
///   finder" behaviour; matches what Finder does.
enum ExportService {

    /// Result of an export operation, surfaced to the user via an alert.
    struct ExportResult {
        var copied: Int = 0
        var skipped: Int = 0
        var failed: Int = 0
        var firstError: String? = nil
    }

    /// Copy `urls` into `destinationFolder`. Returns counts so the caller
    /// can show a summary. `urls` should already be filtered to the photos
    /// the user wants (selected, or all visible if none selected).
    ///
    /// Threading: synchronous on the calling actor for the loop, but the
    /// function is intended to be called inside a `Task.detached` so it
    /// doesn't block the UI. File copy is a synchronous sys call, so
    /// running it off-main is the right call.
    static func export(urls: [URL], to destinationFolder: URL) -> ExportResult {
        var result = ExportResult()

        let fm = FileManager.default

        // Verify the destination exists and is a directory. If the user
        // picked a folder in NSOpenPanel this is always true, but the
        // safety check is cheap and saves a confusing crash if someone
        // wires this up to a text-field path later.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destinationFolder.path, isDirectory: &isDir),
              isDir.boolValue else {
            result.failed = urls.count
            result.firstError = "Destination is not a folder: \(destinationFolder.path)"
            return result
        }

        for src in urls {
            let dst = uniqueDestination(for: src, in: destinationFolder)
            do {
                try fm.copyItem(at: src, to: dst)
                result.copied += 1
            } catch {
                result.failed += 1
                if result.firstError == nil {
                    result.firstError = "\(src.lastPathComponent): \(error.localizedDescription)"
                }
                NSLog("RawDeck: export failed for \(src.lastPathComponent): \(error)")
            }
        }
        return result
    }

    /// Compute the destination URL for `source` in `folder`, picking a
    /// non-colliding name. Strategy:
    /// - If `IMG_0001.CR3` doesn't exist in the folder, use it as-is.
    /// - Otherwise try `IMG_0001-1.CR3`, `IMG_0001-2.CR3`, ...
    /// - If even `-9999` is taken (unlikely), fall back to a UUID suffix.
    ///
    /// Internal (not private) because `PhotoStore.exportSelection` calls
    /// it directly when iterating with a progress callback. The actual
    /// copy still goes through `export(urls:to:)` if the caller doesn't
    /// need per-file progress.
    static func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension

        let primary = folder.appendingPathComponent(source.lastPathComponent)
        if !fm.fileExists(atPath: primary.path) {
            return primary
        }

        for n in 1...9999 {
            let candidate = folder.appendingPathComponent("\(stem)-\(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Astronomical fallback — collision against 10k copies of the same
        // filename in one folder is essentially never going to happen.
        let uuid = UUID().uuidString.prefix(8)
        return folder.appendingPathComponent("\(stem)-\(uuid).\(ext)")
    }
}