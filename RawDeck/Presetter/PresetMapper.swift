import Foundation

/// Approximate Camera Raw slider values derived from image statistics.
///
/// These are the values we'd plug into a Camera Raw / Lightroom /
/// Adobe Standard preset. The mapping from stats → sliders is a
/// simplification of Camera Raw's actual adjustment model — good
/// enough as a starting point, not good enough to perfectly
/// reproduce a hand-crafted edit.
///
/// Sign conventions (Camera Raw's actual slider ranges):
/// - Exposure: -5.0 to +5.0 EV stops
/// - Contrast: -100 to +100 (additive)
/// - Highlights: -100 to +100 (negative = recover highlights)
/// - Shadows: -100 to +100 (positive = lift shadows)
/// - Whites: -100 to +100 (positive = set white point higher)
/// - Blacks: -100 to +100 (negative = crush blacks lower)
/// - Vibrance: -100 to +100 (positive = boost muted colors)
/// - Saturation: -100 to +100
/// - Temperature: -100 to +100 (positive = warmer)
/// - Tint: -100 to +100 (positive = magenta)
struct DerivedPreset {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var temperature: Double = 0
    var tint: Double = 0

    var debugDescription: String {
        let fmt: (Double) -> String = { String(format: "%+.2f", $0) }
        return """
            Exposure:     \(fmt(exposure)) EV
            Contrast:     \(fmt(contrast))
            Highlights:   \(fmt(highlights))
            Shadows:      \(fmt(shadows))
            Whites:       \(fmt(whites))
            Blacks:       \(fmt(blacks))
            Vibrance:     \(fmt(vibrance))
            Saturation:   \(fmt(saturation))
            Temperature:  \(fmt(temperature))
            Tint:         \(fmt(tint))
            """
    }
}

enum PresetMapper {

