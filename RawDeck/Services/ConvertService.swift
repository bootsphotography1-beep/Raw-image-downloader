import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Batch-convert RAW photos to JPG.
///
/// **Why JPG and not the originals:** the existing `ExportService` already
/// does "copy the .cr3/.nef/.arw bytes verbatim." This service is for the
/// *other* hand-off — when the user wants a JPG deliverable (web upload,
/// client preview, social-media post, Lightroom import) without opening
/// Pixelmator for every file.
///
/// **Why CIRAWFilter, not ImageIO / CGImageSource:**
/// The project's `ThumbnailService` documents that `CGImageSourceCreateWithURL`
/// hangs on Canon CR3 files on macOS 27. We use the same `CIFilter(imageURL:)`
/// path that `generateFullPreview` uses for the lightbox: it instantiates
/// Apple's RAW codec, does a real sensor demosaic with proper color
/// management (sRGB / Display P3 from the embedded ICC profile), and gives
/// back a `CIImage` we can rasterize at full sensor resolution.
///
/// For non-RAW files (JPEG / HEIC / TIFF / PNG already in the library),
/// we fall through to `CGImageSourceCreateImageAtIndex` — those are the
/// formats ImageIO handles correctly, and they're typically the user's
/// "I already edited this" files.
///
/// **Memory cost per file:**
/// 24MP RAW → ~150 MB peak during demosaic, drops to ~50 MB for the output
/// CGImage. We process files **serially** (one at a time) inside the
/// detached task so a 300-photo batch stays within budget. Parallel
/// processing would multiply RAM by the concurrency factor.
///
/// **Threading:**
/// Pure off-main. Caller (`PhotoStore.convertSelection`) wraps us in a
/// `Task.detached` and publishes progress + the final result on MainActor.
enum ConvertService {

    /// Result of a convert operation, surfaced to the user via an alert.
    struct ConvertResult: Sendable {
        var converted: Int = 0
        var failed: Int = 0
        var skipped: Int = 0   // already-existed destinations we didn't overwrite
        var totalBytes: Int = 0
        var firstError: String? = nil
    }

    /// JPG quality slider. 0.0 = worst, 1.0 = lossless (not what we want;
    /// the encoder still has to quantize). 0.92 is the project default —
    /// visually indistinguishable from higher, ~30% smaller files than 0.95.
    static let defaultQuality: Double = 0.92

    /// Maximum pixel dimension for the long edge. Most user destinations
    /// (Instagram, client proofs, web galleries) don't need 24MP JPGs —
    /// 6000px is a reasonable ceiling that keeps file sizes sane while
    /// staying well above any normal display resolution. Pass `nil` to
    /// keep full sensor resolution.
    static let defaultMaxLongEdge: CGFloat? = 6000

