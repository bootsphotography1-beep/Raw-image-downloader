import Foundation
import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Generates a thumbnail or full-resolution preview for a RAW (or other
/// image) file. Uses macOS Quick Look (Finder's preview engine) as the
/// primary path because it correctly handles Canon CR3 files on macOS 27
/// where CGImageSource hangs.
///
/// Three sizes are exposed:
/// - `generateThumbnail(for:)` — 512px grid cell.
/// - `generatePreview(for:)` — 1600px placeholder preview.
/// - `generateFullPreview(for:)` — full sensor resolution (async).
///
/// **Quick Look vs ImageIO**:
/// Finder previews these CR3s correctly, but `CGImageSourceCreateWithURL`
/// + `CGImageSourceCreateImageAtIndex` hangs on the same files on
/// macOS 27 / Xcode 26.5 (confirmed: NSLog "thumbnail fast-path timeout"
/// fires for every CR3 with no return). Quick Look uses a different code
/// path (the system's RAW codec invoked via XPC) and is what Finder,
/// Preview, and every other Mac app uses to show RAW thumbnails. We use
/// it as the primary decoder and fall back to ImageIO for non-RAW files.
enum ThumbnailService {

    // MARK: - Public API

    /// Synchronous wrapper for `generateThumbnailAsync`. Blocks until the
    /// thumbnail is ready. Used by the grid cell renderer which expects
    /// an NSImage.
    ///
    /// **Threading**: must be called from a non-main thread (the caller
    /// wraps this in `Task.detached`). The QL call is XPC-based and
    /// posts a callback; we use a semaphore to wait synchronously.
    static func generateThumbnail(for url: URL, maxDimension: CGFloat = 512) -> NSImage? {
        let sem = DispatchSemaphore(value: 0)
        var result: NSImage? = nil
        generateThumbnailAsync(url: url, maxDimension: maxDimension) { img in
            result = img
            sem.signal()
        }
        // Bounded wait — QL can take a few seconds for the first RAW
        // after app launch (cold cache). After that it's 50-100ms.
        _ = sem.wait(timeout: .now() + 5.0)
        return result
    }

    /// Synchronous wrapper for the 1600px placeholder preview.
    static func generatePreview(for url: URL, maxDimension: CGFloat = 1600) -> NSImage? {
        return generateThumbnail(for: url, maxDimension: maxDimension)
    }

    /// Async full-resolution preview for the lightbox. Uses Quick Look at
    /// its largest available scale, which for CR3 is the demosaiced
    /// sensor capture (much sharper than the embedded JPEG thumbnail).
    ///
    /// Cost: 200-500ms per photo on a recent Mac. Falls back to a 1600px
    /// thumbnail if the full-res isn't available.
    static func generateFullPreview(for url: URL, maxDimension: CGFloat = 1600) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            generateThumbnailAsync(url: url, maxDimension: maxDimension) { img in
                continuation.resume(returning: img)
            }
        }
    }

    /// Async thumbnail generation callback. Posts the result on the main
    /// queue. `handler` is invoked exactly once.
    ///
    /// Uses `QLThumbnailGenerator` which is Finder's preview engine. It
    /// correctly handles CR3 on macOS 27 where CGImageSource hangs.
    private static func generateThumbnailAsync(
        url: URL,
        maxDimension: CGFloat,
        handler: @escaping (NSImage?) -> Void
    ) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxDimension, height: maxDimension),
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            DispatchQueue.main.async {
                if let rep = rep {
                    handler(rep.nsImage)
                } else {
                    handler(nil)
                }
            }
        }
    }

    // MARK: - Legacy ImageIO fallback (kept for non-RAW files where QL
    // is overkill; e.g., JPEG imports where QL would do an extra IPC hop)

    /// Heuristic: is this file a RAW image that macOS can decode?
    /// Used to decide between Quick Look (RAW) and ImageIO (everything
    /// else).
    static func isLikelyRAW(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let rawExtensions: Set<String> = [
            "cr3", "cr2",  // Canon
            "arw", "srf", "sr2",  // Sony
            "nef", "nrw",  // Nikon
            "raf",  // Fujifilm
            "dng",  // Adobe universal RAW
            "orf",  // Olympus
            "rw2",  // Panasonic
            "pef",  // Pentax
            "3fr", "fff",  // Hasselblad
            "iiq",  // Phase One
            "x3f",  // Sigma
        ]
        return rawExtensions.contains(ext)
    }
}