    /// Derive a Camera Raw preset from image statistics.
    ///
    /// The math here is intentionally simple. The hard part of "what
    /// did the photographer do?" isn't the math — it's the lack of
    /// information. We see a finished image; we don't see the RAW it
    /// came from. So all our estimates have wide error bars.
    /// Fine-tune in your editor.
    static func derive(from stats: ImageStats) -> DerivedPreset {
        var p = DerivedPreset()

        // ---- Exposure ----
        // 18% gray (Y = 0.18 in linear, ~118/255 in sRGB after gamma)
        // is the canonical "well-balanced midtone." If the image's
        // mean luma is brighter or darker than that, the photographer
        // either exposed for it (Exposure slider) or used Tone Curve.
        // We assume Exposure if the deviation is moderate, Tone Curve
        // if it's extreme (because pushing Exposure past ±2 EV is rare).
        //
        // The conversion from sRGB-encoded luma to EV is:
        //   linear_luma = (sRGB_luma / 255)^2.2   (approximate gamma)
        //   EV_offset = log2(linear_luma / 0.18)
        let srgbLuma = stats.meanLuma / 255.0
        let linearLuma = pow(max(srgbLuma, 0.001), 2.2)
        let evOffset = log2(max(linearLuma / 0.18, 0.001))
        p.exposure = clamp(evOffset, lower: -2.5, upper: 2.5)

        // ---- Contrast ----
        // The standard deviation of luma, normalized to a "neutral"
        // baseline of ~50 (out of 255) which corresponds to a typical
        // well-balanced photograph without any contrast adjustments.
        //
        // The mapping: if stddev ≈ 50 → contrast = 0; if stddev > 50
        // → contrast > 0 (boosted); if stddev < 50 → contrast < 0
        // (flatter). Scale so stddev=80 maps to +50 (close to ACR's
        // typical default range).
        let neutralStddev: Double = 50.0
        let stddevDelta = stats.stddevLuma - neutralStddev
        // Empirically tuned: ±20 stddev → ±50 contrast.
        p.contrast = clamp(stddevDelta * 2.5, lower: -100, upper: 100)

        // ---- Highlights ----
        // If the photographer recovered highlights (Highlights < 0),
        // the histogram has mass near 255 but isn't fully clipped.
        // If they pushed highlights UP (Highlights > 0), more pixels
        // are near 255 and may be clipped.
        //
        // Map: 0% clipping → 0; 2% clipping → -50; 5%+ clipping → -100.
        // Sign is negative because more clipping = more highlight RECOVERY.
        if stats.highlightClipFraction < 0.001 {
            p.highlights = 0
        } else {
            // 1% clipping → ~25 highlight recovery
            p.highlights = clamp(-stats.highlightClipFraction * 2500, lower: -100, upper: 0)
        }

        // ---- Shadows ----
        // Mirror of highlights. Shadows > 0 = lift shadows.
        // 1% clipping → ~25 shadow lift.
        if stats.shadowClipFraction < 0.001 {
            p.shadows = 0
        } else {
            p.shadows = clamp(stats.shadowClipFraction * 2500, lower: 0, upper: 100)
        }

        // ---- Whites ----
        // If the histogram's 99.5th percentile is at 255, the user
        // pushed Whites UP. If it's at, say, 240, Whites are roughly
        // neutral.
        //
        // Map: 99.5%ile at 250 → 0; at 230 → -30; at 255 → +50.
        let whitesDelta = stats.whitesCutoff - 250.0  // 0 = neutral
        p.whites = clamp(whitesDelta * 2.5, lower: -100, upper: 100)

        // ---- Blacks ----
        // If the 0.5th percentile is at 0, the user pushed Blacks DOWN.
        // If it's at, say, 15, Blacks are roughly neutral.
        let blacksDelta = 5.0 - stats.blacksCutoff  // 0 = neutral
        p.blacks = clamp(blacksDelta * 2.5, lower: -100, upper: 100)

        // ---- Vibrance / Saturation ----
        // Mean saturation index across all pixels. A "neutral" image
        // typically has mean sat around 0.20-0.25 (mostly desaturated
        // real-world content with selective color). Higher → boost.
        //
        // Camera Raw's default Vibrance boost is around +25 for "pop"
        // without making skin tones look unnatural. Saturation is
        // typically left at 0 unless going for a stylized look.
        let satBaseline: Double = 0.22
        let satDelta = stats.meanSaturation - satBaseline
        p.vibrance = clamp(satDelta * 250, lower: -100, upper: 100)
        p.saturation = clamp(satDelta * 100, lower: -100, upper: 100)

        // ---- Temperature / Tint ----
        // Compare R/G/B channel means. If R > B, the image is warm
        // (user raised temperature). If B > R, the image is cool.
        // Tint is the G deviation from the average of R and B.
        //
        // For a "neutral" image, R, G, B means should be roughly equal
        // (modulo the sensor's color filter array characteristics, which
        // we can't know without the RAW). We use G as the anchor and
        // compute deviations from G.
        let meanRG = (stats.meanR + stats.meanG) / 2.0
        let meanBG = (stats.meanB + stats.meanG) / 2.0
        // Camera Raw's temperature slider ranges -100..+100, where
        // ±50 ≈ ±1000 K (very approximate). We scale our deviation
        // so a 5% channel difference maps to ~25 temperature units.
        let tempRaw = (stats.meanB - stats.meanR) / 255.0  // negative = warm
        p.temperature = clamp(-tempRaw * 500, lower: -100, upper: 100)
        let tintRaw = (stats.meanG - (meanRG + meanBG) / 2.0) / 255.0
        p.tint = clamp(tintRaw * 500, lower: -100, upper: 100)
        _ = meanRG
        _ = meanBG

        return p
    }

    /// Clamp `x` to [lower, upper]. Helper for the derivation.
    private static func clamp(_ x: Double, lower: Double, upper: Double) -> Double {
        return Swift.min(Swift.max(x, lower), upper)
    }
}