import Foundation
import SwiftUI  // for RDColor / RDConfidence if needed by View files in same target

/// One row in the coaching delta panel: the signed adjustment to
/// apply to the target RAW to bring it closer to the reference look,
/// plus a confidence indicator and an optional human-readable
/// explanation.
///
/// Data model is intentionally JSON-serializable so the same struct
/// can power the right-rail UI, the .xmp export, and the recreation
/// sheet without three parallel type hierarchies.
struct CoachingDeltaRow: Identifiable, Hashable {
    enum Parameter: String, Hashable {
        case exposure
        case contrast
        case highlights
        case shadows
        case whites
        case blacks
        case vibrance
        case saturation
        case temperature
        case tint
    }

    /// Format hint for `value`. Mirrors `RDNumberReadout.Format` but
    /// duplicated here to keep this file free of UI dependencies
    /// (the writer/UI files map these to RDNumberReadout.Format).
    enum Format {
        case signed
        case ev
        case percent
        case integer
        case kelvin
    }

    let id = UUID()
    let parameter: Parameter
    /// Signed delta to apply. Sign convention matches Camera Raw
    /// (positive exposure = brighter, positive contrast = more
    /// contrast, etc.).
    let value: Double
    let format: Format
    let confidence: RDConfidence
    /// Optional human-readable explanation ("mean luma is +0.4 EV
    /// brighter than target; lift exposure to match"). Surfaced in
    /// the row's info popover and in the recreation sheet.
    let reasoning: String?

    /// Display label for the parameter, e.g. "Exposure".
    var label: String {
        switch parameter {
        case .exposure:    return "Exposure"
        case .contrast:    return "Contrast"
        case .highlights:  return "Highlights"
        case .shadows:     return "Shadows"
        case .whites:      return "Whites"
        case .blacks:      return "Blacks"
        case .vibrance:    return "Vibrance"
        case .saturation:  return "Saturation"
        case .temperature: return "Temperature"
        case .tint:        return "Tint"
        }
    }
}

/// Computes per-parameter coaching deltas from two image stats.
///
/// The math is intentionally simple and transparent:
///   delta = referencePreset[param] - targetPreset[param]
///
/// That gives the signed adjustment you'd apply to the target's
/// processing to bring it toward the reference look.
///
/// Confidence is heuristic — based on how strong the signal is and
/// whether the reference and target look similar enough that a
/// single-axis adjustment is meaningful. The rules below are
/// conservative (prefer medium over high) because over-confident
/// presets are worse than under-confident ones.
enum CoachingDeltaComputer {

