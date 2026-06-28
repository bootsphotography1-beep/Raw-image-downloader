import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Generates a thumbnail for a RAW file using macOS's built-in RAW decoder.
///
/// macOS's ImageIO framework supports every camera's RAW format out of the box
/// (CR3, ARW, NEF, RAF, DNG, ORF, RW2, etc.) — it uses the system RAW codecs
/// that ship with macOS. No third-party library needed.
///
/// We ask for a 512px preview, which is plenty for a thumbnail grid and
/// renders fast even for 1000+ files.
enum ThumbnailService {

    /// Synchronously generate a thumbnail for the given RAW file URL.
        /// Returns nil if the file can't be read or isn't a supported RAW format.
        static func generateThumbnail(for url: URL, maxDimension: CGFloat = 512) -> NSImage? {
            decode(url: url, maxDimension: maxDimension)
        }

        /// Synchronously generate a larger preview suitable for the full-screen
        /// lightbox view. 1600px on the long edge is plenty for a Retina display
        /// without paying the cost of a full RAW decode on every navigation.
        static func generatePreview(for url: URL, maxDimension: CGFloat = 1600) -> NSImage? {
            decode(url: url, maxDimension: maxDimension)
        }

        /// Shared decoder used by both thumbnail and preview generation.
        /// Returns nil if the file can't be read or isn't a supported RAW format.
        private static func decode(url: URL, maxDimension: CGFloat) -> NSImage? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                return nil
            }
            let size = NSSize(width: cg.width, height: cg.height)
            return NSImage(cgImage: cg, size: size)
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
