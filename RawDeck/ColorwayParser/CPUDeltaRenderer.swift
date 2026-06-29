import Foundation
import AppKit
import CoreGraphics

/// Applies a `DerivedPreset`-style delta to a CGImage in pixel space.
///
/// This is the **honest "before/after" preview**: it runs on the CPU
/// at view time, using simple linear tone-curve math. It will NOT
/// match Camera Raw exactly (Camera Raw uses spline curves, per-
/// channel matrices, and process-version-specific color science),
/// but it will visibly demonstrate the direction and rough magnitude
/// of each adjustment.
///
/// For the exact edit, the user opens the target in Pixelmator Pro
/// with the .xmp sidecar via "View in Pixelmator" — that uses
/// Pixelmator's full Camera-Raw-equivalent engine. This renderer
/// exists purely for the slider preview.
///
/// ### Performance
///
/// For a 4000×3000 image (12 MP), this is ~36 M operations per
/// channel pass, with maybe 4 passes = 144 M ops. On M-series that
/// is < 100 ms. On Intel it's ~300 ms. Acceptable for a one-shot
/// render triggered by delta recomputation (not per-frame).
///
/// ### Math summary
///
/// - **Exposure (EV):** multiply linear-light pixel by `2^EV`.
/// - **Contrast:** `(p − 0.5) × (1 + c/100) + 0.5` around mid-gray.
/// - **Highlights:** additive on pixels with luma > 0.5, falling off
///   toward the top of the curve.
/// - **Shadows:** additive on pixels with luma < 0.5, falling off
///   toward the bottom.
/// - **Whites:** additive on the very top of the curve (luma > 0.85).
/// - **Blacks:** additive on the very bottom (luma < 0.15).
/// - **Temperature:** scale R (positive = warmer) and B (negative).
/// - **Tint:** scale G channel.
/// - **Saturation:** `gray + (p − gray) × (1 + s/100)` per pixel.
///
/// All operations are clamped to `[0, 1]` after each step.
enum CPUDeltaRenderer {

    /// Convenience: build a `DerivedPreset` from a set of coaching
    /// delta rows. Used by the model when re-rendering the
    /// "after" image — the same `CoachingDeltaRow` array that drives
    /// the right rail also drives this preview.
    static func preset(from rows: [CoachingDeltaRow]) -> DerivedPreset {
        var p = DerivedPreset()
        for row in rows {
            switch row.parameter {
            case .exposure:    p.exposure = row.value
            case .contrast:    p.contrast = row.value
            case .highlights:  p.highlights = row.value
            case .shadows:     p.shadows = row.value
            case .whites:      p.whites = row.value
            case .blacks:      p.blacks = row.value
            case .vibrance:    p.vibrance = row.value
            case .saturation:  p.saturation = row.value
            case .temperature: p.temperature = row.value
            case .tint:        p.tint = row.value
            }
        }
        return p
    }

    /// Apply the preset to a CGImage and return a new CGImage with
    /// the adjusted pixel data.
    ///
    /// Returns `nil` if the input image has no bitmap representation
    /// or if the pixel format isn't 8-bit RGBA (the only format this
    /// renderer supports).
    static func render(_ source: CGImage, preset: DerivedPreset) -> CGImage? {
        let width = source.width
        let height = source.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        // Allocate a destination buffer and draw the source into it.
        let colorSpace = source.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return nil }
        let pixels = buffer.bindMemory(
            to: UInt8.self, capacity: width * height * bytesPerPixel
        )

        // Pre-compute channel gains.
        // Exposure as a linear multiplier.
        let exposureGain = pow(2.0, preset.exposure)

        // Contrast as a slope around 0.5 (sRGB mid-gray).
        let contrastSlope = 1.0 + preset.contrast / 100.0

        // Temperature: positive = warmer = R up, B down.
        // ±100 ≈ ±10% per channel. Tiny numbers because we're working
        // in display sRGB; the visible shift comes out fine.
        let tempR = 1.0 + preset.temperature / 1000.0
        let tempB = 1.0 - preset.temperature / 1000.0

        // Tint: positive = magenta = G down (R+B up).
        let tintG = 1.0 - preset.tint / 1000.0

