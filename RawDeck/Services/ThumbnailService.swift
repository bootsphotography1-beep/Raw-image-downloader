import Foundation
import AppKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
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
    /// Routes through `CIRAWFilter` (Apple's RAW decoder) when the
    /// file is a RAW format AND CIRAWFilter can be instantiated.
    /// CIRAWFilter actually demosaics the sensor pixels using
    /// Apple's RAW codec and renders to a `CIImage`, then we pull
    /// out a CGImage at the requested max dimension. This is what
    /// Photos.app uses for its RAW viewer — sharp, properly
    /// color-managed, no upscaling artifacts from the embedded JPEG.
    ///
    /// Falls back to `QLThumbnailGenerator` with `.thumbnail`
    /// representation for non-RAW files (JPEG, HEIC, TIFF, PNG) and
    /// for the rare case where CIRAWFilter refuses a particular RAW
    /// variant. The fallback uses the same `.thumbnail`
    /// representation we use for grid cells but at a larger
    /// requested size so QL scales its decoded preview bitmap to
    /// fit. Sharp on Retina, but for RAW files it's actually
    /// decoding the embedded JPEG preview — which is why CIRAW is
    /// preferred for RAW.
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
    static func generateFullPreview(for url: URL, maxDimension: CGFloat = 2400) async -> NSImage? {
        if isLikelyRAW(url) {
            if let ciRaw = await generatePreviewViaCIRAW(url: url, maxDimension: maxDimension) {
                return ciRaw
            }
            // CIRAW refused — fall through to QL.
        }
        return await withCheckedContinuation { continuation in
            generateThumbnailAsync(url: url, maxDimension: maxDimension, quality: .fullSize) { img in
                continuation.resume(returning: img)
            }
        }
    }

    /// Decode a RAW via `CIRAWFilter` (Apple's RAW decoder) and
    /// return an `NSImage` at the requested max dimension. Returns
    /// nil if CIRAWFilter isn't available on this macOS version, or
    /// if it can't process the file (e.g. unsupported variant, file
    /// unreadable).
    ///
    /// Why CIRAWFilter matters: it does a real sensor demosaic with
    /// proper color management (sRGB / Display P3 / ProPhoto depending
    /// on the embedded ICC profile). The QL path we used before
    /// returned the camera's *embedded JPEG preview*, which is a
    /// lossy-compressed 1620×1080 image baked into the RAW at capture
    /// time. On a 5K iMac fullscreen lightbox, that embedded JPEG
    /// looked visibly blurry.
    ///
    /// Cost: 100–400ms per photo on a recent Mac (M-series). Memory
    /// usage peaks at ~150MB for a 24MP RAW during demosaic, then
    /// drops to ~50MB for the output CGImage.
    private static func generatePreviewViaCIRAW(url: URL, maxDimension: CGFloat) async -> NSImage? {
        // CIRAWFilter exists on macOS 10.14+ but is best on 13+. The
        // generator must be created on a background thread (it's
        // synchronous and we want off-main work). Render happens on
        // an arbitrary CIContext (we use Metal-backed for speed).
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let filter = CIFilter(imageURL: url) else {
                return nil
            }
            // Identify ourselves so anyone debugging CI internals
            // sees this is RawDeck driving the decoder.
            filter.name = "RawDeck CIRAW"

            guard let rawImage = filter.outputImage else {
                return nil
            }

            // Scale the CIImage down to the requested max dimension
            // before rasterizing — saves both RAM and time. We use
            // a Lanczos-style filter for downsampling.
            let extent = rawImage.extent
            let longestSide = max(extent.width, extent.height)
            guard longestSide > 0 else { return nil }
            let scale = min(maxDimension / longestSide, 1.0)
            let scaled: CIImage
            if scale < 1.0 {
                scaled = rawImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            } else {
                scaled = rawImage
            }

            // Render into a CGImage. Use a Metal-backed context for
            // speed; fall back to software if Metal isn't available.
            let ctx = CIContext(options: [.useSoftwareRenderer: false])
            guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else {
                return nil
            }

            let outSize = NSSize(width: scaled.extent.width, height: scaled.extent.height)
            return NSImage(cgImage: cg, size: outSize)
        }.value
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

        /// Diagnostics-aware variant of `generateThumbnail`. Calls back
        /// with BOTH the result image (or nil) AND a human-readable
        /// string explaining why each fallback path failed. Used by
        /// `PhotoStore.decodeOneThumbnail` so failed files surface a
        /// reason instead of a silent broken-image icon.
        ///
        /// The reason string is one of:
        /// - `nil` when the image was generated successfully.
        /// - `"QL: <error>"` when the first QL attempt failed.
        /// - `"QL(small): <error>"` when the smaller QL attempt also failed.
        /// - `"CR3 embedded preview: no JPEG marker"` etc. for CR3 extraction.
        /// - `"All decode paths timed out (Ns)"` if we never even got a callback.
        static func generateThumbnailAsyncForDiagnostics(
            url: URL,
            maxDimension: CGFloat = 512,
            handler: @escaping (NSImage?, String?) -> Void
        ) {
            var firstReason: String? = nil
            // Path 1: standard QL
            generateThumbnailAsync(url: url, maxDimension: maxDimension) { img in
                if let img = img {
                    handler(img, nil)
                    return
                }
                firstReason = "QL primary failed"
                // Path 2: smaller QL (cold-cache workaround)
                generateThumbnailAsync(url: url, maxDimension: 256) { img in
                    if let img = img {
                        handler(img, nil)
                        return
                    }
                    // Path 3: CR3 embedded JPEG extraction
                    if url.pathExtension.lowercased() == "cr3" {
                        if let img = extractCR3EmbeddedPreview(url: url, maxDimension: maxDimension) {
                            handler(img, nil)
                            return
                        }
                        handler(nil, "QL primary failed; QL(small) failed; CR3 embedded JPEG not found")
                        return
                    }
                    handler(nil, "QL primary failed; QL(small) failed; not a CR3 so no embedded-preview fallback")
                }
            }
        }

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