import Foundation
import AppKit
import UniformTypeIdentifiers

/// State and actions for the Colorway Parser feature.
///
/// Two usage modes:
///   1. **Coaching** (default, two-image): user drops a *reference*
///      image whose look they want to mimic, then drops a *target*
///      RAW they want to apply the look to. Model computes a per-
///      parameter delta + confidence and exposes them as
///      `coachingDeltaRows`.
///   2. **Quick preset** (legacy single-image): only reference loaded.
///      Model exposes the inferred `preset` for export as .xmp or
///      recreation sheet. No delta, no confidence.
///
/// `ColorwayParserModel` is intentionally separate from `PhotoStore`:
/// the library feature (cull, rate, lightbox) and the preset-
/// extraction feature have almost nothing in common. Putting them in
/// the same ObservableObject would force a unified lifecycle that's
/// awkward for both.
///
/// The model is `@MainActor` because it touches `NSImage` and writes
/// to the clipboard, both of which are main-actor-safe.
@MainActor
final class ColorwayParserModel: ObservableObject {

    // MARK: - Mode

    /// Which flow the user is in. Default is `.coaching` per the
    /// 2026-06-29 spec. Toggled by the dropdown in the header.
    enum Mode: String, CaseIterable, Identifiable {
        case coaching
        case quickPreset
        var id: String { rawValue }
        var label: String {
            switch self {
            case .coaching:    return "Coaching"
            case .quickPreset: return "Quick preset"
            }
        }
    }

    @Published var mode: Mode = .coaching

    // MARK: - Reference (the look to mimic)

    @Published private(set) var image: NSImage? = nil
    @Published private(set) var displayImage: NSImage? = nil
    @Published private(set) var referenceName: String = ""
    @Published private(set) var referenceStats: ImageStats? = nil

    // MARK: - Target (your RAW, only used in coaching mode)

    @Published private(set) var targetImage: NSImage? = nil
    @Published private(set) var targetDisplayImage: NSImage? = nil
    @Published private(set) var targetName: String = ""
    @Published private(set) var targetStats: ImageStats? = nil
    @Published private(set) var targetURL: URL? = nil  // for "View in Pixelmator"

    // MARK: - Output

    /// Single-image preset (Quick preset mode only — the inferred
    /// look the user wants to capture). Coaching mode uses
    /// `coachingDeltaRows` instead, which is the *delta* between
    /// target and reference.
    @Published private(set) var preset: DerivedPreset? = nil

    /// Optional name the user has given this preset. Used as the XMP
    /// preset's `crs:Name` field and as the file stem on export.
    @Published var presetName: String = ""

    /// Per-parameter delta rows for coaching mode. Each row knows its
    /// value (signed delta to apply) and confidence (high/medium/low).
    /// `nil` until both reference and target have loaded and analyzed.
    @Published private(set) var coachingDeltaRows: [CoachingDeltaRow] = []

    /// Summary counts for the header chip in coaching mode.
    /// `nil` until delta is computed.
    var confidenceSummary: (high: Int, medium: Int, low: Int)? {
        guard !coachingDeltaRows.isEmpty else { return nil }
        var h = 0, m = 0, l = 0
        for row in coachingDeltaRows {
            switch row.confidence {
            case .high:   h += 1
            case .medium: m += 1
            case .low:    l += 1
            }
        }
        return (h, m, l)
    }

    /// Last error message. Cleared on successful load.
    @Published private(set) var lastError: String? = nil

    /// Whether the export buttons should be enabled.
    /// - In coaching mode: requires both images + delta rows.
    /// - In quick preset mode: requires the reference + preset.
    var canExport: Bool {
        switch mode {
        case .coaching:
            return image != nil && targetImage != nil && !coachingDeltaRows.isEmpty
        case .quickPreset:
            return image != nil && preset != nil
        }
    }

    // MARK: - Loading — Reference

