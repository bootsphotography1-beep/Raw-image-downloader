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
        // Some Canon CR3 files (and a handful of other RAWs) need
        // ImageIO to be told the source type up front before it'll
        // produce a CGImage. Without this hint, CGImageSourceCreateWithURL
        // can succeed but the thumbnail path returns nil. Using
        // kCGImageSourceTypeIdentifierHint with the file's UTI makes
        // ImageIO skip its magic-byte sniffing (which can miss CR3s
        // written by older Camera Connect utilities) and load the
        // proper RAW decoder.
        let typeHint: [CFString: Any] = [
            kCGImageSourceTypeIdentifierHint: UTType(filenameExtension: url.pathExtension.lowercased())?.identifier
                ?? UTType.image.identifier
        ]
        print("RawDeck: decode calling CGImageSourceCreateWithURL for \(url.lastPathComponent)")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, typeHint as CFDictionary) else {
            print("RawDeck: CGImageSourceCreateWithURL returned nil for \(url.lastPathComponent)")
            return nil
        }
        print("RawDeck: decode got image source for \(url.lastPathComponent), trying thumbnail")

        // Try the embedded-preview thumbnail first — fast path.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        print("RawDeck: decode calling CGImageSourceCreateThumbnailAtIndex path1 for \(url.lastPathComponent)")
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbnailOptions as CFDictionary) {
            print("RawDeck: decode path1 returned \(cg.width)x\(cg.height) for \(url.lastPathComponent)")
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        print("RawDeck: decode path1 returned nil for \(url.lastPathComponent), trying path2")

        // Fallback 1: full image at index 0 (forces the system RAW
        // decoder to demosaic; works for most CR3s whose embedded
        // preview is corrupt or absent).
        let fullOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        print("RawDeck: decode calling CGImageSourceCreateImageAtIndex path2 for \(url.lastPathComponent)")
        if let cg = CGImageSourceCreateImageAtIndex(src, 0, fullOptions as CFDictionary) {
            print("RawDeck: decode path2 returned \(cg.width)x\(cg.height) for \(url.lastPathComponent)")
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        print("RawDeck: decode path2 returned nil for \(url.lastPathComponent), trying path3")

        // Fallback 2: create a thumbnail from the full image using
        // kCGImageSourceCreateThumbnailFromImageIfAbsent. This is the
        // last-resort path for Canon CR3s where both the embedded
        // preview AND the direct-index decode return nil.
        let lastResortOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        print("RawDeck: decode calling CGImageSourceCreateThumbnailAtIndex path3 for \(url.lastPathComponent)")
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, lastResortOptions as CFDictionary) {
            print("RawDeck: decode path3 recovered \(cg.width)x\(cg.height) for \(url.lastPathComponent)")
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }

        print("RawDeck: all thumbnail decode paths failed for \(url.lastPathComponent)")
        return nil
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
