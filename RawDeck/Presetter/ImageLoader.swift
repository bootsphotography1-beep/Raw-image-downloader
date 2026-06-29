import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// Decoded RGB pixel data from a reference image, in sRGB space.
///
/// We load via Core Graphics (CGImageSource → CGImage) rather than
/// Core Image (CIImage) because CGImage gives us direct access to
/// the raw pixel buffer in a known layout (RGBA8 or RGBAf). We then
/// drop the alpha channel and convert to a `[UInt8]` triple buffer
/// (R, G, B interleaved) for the stats module to consume.
///
/// Memory note: a 24-megapixel reference image is ~72 MB of RGBA8
/// data. We hold it all in memory because the statistics we compute
/// need to scan every pixel multiple times. For larger references,
/// consider downsampling first (see `ImageLoader.load(downsampledTo:)`).
struct DecodedImage {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    /// RGBA8 pixel data, 4 bytes per pixel. We keep alpha even though
    /// we ignore it for stats — keeps the layout simple (CGImage gives
    /// it to us in this format anyway).
    let pixels: Data

    var pixelCount: Int { width * height }

    /// Read a single channel value at (x, y). Alpha is ignored.
    func channel(_ c: Int, at x: Int, _ y: Int) -> UInt8 {
        let offset = y * bytesPerRow + x * 4 + c
        return pixels[pixels.startIndex + offset]
    }
}

enum ImageLoader {

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        case unsupportedFormat(String)
        case decodeFailed(String)

        var description: String {
            switch self {
            case .unreadable(let s): return "Image file not readable: \(s)"
            case .unsupportedFormat(let s): return "Unsupported image format: \(s)"
            case .decodeFailed(let s): return "Failed to decode image: \(s)"
            }
        }
    }

    /// Load an image file into a `DecodedImage`. Uses ImageIO for
    /// format detection (JPEG, PNG, HEIC, TIFF, etc.) and CGImage for
    /// the actual pixel decode.
    static func load(url: URL) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LoadError.unreadable(url.path)
        }
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw LoadError.decodeFailed(url.path)
        }
        return try decode(cgImage: cg)
    }

    /// Decode a CGImage into the pixel buffer. If the image is larger
    /// than `maxDimension` on either edge, downsample first to bound
    /// memory use. Default `maxDimension = 4000` keeps a 24 MP source
    /// to ~3 MP (12× less memory, still plenty of stats signal).
    static func load(url: URL, downsampledTo maxDimension: Int = 4000) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LoadError.unreadable(url.path)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw LoadError.decodeFailed(url.path)
        }
        return try decode(cgImage: cg)
    }

    /// Decode a CGImage into our internal buffer. We render to an
    /// RGBA8 bitmap context (the most universally-supported layout
    /// across color spaces). Wide-gamut images (P3, ProPhoto) get
    /// converted to sRGB at this step because that's what Camera
    /// Raw's slider values are calibrated for.
    ///
    /// Public so callers (e.g. `PresetterModel`) can pass a CGImage
    /// they've obtained from a non-URL source (clipboard paste, etc.).
    static func decode(cgImage: CGImage, maxDimension: Int = 4000) throws -> DecodedImage {
        // Downsample if needed. CGImageSourceCreateThumbnailAtIndex
        // requires a CGImageSource, which we don't have for an
        // already-decoded CGImage. Use vImage via CGImage's natural
        // scaling (CGContext draw with a smaller rect) — simple and
        // fast enough for a one-off analysis.
        let cg = downsample(cgImage: cgImage, maxDimension: maxDimension)

        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else {
            throw LoadError.decodeFailed("image has zero dimensions")
        }

        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: width * height * 4)

        // ColorSpace.genericRGBLinear would be the "right" choice for
        // scene-referred math, but Camera Raw's sliders operate in
        // display-referred sRGB. Match that here.
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        // ^ RGBA8 with alpha at the end. Premultiplied alpha doesn't
        //   matter for opaque images.

        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            throw LoadError.decodeFailed("could not create bitmap context")
        }

        // Draw the image into our buffer. The rect matches the image
        // dimensions; CGContext handles any color-space conversion
        // automatically.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        return DecodedImage(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(buffer)
        )
    }

    /// Downsample a CGImage so its longest edge is at most
    /// `maxDimension`. Returns the input unchanged if already small
    /// enough. Uses Core Graphics' interpolation-based scaling — fast
    /// and good enough for histogram analysis (we don't need pixel-
    /// perfect fidelity).
    private static func downsample(cgImage: CGImage, maxDimension: Int) -> CGImage {
        let w = cgImage.width
        let h = cgImage.height
        let longest = max(w, h)
        if longest <= maxDimension { return cgImage }
        let scale = Double(maxDimension) / Double(longest)
        let newW = max(1, Int(Double(w) * scale))
        let newH = max(1, Int(Double(h) * scale))

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return cgImage  // best-effort: keep original on failure
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? cgImage
    }
}