    func openReferenceViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Load Reference"
        if panel.runModal() == .OK, let url = panel.url {
            loadReference(from: url)
        }
    }

    func loadReference(from url: URL) {
        do {
            let nsImage = try loadNSImage(from: url)
            self.displayImage = nsImage
            self.image = nsImage
            self.referenceName = url.deletingPathExtension().lastPathComponent
            self.lastError = nil
            if presetName.isEmpty { presetName = referenceName }
            analyzeReference(image: nsImage)
            recomputeCoachingIfReady()
        } catch {
            self.lastError = "Could not load reference: \(error.localizedDescription)"
            self.image = nil
            self.displayImage = nil
            self.referenceStats = nil
        }
    }

    func loadReference(from data: Data) {
        guard let nsImage = NSImage(data: data) else {
            self.lastError = "Could not decode image data from clipboard."
            return
        }
        self.displayImage = nsImage
        self.image = nsImage
        if referenceName.isEmpty { referenceName = "Pasted Reference" }
        if presetName.isEmpty { presetName = referenceName }
        self.lastError = nil
        analyzeReference(image: nsImage)
        recomputeCoachingIfReady()
    }

    func loadReference(from nsImage: NSImage) {
        self.displayImage = nsImage
        self.image = nsImage
        if referenceName.isEmpty { referenceName = "Pasted Reference" }
        if presetName.isEmpty { presetName = referenceName }
        self.lastError = nil
        analyzeReference(image: nsImage)
        recomputeCoachingIfReady()
    }

    // MARK: - Loading — Target

    func openTargetViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]  // [.rawImage] if we want strict RAW
        panel.prompt = "Load Your RAW"
        if panel.runModal() == .OK, let url = panel.url {
            loadTarget(from: url)
        }
    }

    func loadTarget(from url: URL) {
        do {
            let nsImage = try loadNSImage(from: url)
            self.targetDisplayImage = nsImage
            self.targetImage = nsImage
            self.targetName = url.deletingPathExtension().lastPathComponent
            self.targetURL = url
            self.lastError = nil
            analyzeTarget(image: nsImage)
            recomputeCoachingIfReady()
        } catch {
            self.lastError = "Could not load target: \(error.localizedDescription)"
            self.targetImage = nil
            self.targetDisplayImage = nil
            self.targetStats = nil
            self.targetURL = nil
        }
    }

    /// Load target from raw image data (used when pasting from the
    /// clipboard — the pasteboard gives us PNG/TIFF/JPEG bytes, not
    /// a file URL).
    func loadTarget(from data: Data) {
        guard let nsImage = NSImage(data: data) else {
            self.lastError = "Could not decode image data from clipboard (target)."
            self.targetImage = nil
            self.targetDisplayImage = nil
            self.targetStats = nil
            return
        }
        self.targetDisplayImage = nsImage
        self.targetImage = nsImage
        if targetName.isEmpty { targetName = "Pasted Target" }
        // Pasted targets don't have a backing URL, so `targetURL`
        // stays nil. The "View in Pixelmator" CTA checks for
        // `targetURL == nil` and surfaces an error in that case.
        self.lastError = nil
        analyzeTarget(image: nsImage)
        recomputeCoachingIfReady()
    }

    func loadTarget(from nsImage: NSImage) {
        self.targetDisplayImage = nsImage
        self.targetImage = nsImage
        if targetName.isEmpty { targetName = "Pasted Target" }
        self.lastError = nil
        analyzeTarget(image: nsImage)
        recomputeCoachingIfReady()
    }

    // MARK: - Loading — generic (kept for back-compat with old call sites)

    /// Back-compat alias. Old code calls `loadImage(from:)` expecting
    /// it to load the reference. Routes to `loadReference(from:)`.
    func loadImage(from url: URL) { loadReference(from: url) }
    func loadImage(from data: Data) { loadReference(from: data) }
    func loadImage(from nsImage: NSImage) { loadReference(from: nsImage) }

    /// Back-compat alias. Old single-image `openImageViaPanel`.
    func openImageViaPanel() { openReferenceViaPanel() }

    // MARK: - Analysis

    private func analyzeReference(image: NSImage) {
        guard let cg = cgImage(from: image) else {
            self.lastError = "Could not access pixel data for reference."
            self.referenceStats = nil
            self.preset = nil
            return
        }
        do {
            let decoded = try ImageLoader.decode(cgImage: cg, maxDimension: 4000)
            let stats = ImageStatsComputer.compute(from: decoded)
            self.referenceStats = stats
            // Update quick-preset preset too (it's the same math).
            self.preset = PresetMapper.derive(from: stats)
        } catch {
            self.lastError = "Reference analysis failed: \(error.localizedDescription)"
            self.referenceStats = nil
            self.preset = nil
        }
    }

    private func analyzeTarget(image: NSImage) {
        guard let cg = cgImage(from: image) else {
            self.lastError = "Could not access pixel data for target."
            self.targetStats = nil
            return
        }
        do {
            let decoded = try ImageLoader.decode(cgImage: cg, maxDimension: 4000)
            let stats = ImageStatsComputer.compute(from: decoded)
            self.targetStats = stats
        } catch {
            self.lastError = "Target analysis failed: \(error.localizedDescription)"
            self.targetStats = nil
        }
    }

    /// Decode an NSImage into a CGImage via the TIFF round-trip.
    /// NSImage's `cgImage(forProposedRect:)` is documented but quirky
    /// for vector PDFs and some RAW previews; the TIFF round-trip is
    /// slower but always correct.
    private func cgImage(from image: NSImage) -> CGImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.cgImage
    }

    /// Compute the coaching delta rows from the two stats.
    /// No-op until both `referenceStats` and `targetStats` exist.
    private func recomputeCoachingIfReady() {
        guard let ref = referenceStats, let tgt = targetStats else {
            self.coachingDeltaRows = []
            return
        }
        // Derive a preset from each, then compute the delta to apply
        // to the target to bring it toward the reference look.
        let refPreset = PresetMapper.derive(from: ref)
        let tgtPreset = PresetMapper.derive(from: tgt)

        self.coachingDeltaRows = CoachingDeltaComputer.compute(
            reference: refPreset,
            target: tgtPreset,
            referenceStats: ref,
            targetStats: tgt
        )
    }

    // MARK: - File I/O

    private func loadNSImage(from url: URL) throws -> NSImage {
        guard let img = NSImage(contentsOf: url) else {
            throw NSError(
                domain: "Colorway", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported image format or unreadable file."]
            )
        }
        return img
    }

    // MARK: - Paste

    /// Paste the first image on the clipboard into the **reference**
    /// slot. ⌘V behaviour while no image is loaded or the reference
    /// pane has focus.
    func pasteFromClipboard() { pasteFromClipboard(asTarget: false) }

    /// Paste into the **target** slot. Used when the target pane has
    /// focus (⌘⇧V).
    func pasteTargetFromClipboard() { pasteFromClipboard(asTarget: true) }

    private func pasteFromClipboard(asTarget: Bool) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first {
            if asTarget { loadTarget(from: url) } else { loadReference(from: url) }
            return
        }
        if let data = pb.data(forType: .png)
            ?? pb.data(forType: .tiff)
            ?? pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            if asTarget { loadTarget(from: data) } else { loadReference(from: data) }
            return
        }
        self.lastError = "Clipboard doesn't contain an image."
    }

    // MARK: - Reset

    /// Clear both reference and target. Used by the "Clear" button.
    func reset() {
        self.image = nil
        self.displayImage = nil
        self.referenceName = ""
        self.referenceStats = nil
        self.targetImage = nil
        self.targetDisplayImage = nil
        self.targetName = ""
        self.targetStats = nil
        self.targetURL = nil
        self.preset = nil
        self.coachingDeltaRows = []
        self.presetName = ""
        self.lastError = nil
    }

    // MARK: - Export

    /// Export the derived preset as an .xmp file (Camera Raw / Lightroom).
    /// In coaching mode, exports the *delta* applied to the target. In
    /// quick preset mode, exports the absolute preset for the reference.
    func exportXMP() {
        let xmpString: String
        switch mode {
        case .coaching:
            guard !coachingDeltaRows.isEmpty else { return }
            xmpString = XMPWriter.makeCoaching(name: presetName, rows: coachingDeltaRows)
        case .quickPreset:
            guard let p = preset else { return }
            xmpString = XMPWriter.make(name: presetName, preset: p)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        panel.nameFieldStringValue = "\(safeFileName(presetName))-look.xmp"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try xmpString.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.lastError = "Failed to write XMP: \(error.localizedDescription)"
            }
        }
    }

    /// Export a "recreation sheet" — a Markdown file with each value
    /// for editors that don't read XMP (e.g. Pixelmator Pro).
    func exportRecreationSheet() {
        let sheet: String
        switch mode {
        case .coaching:
            guard !coachingDeltaRows.isEmpty else { return }
            sheet = RecreationSheetWriter.makeCoaching(name: presetName, rows: coachingDeltaRows)
        case .quickPreset:
            guard let p = preset else { return }
            sheet = RecreationSheetWriter.make(name: presetName, preset: p)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(safeFileName(presetName))-recreation.md"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try sheet.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.lastError = "Failed to write recreation sheet: \(error.localizedDescription)"
            }
        }
    }

    /// In coaching mode, write the XMP *next to the target file* (so
    /// editors that auto-pickup sidecars will find it) and open the
    /// target in Pixelmator Pro. In quick preset mode, there's no
    /// target to open — fall back to a save panel.
    func viewInPixelmator() {
        switch mode {
        case .coaching:
            guard let targetURL = targetURL else {
                self.lastError = "No target file to open in Pixelmator."
                return
            }
            // Write the XMP sidecar next to the target.
            let xmpURL = targetURL.deletingPathExtension()
                .appendingPathExtension("xmp")
            let xmpString = XMPWriter.makeCoaching(name: presetName, rows: coachingDeltaRows)
            do {
                try xmpString.write(to: xmpURL, atomically: true, encoding: .utf8)
            } catch {
                self.lastError = "Failed to write XMP sidecar: \(error.localizedDescription)"
                return
            }
            ExternalAppService.openInPixelmator(targetURL)

        case .quickPreset:
            // No target file in this mode. Save the XMP and tell the user.
            exportXMP()
        }
    }

    /// Strip characters that are awkward in filenames.
    private func safeFileName(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return s.components(separatedBy: invalid).joined(separator: "_")
    }
}