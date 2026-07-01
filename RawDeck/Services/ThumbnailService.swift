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

    /// Async full-resolution preview for the lightbox. Uses Quick Look's
    /// `.all` representation type which returns the highest-quality
    /// representation Finder can produce — for CR3, that's the
    /// demosaiced sensor capture at the requested scale (much sharper
    /// than the embedded JPEG thumbnail).
    ///
    /// Default size is 2400px @ 2x = up to 4800px bitmap, which is
    /// enough for a Retina 5K lightbox. Cost: ~300-800ms per photo on
    /// a recent Mac. The result is delivered via the async function
    /// and assigned to `photo.preview`.
    ///
    /// NOTE on "original quality": QL returns whatever the system RAW
    /// codec produces for that file at the requested size — it does NOT
    /// return the unmodified sensor pixels. To see truly lossless RAW
    /// pixels, the user needs an external app like Pixelmator Pro or
    /// Darktable (which is why the "Open in Pixelmator" double-click
    /// shortcut exists). This is the sharpest QL can give us at this
    /// size.
    static func generateFullPreview(for url: URL, maxDimension: CGFloat = 2400) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            generateThumbnailAsync(url: url, maxDimension: maxDimension, quality: .fullSize) { img in
                continuation.resume(returning: img)
            }
        }
    }

    /// Async thumbnail generation callback. Posts the result on the main
    /// queue. `handler` is invoked exactly once.
    ///
    /// Uses `QLThumbnailGenerator` which is Finder's preview engine. It
    /// correctly handles CR3 on macOS 27 where CGImageSource hangs.
    ///
    /// `quality` controls which representation type QL returns:
    /// - `.thumbnail` (default for grid cells): Finder-icon-sized preview,
    ///   ~256-512px, fast.
    /// - `.fullSize` (for lightbox): the highest-quality representation
    ///   Finder can produce for the file — for CR3, that's the demosaiced
    ///   sensor capture at the requested size. ~200-500ms per file.
    enum Quality {
        case thumbnail
        case fullSize
    }

    private static func generateThumbnailAsync(
        url: URL,
        maxDimension: CGFloat,
        quality: Quality = .thumbnail,
        handler: @escaping (NSImage?) -> Void
    ) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        // For full-size requests, scale UP so a Retina display gets
        // pixel-perfect rendering. 3.0 = up to 3x the requested pixel
        // dimension (e.g. 1600px request → up to 4800px bitmap for
        // retina + zoom).
        let effectiveScale = (quality == .fullSize) ? max(scale, 2.0) : scale
        let representationType: QLThumbnailGenerator.Request.RepresentationTypes =
            (quality == .fullSize) ? .all : .thumbnail
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxDimension, height: maxDimension),
            scale: effectiveScale,
            representationTypes: representationType
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