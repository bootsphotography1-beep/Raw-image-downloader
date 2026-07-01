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
        decode(url: url, maxDimension: maxDimension)
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
    /// Cost: 200–500ms per photo on a recent Mac. Decoded off-main; the
    /// resulting CGImage is lazy (no bitmap allocation until painted),
    /// so RAM stays bounded.
    static func generateFullPreview(for url: URL) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary) else {
            // Not a RAW (or not an image ImageIO can decode natively) —
            // fall back to the embedded thumbnail at 2400px so non-RAW
            // files (JPEG/HEIC/TIFF/PNG) still look good in the lightbox.
            return decode(url: url, maxDimension: 2400)
        }
        let size = NSSize(width: cg.width, height: cg.height)
        return NSImage(cgImage: cg, size: size)
    }

    /// Shared decoder used by `generateThumbnail` and `generatePreview`.
    /// Both call into CGImageSource's thumbnail path, which reads the
    /// camera's embedded JPEG preview (or the JPEG's own pixels for
    /// non-RAW files). Fast but low-resolution.
    ///
    /// `shouldCacheImmediately: true` makes ImageIO materialise the
    /// bitmap up-front. The lazy variant (`false`) causes ImageIO to
    /// return nil for some RAW formats — particularly CR3 on certain
    /// macOS versions — even when the embedded preview is fine. The
    /// cost of eager caching is one extra bitmap allocation per file
    /// (here, ~1MB for a 512px thumbnail); the benefit is that
    /// `CGImageSourceCreateThumbnailAtIndex` actually returns a
    /// CGImage we can wrap in an NSImage and hand to SwiftUI.
    private static func decode(url: URL, maxDimension: CGFloat) -> NSImage? {
        print("RawDeck: decode enter url=\(url.lastPathComponent) ext=\(url.pathExtension)")
        // macOS 27 / Xcode 26.5 ImageIO bug: for Canon CR3 files,
        // CGImageSourceCreateThumbnailAtIndex hangs indefinitely.
        // We confirmed this with line-by-line logging — every CR3
        // decode stalls at path1 regardless of `shouldCacheImmediately`
        // value. So for RAW formats we skip the thumbnail path entirely
        // and go straight to CGImageSourceCreateImageAtIndex (full image)
        // + manual downscale.
        print("RawDeck: decode calling CGImageSourceCreateWithURL for \(url.lastPathComponent)")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            print("RawDeck: CGImageSourceCreateWithURL returned nil for \(url.lastPathComponent)")
            return nil
        }
        print("RawDeck: decode got image source for \(url.lastPathComponent)")

        if isLikelyRAW(url) {
            print("RawDeck: decode RAW branch for \(url.lastPathComponent) — skipping thumbnail path")
            // RAW: get the full decoded image.
            // shouldCacheImmediately: false to avoid any eager-cache hangs.
            let fullOptions: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: false,
            ]
            print("RawDeck: decode calling CGImageSourceCreateImageAtIndex for \(url.lastPathComponent)")
            if let cg = CGImageSourceCreateImageAtIndex(src, 0, fullOptions as CFDictionary) {
                print("RawDeck: decode full-image returned \(cg.width)x\(cg.height) for \(url.lastPathComponent)")
                // Skip the manual downscale (it was hanging on macOS 27).
                // Hand SwiftUI the full CGImage and let Image(nsImage:)
                // scale it on the GPU during paint — slightly more work
                // per paint but reliable. The grid cell's
                // .resizable().aspectRatio(contentMode: .fit) handles
                // the scaling at draw time.
                let size = NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
                let img = NSImage(cgImage: cg, size: size)
                print("RawDeck: decode wrapped full-image as NSImage for \(url.lastPathComponent)")
                return img
            }
            print("RawDeck: decode full-image returned nil for \(url.lastPathComponent)")
            return nil
        }

        // Non-RAW (JPEG, HEIC, PNG, TIFF, etc.): the thumbnail path is
        // fast and reliable on macOS 27. No need to downscale manually.
        print("RawDeck: decode non-RAW branch for \(url.lastPathComponent) — trying thumbnail")
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        print("RawDeck: decode calling CGImageSourceCreateThumbnailAtIndex for \(url.lastPathComponent)")
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbnailOptions as CFDictionary) {
            print("RawDeck: decode thumbnail returned \(cg.width)x\(cg.height) for \(url.lastPathComponent)")
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        print("RawDeck: all decode paths failed for \(url.lastPathComponent)")
        return nil
    }

    /// Downscale a CGImage to `maxDimension` (longest side) using an
    /// off-screen bitmap draw. Used by `decode(path2)` when we get the
    /// full-resolution RAW back — we don't want to hand SwiftUI a
    /// 6000×4000 image it has to scale every paint.
    private static func scaledNSImage(from cg: CGImage, maxDimension: CGFloat) -> NSImage {
        let cw = CGFloat(cg.width)
        let ch = CGFloat(cg.height)
        let scale = min(maxDimension / max(cw, ch), 1.0)
        let w = Int(cw * scale)
        let h = Int(ch * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return NSImage(cgImage: cg, size: NSSize(width: cw, height: ch))
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else {
            return NSImage(cgImage: cg, size: NSSize(width: cw, height: ch))
        }
        return NSImage(cgImage: scaled, size: NSSize(width: CGFloat(w), height: CGFloat(h)))
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
