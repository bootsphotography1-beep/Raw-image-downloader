import Foundation

/// Aggregate statistics of a decoded reference image, in sRGB display-
/// referred space (0-255 per channel). Everything `PresetMapper`
/// needs to derive Camera Raw slider values lives here.
///
/// We compute:
/// - Per-channel mean (R, G, B) — for white-balance estimation
/// - Luminance mean — for exposure
/// - Luminance stddev — for contrast
/// - Histogram (256 bins, luma) — for tone-curve approximation
/// - Highlight clipping % — for "Highlights" recovery
/// - Shadow clipping % — for "Shadows" lift
/// - Whites endpoint — for "Whites" slider
/// - Blacks endpoint — for "Blacks" slider
/// - Saturation index — for "Vibrance" / "Saturation"
///
/// Performance: this scans every pixel ~5 times (once per stat).
/// For a 3 MP downsampled reference that's ~15 M operations — fast
/// enough (~50 ms on M1) to not need Accelerate/vImage SIMD. We keep
/// the loops plain Swift so the code is readable. If profiling
/// shows it's a bottleneck, swap in vImageHistogramCalculation_ARGB8888
/// + vImageMeanFilter_ARGB8888 etc.
struct ImageStats {
    let meanR: Double
    let meanG: Double
    let meanB: Double
    let meanLuma: Double          // Rec.709 luma: 0.2126 R + 0.7152 G + 0.0722 B
    let stddevLuma: Double
    /// 256-bin histogram of luma values (0..255), normalized to sum=1.
    let histogram: [Double]
    /// Fraction of pixels with luma ≥ 252 (out of 1.0).
    let highlightClipFraction: Double
    /// Fraction of pixels with luma ≤ 3 (out of 1.0).
    let shadowClipFraction: Double
    /// Histogram-percentile endpoints — used for whites/blacks sliders.
    /// Whites = the luma value below which 99.5% of pixels fall.
    let whitesCutoff: Double
    /// Blacks = the luma value above which 0.5% of pixels fall.
    let blacksCutoff: Double
    /// Mean saturation, where saturation = max(R,G,B) - min(R,G,B) normalized to [0,1].
    let meanSaturation: Double

    var debugDescription: String {
        let fmt: (Double) -> String = { String(format: "%.3f", $0) }
        return """
            mean RGB:      (\(fmt(meanR)), \(fmt(meanG)), \(fmt(meanB)))
            mean luma:     \(fmt(meanLuma))
            luma stddev:   \(fmt(stddevLuma))
            highlight clip: \(String(format: "%.2f%%", highlightClipFraction * 100))
            shadow clip:    \(String(format: "%.2f%%", shadowClipFraction * 100))
            whites cutoff: \(fmt(whitesCutoff)) (255 = no highlight clipping, lower = more clipping)
            blacks cutoff: \(fmt(blacksCutoff)) (0 = no shadow clipping, higher = more clipping)
            mean sat:      \(fmt(meanSaturation))
            """
    }
}

enum ImageStatsComputer {

    /// Compute all stats from a `DecodedImage`. Walks the pixel
    /// buffer in a single pass for mean/stddev/clipping/saturation,
    /// then a second pass to build the histogram (since we need the
    /// mean first to know where to split "highlights" vs "shadows").
    static func compute(from image: DecodedImage) -> ImageStats {
        let n = image.pixelCount
        var sumR: Double = 0
        var sumG: Double = 0
        var sumB: Double = 0
        var sumLuma: Double = 0
        var sumLumaSq: Double = 0
        var sumSat: Double = 0
        var highlightClip: Int = 0
        var shadowClip: Int = 0
        var histogram = [Int](repeating: 0, count: 256)

        // First pass: per-pixel sums + clipping counts + histogram.
        // We walk in row-major order, ignoring the alpha byte (every 4th).
        let px = image.pixels
        let bytesPerRow = image.bytesPerRow
        let height = image.height
        let base = px.startIndex

        // Precompute: in display-referred sRGB, the highlight-clip
        // threshold for "this would be hard-clipped" is ~250. We use
        // 252 to leave a small margin and avoid flagging legitimate
        // bright (but not blown) pixels.
        let highlightThreshold: UInt8 = 252
        let shadowThreshold: UInt8 = 3

        for y in 0..<height {
            let rowStart = base + y * bytesPerRow
            for x in 0..<image.width {
                let i = rowStart + x * 4
                let r = Double(px[i])
                let g = Double(px[i + 1])
                let b = Double(px[i + 2])

                sumR += r
                sumG += g
                sumB += b

                // Rec.709 luma — same weights Camera Raw uses for
                // its "Blacks" / "Whites" calculations.
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                sumLuma += luma
                sumLumaSq += luma * luma
                // Histogram bin is the integer luma value (clamped to 0..255).
                let bin = Swift.min(255, Swift.max(0, Int(luma)))
                histogram[bin] += 1
                if bin >= Int(highlightThreshold) { highlightClip += 1 }
                if bin <= Int(shadowThreshold) { shadowClip += 1 }

                // Saturation index. We use (max-min)/255 as a fast
                // monotonic approximation of HSL saturation.
                let mx = Swift.max(r, Swift.max(g, b))
                let mn = Swift.min(r, Swift.min(g, b))
                sumSat += (mx - mn) / 255.0
            }
        }

        let dN = Double(n)
        let meanR = sumR / dN
        let meanG = sumG / dN
        let meanB = sumB / dN
        let meanLuma = sumLuma / dN
        // Variance = E[x^2] - E[x]^2. Use max(0, ...) to guard against
        // tiny floating-point negative values from the subtraction.
        let variance = max(0, sumLumaSq / dN - meanLuma * meanLuma)
        let stddevLuma = sqrt(variance)

        // Normalize histogram to a probability distribution (sums to 1).
        // Convert to Double for the percentile walk below.
        var normalizedHistogram = [Double](repeating: 0, count: 256)
        for i in 0..<256 { normalizedHistogram[i] = Double(histogram[i]) / dN }

        // Percentile cutoffs for whites/blacks.
        // Camera Raw's "Whites" slider raises the upper part of the
        // curve; if the histogram already has mass near 255, that's
        // a sign the user pushed Whites UP. We approximate by finding
        // the luma value below which 99.5% of pixels fall (i.e. the
        // 99.5th percentile).
        let whitesCutoff = percentile(histogram: normalizedHistogram, percentile: 0.995)
        let blacksCutoff = percentile(histogram: normalizedHistogram, percentile: 0.005)

        return ImageStats(
            meanR: meanR,
            meanG: meanG,
            meanB: meanB,
            meanLuma: meanLuma,
            stddevLuma: stddevLuma,
            histogram: normalizedHistogram,
            highlightClipFraction: Double(highlightClip) / dN,
            shadowClipFraction: Double(shadowClip) / dN,
            whitesCutoff: whitesCutoff,
            blacksCutoff: blacksCutoff,
            meanSaturation: sumSat / dN
        )
    }

    /// Find the luma value (0-255) at the given cumulative percentile
    /// of the histogram. Walks bins low→high, accumulating mass until
    /// we cross the threshold. O(256) — trivial.
    private static func percentile(histogram: [Double], percentile p: Double) -> Double {
        var cumulative: Double = 0
        for (i, mass) in histogram.enumerated() {
            cumulative += mass
            if cumulative >= p { return Double(i) }
        }
        return 255
    }
}