    /// Compute one row per parameter.
    static func compute(
        reference: DerivedPreset,
        target: DerivedPreset,
        referenceStats: ImageStats,
        targetStats: ImageStats
    ) -> [CoachingDeltaRow] {
        // Similarity score 0..1 — how close the target's tonal
        // distribution is to the reference's. Drives confidence for
        // many parameters. If the histograms are wildly different,
        // single-axis deltas are less likely to converge the look.
        let similarity = histogramSimilarity(
            referenceStats.histogram, targetStats.histogram
        )

        return [
            // Exposure — derived from mean luma. High confidence when
            // both images have a clear midtone distribution.
            makeRow(
                parameter: .exposure,
                value: reference.exposure - target.exposure,
                format: .ev,
                similarity: similarity,
                isHistogramDerived: true,
                reasoning: exposureReasoning(reference: reference.exposure,
                                             target: target.exposure)
            ),
            // Contrast — derived from luma stddev. High confidence
            // when both distributions have similar shape.
            makeRow(
                parameter: .contrast,
                value: reference.contrast - target.contrast,
                format: .signed,
                similarity: similarity,
                isHistogramDerived: true,
                reasoning: nil
            ),
            // Highlights — derived from highlight clipping fraction.
            // Single inference signal → never high.
            makeRow(
                parameter: .highlights,
                value: reference.highlights - target.highlights,
                format: .signed,
                similarity: similarity,
                isHistogramDerived: false,
                reasoning: nil
            ),
            // Shadows — mirror of highlights.
            makeRow(
                parameter: .shadows,
                value: reference.shadows - target.shadows,
                format: .signed,
                similarity: similarity,
                isHistogramDerived: false,
                reasoning: nil
            ),
            // Whites — derived from histogram 99.5% percentile.
            makeRow(
                parameter: .whites,
                value: reference.whites - target.whites,
                format: .signed,
                similarity: similarity,
                isHistogramDerived: true,
                reasoning: nil
            ),
            // Blacks — derived from histogram 0.5% percentile.
            makeRow(
                parameter: .blacks,
                value: reference.blacks - target.blacks,
                format: .signed,
                similarity: similarity,
                isHistogramDerived: true,
                reasoning: nil
            ),
            // Vibrance — derived from mean saturation. Single signal.
            makeRow(
                parameter: .vibrance,
                value: reference.vibrance - target.vibrance,
                format: .signed,
                similarity: similarity,
                isHistogramDerived: false,
                reasoning: nil
            ),
            // Saturation — derived from mean saturation. Single signal.
            makeRow(
                parameter: .saturation,
                value: reference.saturation - target.saturation,
                format: .signed,
                similarity: similarity,
                isHistogramDerived: false,
                reasoning: nil
            ),
            // Temperature — derived from R/B channel means. Single
            // signal, sensitive to scene content (red sunset vs red
            // lipstick both register warm).
            makeRow(
                parameter: .temperature,
                value: reference.temperature - target.temperature,
                format: .signed,
                similarity: similarity,
                isHistogramDerived: false,
                reasoning: nil
            ),
            // Tint — derived from G channel deviation. Same caveat
            // as temperature — single signal, scene-sensitive.
            makeRow(
                parameter: .tint,
                value: reference.tint - target.tint,
                format: .signed,
                similarity: similarity,
                isHistogramDerived: false,
                reasoning: nil
            ),
        ]
    }

    // MARK: - Internals

    /// Build a single row with confidence heuristic.
    ///
    /// Rules (in order, first match wins):
    ///   1. If `|delta| < 1.0` → low (no meaningful change to make)
    ///   2. If similarity < 0.5 → low (too dissimilar for a single-
    ///      axis adjustment to be reliable)
    ///   3. If `isHistogramDerived && similarity ≥ 0.8` → high
    ///   4. Else → medium
    private static func makeRow(
        parameter: CoachingDeltaRow.Parameter,
        value: Double,
        format: CoachingDeltaRow.Format,
        similarity: Double,
        isHistogramDerived: Bool,
        reasoning: String?
    ) -> CoachingDeltaRow {
        let confidence: RDConfidence
        let absDelta = abs(value)

        if absDelta < 1.0 {
            // No meaningful change requested — mark low so the user
            // doesn't second-guess an already-aligned image.
            confidence = .low
        } else if similarity < 0.5 {
            // Histograms diverge too much for a single slider to
            // bridge. HSL / tone curve would help more here.
            confidence = .low
        } else if isHistogramDerived && similarity >= 0.8 {
            // Strong, well-supported signal.
            confidence = .high
        } else {
            confidence = .medium
        }

        return CoachingDeltaRow(
            parameter: parameter,
            value: value,
            format: format,
            confidence: confidence,
            reasoning: reasoning
        )
    }

    /// Histogram intersection — 0 (no overlap) to 1 (identical).
    /// Cheap, well-understood similarity metric for luminance
    /// distributions.
    private static func histogramSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sumMin: Double = 0
        for i in 0..<a.count {
            sumMin += min(a[i], b[i])
        }
        return sumMin
    }

    private static func exposureReasoning(reference: Double, target: Double) -> String {
        let delta = reference - target
        if abs(delta) < 0.05 {
            return "Both images have similar mean luma — no exposure adjustment needed."
        }
        let direction = delta > 0 ? "brighter" : "darker"
        return "Reference is \(String(format: "%.2f", abs(delta))) EV \(direction) than your RAW. Adjust exposure to match."
    }
}