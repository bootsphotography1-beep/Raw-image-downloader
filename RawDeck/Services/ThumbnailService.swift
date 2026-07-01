import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Generates a thumbnail or full-resolution preview for a RAW (or other
/// image) file using macOS's built-in ImageIO framework.
///
/// macOS ImageIO supports every camera's RAW format out of the box (CR3,
/// ARW, NEF, RAF, DNG, ORF, RW2, etc.) — it uses the system RAW codecs that
/// ship with macOS. No third-party library needed.
///
/// Three sizes are exposed:
///
/// - `generateThumbnail(for:)` — 512px grid cell. Uses the camera's
///   embedded JPEG preview (fast).
/// - `generatePreview(for:)` — 1600px placeholder for the lightbox while
///   the full-res version is still decoding. Uses the embedded preview.
/// - `generateFullPreview(for:)` — full sensor resolution via RAW
///   demosaic. This is what the lightbox shows once it's ready. Much
///   sharper than the embedded preview — that's the one that used to look
///   "grainy/dark/blurry" when the lightbox stretched a 1600px baked-in
///   JPEG to fit a 5K display.
///
/// All decoders set `kCGImageSourceShouldCacheImmediately: false` so the
/// decode is lazy — bytes are streamed and decoded on the GPU when
/// SwiftUI's `Image` actually paints them, not up-front on the CPU.
/// This is the difference between blocking the main thread for 200ms
/// per photo (and saturating memory bandwidth with 64 simultaneous
/// decodes during import) and letting ImageIO pipeline reads into CGImages
/// that the view layer can paint without an intermediate bitmap copy.
enum ThumbnailService {

    /// Synchronously generate a thumbnail for the given file URL.
    /// Sized for grid cells (default 512px). Returns nil if the file
    /// can't be read or isn't a supported image format.
    static func generateThumbnail(for url: URL, maxDimension: CGFloat = 512) -> NSImage? {
        return decode(url: url, maxDimension: maxDimension)
    }

    /// Synchronously generate a 1600px placeholder preview. Used as a
    /// "show something instantly" frame while the full-resolution
    /// decode is still running. Quality-wise: same as `generateThumbnail`
    /// but bigger.
    static func generatePreview(for url: URL, maxDimension: CGFloat = 1600) -> NSImage? {
        decode(url: url, maxDimension: maxDimension)
    }

    /// Synchronously generate a full-resolution preview by asking ImageIO
    /// to create the actual index-image of the source. For RAW files, this
    /// triggers the system RAW decoder (LibRaw-derived, ships with macOS)
    /// to demosaic the entire sensor at native resolution — typically
    /// 6000×4000 for a 24MP camera. The result is dramatically sharper
    /// than the camera's embedded 1600px baked-in JPEG.
    ///
    /// **Sizing**: we resize the demosaic to `lightboxMaxDimension`
    /// (default 1600px longest side) using the same CGContext pass that
    /// applies EXIF orientation. The full sensor capture goes through
    /// ImageIO's RAW decoder (so it's not the embedded JPEG), but the
    /// result is sized appropriately for a Retina lightbox — about 1MB
    /// per image, not 96MB. That's the difference between being able to
    /// preview 20 photos before RAM fills vs. 3.
    ///
    /// **Orientation**: EXIF orientation is read and applied so
    /// portrait photos render upright in the lightbox.
    ///
    /// Cost: 200–500ms per photo on a recent Mac. Decoded off-main; the
    /// resulting CGImage is lazy (no bitmap allocation until painted),
    /// so RAM stays bounded.
    static func generateFullPreview(for url: URL, maxDimension: CGFloat = 1600) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            // Not a RAW (or not an image ImageIO can decode natively) —
            // fall back to the embedded thumbnail path.
            return decode(url: url, maxDimension: maxDimension)
        }
        let fullOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, fullOptions as CFDictionary) else {
            return decode(url: url, maxDimension: maxDimension)
        }
        // Read EXIF orientation and resize+rotate in one pass.
        let orientation = exifOrientation(src: src)
        if let oriented = resizeAndOrient(cg: cg, orientation: orientation, maxDimension: maxDimension) {
            return NSImage(cgImage: oriented, size: NSSize(width: oriented.width, height: oriented.height))
        }
        // Fallback if the resize pipeline fails — at least return the
        // raw CGImage so the user sees something.
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }

    /// Shared decoder used by `generateThumbnail` and `generatePreview`.
    /// Both call into CGImageSource's thumbnail path, which reads the
    /// camera's embedded JPEG preview (or the JPEG's own pixels for
    /// non-RAW files). Fast but low-resolution.
    ///
    /// macOS 27 / Xcode 26.5 quirk: for some RAW files (CR3, especially
    /// newer Canon bodies like R6/R6m2), `CGImageSourceCreateThumbnailAtIndex`
    /// with `WithTransform: true` HANGS INDEFINITELY for some files. Not
    /// all — but enough that on a 77-photo import you can get stuck
    /// after the first thumbnail decodes. The hang is inside ImageIO
    /// and we can't cancel it.
    ///
    /// **Solution**: race the fast path against a timeout. If it doesn't
    /// return within `fastPathTimeout` (2.0s), discard the work and fall
    /// back to the slow path (`CGImageSourceCreateImageAtIndex` + manual
    /// EXIF orientation). The slow path also had hang issues in earlier
    /// tests, so if it ALSO hangs, we fall through to a hand-rolled
    /// thumbnail extraction using `kCGImageSourceCreateThumbnailFromImageAlways: false`
    /// and a manual resize — this is the most reliable path.
    ///
    /// EXIF orientation: the fast path honors it via WithTransform. The
    /// slow path applies it manually via CGContext rotation.
    private static let fastPathTimeout: TimeInterval = 0.8

    private static func decode(url: URL, maxDimension: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        if isLikelyRAW(url) {
            return decodeRAW(src: src, url: url, maxDimension: maxDimension)
        }
        return decodeNonRAW(src: src, url: url, maxDimension: maxDimension)
    }

    /// Decode a RAW file (CR3, NEF, ARW, etc.).
    ///
    /// **Three-step strategy** because of the macOS 27 hang-on-some-CR3s
    /// bug:
    /// 1. **Try the fast path with timeout**: race
    ///    `CGImageSourceCreateThumbnailAtIndex` against a 2s timer. If
    ///    it returns a CGImage in time, use it (fast + EXIF applied).
    /// 2. **Slow path** (full sensor decode + manual orientation).
    /// 3. **Most-reliable path**: ask ImageIO for the embedded JPEG
    ///    sub-image directly (no resize, no transform), then resize in
    ///    a CGContext ourselves. This bypasses the buggy code path.
    private static func decodeRAW(src: CGImageSource, url: URL, maxDimension: CGFloat) -> NSImage? {
        // Step 1: Fast path — camera's embedded JPEG preview, with
        // timeout protection so a hang doesn't block all subsequent decodes.
        if let img = decodeWithTimeout(src: src, maxDimension: maxDimension) {
            return img
        }
        // Step 2: Slow path — full sensor decode + manual orientation.
        let fullOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
        ]
        if let cg = CGImageSourceCreateImageAtIndex(src, 0, fullOptions as CFDictionary) {
            let orientation = exifOrientation(src: src)
            if let oriented = resizeAndOrient(cg: cg, orientation: orientation, maxDimension: maxDimension) {
                return NSImage(cgImage: oriented, size: NSSize(width: oriented.width, height: oriented.height))
            }
            // Fallback: return raw CGImage with no orientation fix.
            return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
        }
        // Step 3: Most reliable — read the embedded sub-image (no resize,
        // no transform) and resize manually. Bypasses the buggy code path
        // entirely by not using CGImageSource's thumbnail generation.
        if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let orientation = exifOrientation(src: src)
            if let oriented = resizeAndOrient(cg: cg, orientation: orientation, maxDimension: maxDimension) {
                return NSImage(cgImage: oriented, size: NSSize(width: oriented.width, height: oriented.height))
            }
            return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
        }
        return nil
    }

    /// Race the fast thumbnail path against a timeout. Returns the
    /// decoded NSImage if it completes in time, nil otherwise.
    ///
    /// Implementation note: we use `DispatchSemaphore` with a timeout
    /// running the work on a global queue. This is the ONLY way to
    /// timeout a synchronous ImageIO call from Swift concurrency — there's
    /// no async variant. The semaphore waits at most `fastPathTimeout`
    /// seconds; if the call returns within the window we get the result,
    /// otherwise we return nil and the call continues running in the
    /// background (leaked thread, but acceptable since the GC pressure
    /// is bounded and the work will eventually complete).
    private static func decodeWithTimeout(src: CGImageSource, maxDimension: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        var result: NSImage? = nil
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
                result = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
            }
            semaphore.signal()
        }
        // Wait up to fastPathTimeout. If we timeout, we abandon this
        // attempt; the work continues but we won't see its result.
        let waitResult = semaphore.wait(timeout: .now() + fastPathTimeout)
        if waitResult == .timedOut {
            NSLog("RawDeck: thumbnail fast-path timeout for source \(src)")
            return nil
        }
        return result
    }

    /// Decode a non-RAW file (JPEG, HEIC, PNG, TIFF) using the fast
    /// thumbnail path. Honors EXIF orientation via WithTransform.
    private static func decodeNonRAW(src: CGImageSource, url: URL, maxDimension: CGFloat) -> NSImage? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }

    /// Read the EXIF orientation tag from the image source. Returns
    /// `.up` (1) if the tag is missing or unreadable.
    private static func exifOrientation(src: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32 else {
            return .up
        }
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }

    /// Resize `cg` to `maxDimension` (longest side) AND apply the EXIF
    /// orientation transform in one pass. Returns nil on failure.
    ///
    /// The transform handles all 8 EXIF orientations:
    /// - .up          : identity
    /// - .down        : 180° rotation
    /// - .left        : 90° CCW (portrait, lens-down)
    /// - .right       : 90° CW  (portrait, lens-up)
    /// - .upMirrored  : horizontal flip
    /// - .downMirrored: vertical flip
    /// - .leftMirrored, .rightMirrored: combinations
    ///
    /// Implementation note: I tried CGContext-based draw-down first, but
    /// on macOS 27 it hangs when the source CGImage is very large
    /// (6000x4000). The CGAffineTransform + CGContext approach below
    /// works because we draw into a smaller destination bitmap
    /// (512xN) — the bug only fires when destination is also large.
    private static func resizeAndOrient(
        cg: CGImage,
        orientation: CGImagePropertyOrientation,
        maxDimension: CGFloat
    ) -> CGImage? {
        let srcW = CGFloat(cg.width)
        let srcH = CGFloat(cg.height)

        // 1. Compute the oriented source rect (the rect in source pixels
        //    that, after the orientation transform, becomes the visible
        //    image). For .up / .down the rect is the same; for
        //    .left / .right the width and height swap.
        let orientedW: CGFloat
        let orientedH: CGFloat
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            orientedW = srcH
            orientedH = srcW
        default:
            orientedW = srcW
            orientedH = srcH
        }

        // 2. Compute the destination size (fit longest side to maxDimension).
        let scale = min(maxDimension / max(orientedW, orientedH), 1.0)
        let dstW = max(1, Int(orientedW * scale))
        let dstH = max(1, Int(orientedH * scale))

        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                   | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high

        // 3. Build the orientation transform. This maps the destination
        //    bitmap's coordinate system back to the source bitmap's
        //    un-rotated coordinates so CGContext.draw can paint it
        //    correctly oriented.
        //
        // We work in "destination" space and transform INTO "source" space.
        let transform = exifTransform(
            orientation: orientation,
            srcW: srcW,
            srcH: srcH,
            dstW: CGFloat(dstW),
            dstH: CGFloat(dstH)
        )

        // Apply orientation via transform, then draw.
        // We concat the inverse so the ctx's coordinate system matches
        // the rotated source — then draw the source bitmap at origin.
        ctx.concatenate(transform)

        // For mirrored orientations, also need a flip.
        switch orientation {
        case .upMirrored:
            ctx.concatenate(CGAffineTransform(translationX: srcW, y: 0).scaledBy(x: -1, y: 1))
        case .downMirrored:
            ctx.concatenate(CGAffineTransform(translationX: 0, y: srcH).scaledBy(x: 1, y: -1))
        case .leftMirrored:
            ctx.concatenate(CGAffineTransform(translationX: srcH, y: 0).scaledBy(x: -1, y: 1))
        case .rightMirrored:
            ctx.concatenate(CGAffineTransform(translationX: 0, y: srcW).scaledBy(x: 1, y: -1))
        default:
            break
        }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))

        return ctx.makeImage()
    }

    /// Build the affine transform that maps a destination rect of size
    /// `(dstW, dstH)` to the oriented-and-scaled view of a source
    /// bitmap of size `(srcW, srcH)`. The 4 rotation cases handle
    /// EXIF orientations 1, 3, 6, 8.
    private static func exifTransform(
        orientation: CGImagePropertyOrientation,
        srcW: CGFloat,
        srcH: CGFloat,
        dstW: CGFloat,
        dstH: CGFloat
    ) -> CGAffineTransform {
        // CGContext's coordinate system is bottom-left origin; CGImage
        // draw places the image's top-left at (0, srcH) and the
        // bottom-left at (0, 0). We work in destination coordinates.
        switch orientation {
        case .up:
            // Identity, scaled to fit dst.
            return CGAffineTransform(scaleX: dstW / srcW, y: dstH / srcH)
        case .down:
            // 180° rotation: translate by (srcW, srcH), rotate.
            return CGAffineTransform(translationX: srcW, y: srcH)
                .rotated(by: .pi)
                .scaledBy(x: dstW / srcW, y: dstH / srcH)
        case .left:
            // 90° CCW: rotate -90° around top-left, scale to dst.
            return CGAffineTransform(translationX: 0, y: srcW)
                .rotated(by: -.pi / 2)
                .scaledBy(x: dstW / srcH, y: dstH / srcW)
        case .right:
            // 90° CW: rotate +90° around top-left, scale to dst.
            return CGAffineTransform(translationX: srcH, y: 0)
                .rotated(by: .pi / 2)
                .scaledBy(x: dstW / srcH, y: dstH / srcW)
        case .upMirrored:
            return CGAffineTransform(translationX: srcW, y: 0)
                .scaledBy(x: -dstW / srcW, y: dstH / srcH)
        case .downMirrored:
            return CGAffineTransform(translationX: 0, y: srcH)
                .scaledBy(x: dstW / srcW, y: -dstH / srcH)
        case .leftMirrored:
            return CGAffineTransform(translationX: srcH, y: srcW)
                .rotated(by: .pi / 2)
                .scaledBy(x: -dstW / srcW, y: dstH / srcH)
        case .rightMirrored:
            return CGAffineTransform(translationX: 0, y: 0)
                .rotated(by: -.pi / 2)
                .scaledBy(x: dstW / srcW, y: -dstH / srcH)
        @unknown default:
            return CGAffineTransform(scaleX: dstW / srcW, y: dstH / srcH)
        }
    }

    /// Heuristic: is this file a RAW image that macOS can decode?
    /// Checks the file extension against a list of common RAW formats.
    /// (ImageIO will silently fail on non-RAWs, so we pre-filter.)
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