    /// Convert `urls` to JPGs in `destinationFolder`.
    ///
    /// - `quality`: 0.0...1.0 JPEG quality
    /// - `maxLongEdge`: clamp the long edge to this many pixels; `nil` for full-res
    /// - `overwrite`: if false (default), existing `.jpg` files are skipped
    /// - `onProgress`: optional callback fired after each file (off-main).
    ///   Caller is responsible for throttling the hop to MainActor if it
    ///   publishes a `@Published` value.
    static func convert(
        urls: [URL],
        to destinationFolder: URL,
        quality: Double = defaultQuality,
        maxLongEdge: CGFloat? = defaultMaxLongEdge,
        overwrite: Bool = false,
        onProgress: ((Int) -> Void)? = nil
    ) -> ConvertResult {
        var result = ConvertResult()
        let fm = FileManager.default

        // Destination sanity check. Cheap, and saves a confusing
        // CGImageDestinationCreateWithURL failure if someone wires
        // this up to a text-field path later.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destinationFolder.path, isDirectory: &isDir),
              isDir.boolValue else {
            result.failed = urls.count
            result.firstError = "Destination is not a folder: \(destinationFolder.path)"
            return result
        }

        // Single CIContext for the whole batch — creating one per file
        // is expensive (Metal device initialization). Metal-backed is
        // 5–10× faster than software; fall back if Metal isn't available.
        let ctx = CIContext(options: [.useSoftwareRenderer: false])

        for src in urls {
            let dst = uniqueDestination(for: src, in: destinationFolder, ext: "jpg")
            if dst == nil {
                // Skipped because overwrite=false and the file exists.
                result.skipped += 1
                onProgress?(result.converted + result.failed + result.skipped)
                continue
            }
            guard let dst = dst else { continue }

            do {
                try writeOne(
                    source: src,
                    destination: dst,
                    ciContext: ctx,
                    quality: quality,
                    maxLongEdge: maxLongEdge
                )
                result.converted += 1
                result.totalBytes += (try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            } catch {
                result.failed += 1
                if result.firstError == nil {
                    result.firstError = "\(src.lastPathComponent): \(error.localizedDescription)"
                }
                NSLog("RawDeck: convert failed for \(src.lastPathComponent): \(error)")
                // Best-effort cleanup: remove the half-written file if
                // CGImageDestinationFinalize left anything behind.
                try? fm.removeItem(at: dst)
            }
            onProgress?(result.converted + result.failed + result.skipped)
        }

        return result
    }

    // MARK: - Single-file conversion

    /// Decode `source` and write a JPG to `destination`. Throws on any
    /// failure so the caller can attribute the error to a specific file.
    ///
    /// Pipeline:
    /// 1. RAW → CIImage via `CIFilter(imageURL:)` (Apple's RAW codec)
    /// 2. (optional) Downscale CIImage if `maxLongEdge` is set
    /// 3. CIImage → CGImage via the Metal-backed context
    /// 4. CGImage → file via `CGImageDestinationCreateWithURL` (the
    ///    supported ImageIO path; CGImageDestination is *not* the same
    ///    code path that hangs on CGImageSourceCreateWithURL for CR3)
    private static func writeOne(
        source: URL,
        destination: URL,
        ciContext: CIContext,
        quality: Double,
        maxLongEdge: CGFloat?
    ) throws {
        let cg = try decodeCGImage(source: source, ciContext: ciContext, maxLongEdge: maxLongEdge)

        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ConvertError.couldNotCreateDestination(destination.path)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // Progressive encoding: web galleries load a blurry preview
            // first then sharpen. Negligible cost, free UX win for any
            // web-bound JPG. Strip this if it ever shows up in profiles.
            kCGImagePropertyJFIFIsProgressive: true,
        ]
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConvertError.encodeFailed(destination.path)
        }
    }

    /// RAW → CGImage via CIRAWFilter, or non-RAW → CGImage via CGImageSource.
    /// Throws if both paths fail (or if the file isn't readable).
    private static func decodeCGImage(
        source: URL,
        ciContext: CIContext,
        maxLongEdge: CGFloat?
    ) throws -> CGImage {
        let ext = source.pathExtension.lowercased()
        let isRAW = ThumbnailService.isLikelyRAW(source)

        if isRAW {
            guard let filter = CIFilter(imageURL: source) else {
                throw ConvertError.cirawUnavailable(source.lastPathComponent)
            }
            filter.name = "RawDeck Convert"
            guard let ci = filter.outputImage else {
                throw ConvertError.cirawReturnedNil(source.lastPathComponent)
            }
            let scaled = downscale(ci, maxLongEdge: maxLongEdge)
            guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else {
                throw ConvertError.rasterizeFailed(source.lastPathComponent)
            }
            return cg
        }

        // Non-RAW: use CGImageSource. This is the path that hangs on CR3,
        // but CR3 is RAW (handled above). JPEG/HEIC/TIFF/PNG are fine here.
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConvertError.decodeFailed(source.lastPathComponent)
        }
        // For non-RAW we still respect maxLongEdge. CGImage downscaling
        // uses CGContext, which is straightforward.
        if let maxLE = maxLongEdge,
           CGFloat(max(cg.width, cg.height)) > maxLE {
            return try downscaleCGImage(cg, maxLongEdge: maxLE)
        }
        return cg
    }

    /// Scale a CIImage down so its long edge ≤ `maxLongEdge`. Identity
    /// if `maxLongEdge` is nil or the image already fits.
    private static func downscale(_ ci: CIImage, maxLongEdge: CGFloat?) -> CIImage {
        guard let maxLE = maxLongEdge else { return ci }
        let extent = ci.extent
        let longest = max(extent.width, extent.height)
        guard longest > maxLE else { return ci }
        let scale = maxLE / longest
        return ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// CGImage downscale via CGContext. Used for non-RAW files where we
    /// already have a CGImage from CGImageSource.
    private static func downscaleCGImage(_ cg: CGImage, maxLongEdge: CGFloat) throws -> CGImage {
        let srcW = CGFloat(cg.width)
        let srcH = CGFloat(cg.height)
        let longest = max(srcW, srcH)
        guard longest > maxLongEdge else { return cg }
        let scale = maxLongEdge / longest
        let dstW = max(1, Int(srcW * scale))
        let dstH = max(1, Int(srcH * scale))
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
            throw ConvertError.rasterizeFailed("downscale context")
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let out = ctx.makeImage() else {
            throw ConvertError.rasterizeFailed("downscale makeImage")
        }
        return out
    }

    /// Compute the destination URL for a `.jpg` rendition of `source`,
    /// picking a non-colliding name. Returns `nil` if the file already
    /// exists and `overwrite` is false (caller should treat as "skipped").
    ///
    /// Mirrors `ExportService.uniqueDestination` but hardcodes the `.jpg`
    /// extension and adds the overwrite check. Kept here rather than
    /// generalized on `ExportService` to avoid touching a working file
    /// unrelated to this feature.
    static func uniqueDestination(
        for source: URL,
        in folder: URL,
        ext: String,
        overwrite: Bool = false
    ) -> URL? {
        let fm = FileManager.default
        let stem = source.deletingPathExtension().lastPathComponent

        let primary = folder.appendingPathComponent("\(stem).\(ext)")
        if !fm.fileExists(atPath: primary.path) {
            return primary
        }
        if !overwrite {
            return nil  // signal skip
        }

        for n in 1...9999 {
            let candidate = folder.appendingPathComponent("\(stem)-\(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let uuid = UUID().uuidString.prefix(8)
        return folder.appendingPathComponent("\(stem)-\(uuid).\(ext)")
    }

    /// Errors surfaced to the user. `localizedDescription` is human-friendly.
    enum ConvertError: LocalizedError {
        case cirawUnavailable(String)
        case cirawReturnedNil(String)
        case decodeFailed(String)
        case rasterizeFailed(String)
        case couldNotCreateDestination(String)
        case encodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cirawUnavailable(let name):
                return "\(name): macOS RAW decoder refused this file (unsupported variant or corrupt)"
            case .cirawReturnedNil(let name):
                return "\(name): RAW decoder returned no image"
            case .decodeFailed(let name):
                return "\(name): couldn't decode (unsupported format or corrupt file)"
            case .rasterizeFailed(let name):
                return "\(name): failed to rasterize to JPG"
            case .couldNotCreateDestination(let path):
                return "Couldn't create destination: \(path)"
            case .encodeFailed(let path):
                return "JPG encoder failed for \(path)"
            }
        }
    }
}
