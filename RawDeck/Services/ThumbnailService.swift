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
        if result != nil {
            return result
        }
        // Fallback 1: retry with smaller size (256px). Sometimes QL's
        // cold-cache RAW decoder fails on large requests but succeeds
        // on smaller ones.
        if maxDimension > 256 {
            let sem2 = DispatchSemaphore(value: 0)
            generateThumbnailAsync(url: url, maxDimension: 256) { img in
                result = img
                sem2.signal()
            }
            _ = sem2.wait(timeout: .now() + 5.0)
            if result != nil {
                return result
            }
        }
        // Fallback 2: extract embedded JPEG preview from CR3 container.
        // Works for CR3 files specifically (Canon's ISO BMFF format).
        if url.pathExtension.lowercased() == "cr3" {
            return extractCR3EmbeddedPreview(url: url, maxDimension: maxDimension)
        }
        return nil
    }

    /// Extract the embedded JPEG preview from a Canon CR3 file's ISO
    /// BMFF container and decode it. CR3 files have an "Exif" JPEG
    /// preview typically stored in a separate `mdat` atom. We scan the
    /// file looking for a JPEG marker (FFD8FF) and decode that.
    ///
    /// This bypasses Quick Look entirely. It's our last-resort
    /// fallback when QL returns nil.
    static func extractCR3EmbeddedPreview(url: URL, maxDimension: CGFloat) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        // Scan for JPEG SOI marker (FFD8FF). Preview is typically in
        // the second half of the file (after main RAW data).
        let bytes = [UInt8](data)
        let fileSize = bytes.count
        guard fileSize > 1024 else { return nil }
        let searchStart = fileSize / 2
        var foundJPEGStart: Int? = nil
        var i = searchStart
        while i < fileSize - 3 {
            if bytes[i] == 0xFF && bytes[i+1] == 0xD8 && bytes[i+2] == 0xFF {
                foundJPEGStart = i
                break
            }
            i += 1
        }
        guard let jpegStart = foundJPEGStart else {
            return nil
        }
        // Find JPEG EOI marker (FFD9) to determine preview end.
        var jpegEnd = fileSize
        var j = jpegStart + 3
        while j < fileSize - 1 {
            if bytes[j] == 0xFF && bytes[j+1] == 0xD9 {
                jpegEnd = j + 2
                break
            }
            j += 1
        }
        let jpegData = data.subdata(in: jpegStart..<jpegEnd)
        guard let nsImage = NSImage(data: jpegData) else {
            return nil
        }
        // Downscale if needed using CGContext.
        if let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let srcW = CGFloat(cg.width)
            let srcH = CGFloat(cg.height)
            let scale = min(maxDimension / max(srcW, srcH), 1.0)
            if scale < 1.0 {
                let dstW = max(1, Int(srcW * scale))
                let dstH = max(1, Int(srcH * scale))
                if let ctx = CGContext(
                    data: nil,
                    width: dstW,
                    height: dstH,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                           | CGBitmapInfo.byteOrder32Little.rawValue
                ) {
                    ctx.interpolationQuality = .high
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
                    if let resized = ctx.makeImage() {
                        return NSImage(cgImage: resized, size: NSSize(width: dstW, height: dstH))
                    }
                }
            }
            return NSImage(cgImage: cg, size: NSSize(width: srcW, height: srcH))
        }
        return nsImage
    }

    /// Synchronous wrapper for the 1600px placeholder preview.
    static func generatePreview(for url: URL, maxDimension: CGFloat = 1600) -> NSImage? {
        return generateThumbnail(for: url, maxDimension: maxDimension)
    }

    /// Async full-resolution preview for the lightbox.
    ///
    /// Uses `QLThumbnailGenerator` with the `.thumbnail` representation
    /// type, but requests a much larger size than the grid cells
    /// (2400px vs 512px). QL's `.thumbnail` scales the preview bitmap
    /// to whatever dimension you request, so a 2400px request yields a
    /// 2400px-long-side image — sharp on a 5K display.
    ///
    /// **Why not `.all`?** We tried `representationTypes: .all` (QL's
    /// "highest quality" option) — it returns the file's *icon*
    /// (the curled-paper graphic) for CR3/RAW instead of decoded image
    /// content, because `.all` is meant for documents (PDFs, Keynote
    /// files) where the file IS the document, not for media files.
    /// `.thumbnail` correctly decodes RAW preview data at any size.
    ///
    /// Cost: ~300-800ms per photo on a recent Mac. The result is
    /// delivered via the async function and assigned to `photo.preview`.
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
    /// `quality` controls what we ask QL for:
    /// - `.thumbnail` (default for grid cells): small request, fast.
    /// - `.fullSize` (for lightbox): larger request — QL scales the
    ///   decoded preview bitmap to whatever size we ask, so we get
    ///   pixel-sharp rendering on Retina without paying for full
    ///   sensor demosaic.
    ///
    /// Both qualities use QL's `.thumbnail` representation type because
    /// `.all` returns the file icon for RAW files (the curled-paper
    /// graphic) instead of decoded image content — see the comment on
    /// `generateFullPreview` for details.
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
        // pixel-perfect rendering. 2.0 = up to 2x the requested pixel
        // dimension (e.g. 2400px request → up to 4800px bitmap for
        // retina).
        let effectiveScale = (quality == .fullSize) ? max(scale, 2.0) : scale
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxDimension, height: maxDimension),
            scale: effectiveScale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
            DispatchQueue.main.async {
                if let rep = rep {
                    handler(rep.nsImage)
                } else {
                    // QL failed to generate a thumbnail for this file.
                    // Log it so we can see which files are problematic.
                    NSLog("RawDeck: QL thumbnail failed for \(url.lastPathComponent): \(error?.localizedDescription ?? "no error")")
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