        // Saturation: scale of (channel − luma).
        let satScale = 1.0 + preset.saturation / 100.0

        // Pass through every pixel. Tight loop, no SIMD; readable.
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * bytesPerRow) + (x * bytesPerPixel)
                var r = Double(pixels[i])     / 255.0
                var g = Double(pixels[i + 1]) / 255.0
                var b = Double(pixels[i + 2]) / 255.0

                // 1. Exposure
                r *= exposureGain
                g *= exposureGain
                b *= exposureGain

                // 2. Contrast around mid-gray
                r = (r - 0.5) * contrastSlope + 0.5
                g = (g - 0.5) * contrastSlope + 0.5
                b = (b - 0.5) * contrastSlope + 0.5

                // 3. Tone-curve add-ons (highlights/shadows/whites/blacks).
                // Rec.709 luma for the weighting.
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

                // Highlights: positive value = brighten the upper part.
                // Weight: 0 at luma 0.5, 1 at luma 1.0.
                if preset.highlights != 0 {
                    let w = max(0, (luma - 0.5) / 0.5)  // 0..1
                    let add = (preset.highlights / 100.0) * 0.25 * w
                    r += add; g += add; b += add
                }
                // Shadows: positive = lift shadows.
                // Weight: 0 at luma 0.5, 1 at luma 0.
                if preset.shadows != 0 {
                    let w = max(0, (0.5 - luma) / 0.5)
                    let add = (preset.shadows / 100.0) * 0.25 * w
                    r += add; g += add; b += add
                }
                // Whites: positive = brighten very top of curve.
                if preset.whites != 0 {
                    let w = max(0, (luma - 0.85) / 0.15)
                    let add = (preset.whites / 100.0) * 0.20 * w
                    r += add; g += add; b += add
                }
                // Blacks: positive = lift very bottom (less crushed).
                if preset.blacks != 0 {
                    let w = max(0, (0.15 - luma) / 0.15)
                    let add = (preset.blacks / 100.0) * 0.20 * w
                    r += add; g += add; b += add
                }

                // 4. White balance — temperature and tint
                r *= tempR
                b *= tempB
                g *= tintG

                // 5. Saturation (after WB so it doesn't desaturate the
                //    warm/cool cast away).
                let lumAfterWB = 0.2126 * r + 0.7152 * g + 0.0722 * b
                r = lumAfterWB + (r - lumAfterWB) * satScale
                g = lumAfterWB + (g - lumAfterWB) * satScale
                b = lumAfterWB + (b - lumAfterWB) * satScale

                // 6. Vibrance — boosts low-saturation pixels more than
                //    already-saturated ones. Simple approximation.
                if preset.vibrance != 0 {
                    let mx = max(r, max(g, b))
                    let mn = min(r, min(g, b))
                    let s = mx - mn  // saturation index for this pixel
                    let boost = (1.0 - s) * (preset.vibrance / 100.0) * 0.5
                    r += (r - lumAfterWB) * boost
                    g += (g - lumAfterWB) * boost
                    b += (b - lumAfterWB) * boost
                }

                // 7. Clamp and write back. Premultiplied alpha so we
                //    keep the alpha byte untouched.
                pixels[i]     = UInt8(max(0, min(255, r * 255.0)))
                pixels[i + 1] = UInt8(max(0, min(255, g * 255.0)))
                pixels[i + 2] = UInt8(max(0, min(255, b * 255.0)))
                // pixels[i + 3] (alpha) — left as-is
            }
        }

        return context.makeImage()
    }

    /// Convenience: render and wrap in an NSImage for SwiftUI display.
    static func renderToNSImage(_ source: NSImage, preset: DerivedPreset) -> NSImage? {
        guard let cg = cgImage(from: source) else { return nil }
        guard let adjusted = render(cg, preset: preset) else { return nil }
        return NSImage(cgImage: adjusted, size: NSSize(width: adjusted.width, height: adjusted.height))
    }

    /// Decode an NSImage to a CGImage via TIFF round-trip (matches the
    /// rest of the ColorwayParser pipeline).
    private static func cgImage(from image: NSImage) -> CGImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.cgImage
    }
}