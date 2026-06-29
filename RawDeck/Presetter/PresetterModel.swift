import Foundation
import AppKit
import UniformTypeIdentifiers

/// State and actions for the Presetter feature: load a reference image
/// (drag-drop, paste, or open panel), run the analyzer, and export the
/// derived preset.
///
/// `PresetterModel` is intentionally separate from `PhotoStore` — the
/// library feature (culling, rating, lightbox) and the preset-extraction
/// feature have almost nothing in common. Putting them in the same
/// ObservableObject would force a unified lifecycle that's awkward for
/// both (e.g. opening a new reference image shouldn't clear the user's
/// rated library; importing a folder shouldn't disturb a half-finished
/// preset extraction).
///
/// The model is `@MainActor` because it touches `NSImage` and writes to
/// the clipboard, both of which are main-actor-safe.
@MainActor
final class PresetterModel: ObservableObject {

    /// The loaded reference image, as displayed in the UI. `nil` means
    /// "no image yet — show the drop zone."
    @Published private(set) var image: NSImage? = nil

    /// The image as an NSImage that we can pass to the analyzer.
    /// Cached separately from `image` because the analyzer wants a
    /// pixel buffer and the UI wants the SwiftUI `Image` rendering.
    /// In practice we always set them together.
    @Published private(set) var displayImage: NSImage? = nil

    /// The derived preset values. `nil` until the analyzer has run on
    /// the current image.
    @Published private(set) var preset: DerivedPreset? = nil

    /// Optional name the user has given this preset. Used as the XMP
    /// preset's `crs:Name` field and as the file stem on export.
    @Published var presetName: String = ""

    /// Last error message (e.g. "unsupported image format"). Cleared
    /// on successful load.
    @Published private(set) var lastError: String? = nil

    /// Whether the export buttons should be enabled. They require both
    /// a loaded image AND a derived preset.
    var canExport: Bool { image != nil && preset != nil }

    // MARK: - Loading

    /// Open an image via the standard macOS file picker.
    func openImageViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Load"
        if panel.runModal() == .OK, let url = panel.url {
            loadImage(from: url)
        }
    }

    /// Load an image from a URL (called from the file picker or a
    /// drag-and-drop operation). Triggers analysis on success.
    func loadImage(from url: URL) {
        do {
            let nsImage = try loadNSImage(from: url)
            self.displayImage = nsImage
            self.image = nsImage
            self.presetName = url.deletingPathExtension().lastPathComponent
            self.lastError = nil
            analyze(image: nsImage)
        } catch {
            self.lastError = "Could not load image: \(error.localizedDescription)"
            self.image = nil
            self.displayImage = nil
            self.preset = nil
        }
    }

    /// Load an image from raw PNG/JPEG/etc. data (used by paste).
    func loadImage(from data: Data) {
        guard let nsImage = NSImage(data: data) else {
            self.lastError = "Could not decode image data from clipboard."
            self.image = nil
            self.displayImage = nil
            self.preset = nil
            return
        }
        self.displayImage = nsImage
        self.image = nsImage
        self.presetName = "Pasted Image"
        self.lastError = nil
        analyze(image: nsImage)
    }

    /// Load an image from an already-decoded NSImage. Used by drag-
    /// and-drop from apps that provide images as NSItemProvider objects
    /// (Photos, Safari, etc.).
    func loadImage(from nsImage: NSImage) {
        self.displayImage = nsImage
        self.image = nsImage
        if self.presetName.isEmpty {
            self.presetName = "Pasted Image"
        }
        self.lastError = nil
        analyze(image: nsImage)
    }

    /// Read a file URL into an NSImage. Uses NSImage(contentsOf:),
    /// which handles JPEG/PNG/HEIC/TIFF and reads embedded preview
    /// metadata when present.
    private func loadNSImage(from url: URL) throws -> NSImage {
        guard let img = NSImage(contentsOf: url) else {
            throw NSError(
                domain: "Presetter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported image format or unreadable file."]
            )
        }
        return img
    }

    // MARK: - Analysis

    /// Run the analyzer on the current image and update `preset`.
    /// Done synchronously on the main actor because the input is
    /// already downsampled (the analyzer caps at 4000px) and the
    /// work is a few hundred ms at most.
    private func analyze(image: NSImage) {
        // The analyzer wants a CGImage-backed bitmap. NSImage can be
        // backed by various representations; we ask it for a TIFF and
        // re-decode via ImageIO to get a reliable CGImage. (NSImage's
        // `cgImage(forProposedRect:)` is documented but quirky for
        // vector PDFs and some RAW previews; the TIFF round-trip is
        // slower but always correct.)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else {
            self.lastError = "Could not access pixel data for analysis."
            self.preset = nil
            return
        }

        do {
            let decoded = try ImageLoader.decode(cgImage: cg, maxDimension: 4000)
            let stats = ImageStatsComputer.compute(from: decoded)
            self.preset = PresetMapper.derive(from: stats)
        } catch {
            self.lastError = "Analysis failed: \(error.localizedDescription)"
            self.preset = nil
        }
    }

    // MARK: - Paste

    /// Read an image from the system clipboard (NSPasteboard). Called
    /// when the user hits ⌘V while the Presetter tab is active.
    func pasteFromClipboard() {
        let pb = NSPasteboard.general

        // Try file URLs first (drag-from-Finder paste).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first {
            loadImage(from: url)
            return
        }

        // Then try raw image data (screenshot, copy-from-Photos, etc.).
        if let data = pb.data(forType: .png)
            ?? pb.data(forType: .tiff)
            ?? pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            loadImage(from: data)
            return
        }

        self.lastError = "Clipboard doesn't contain an image."
    }

    // MARK: - Reset

    /// Clear the current image and preset. Used by the "Clear" button
    /// and when the user wants to start over with a new reference.
    func reset() {
        self.image = nil
        self.displayImage = nil
        self.preset = nil
        self.presetName = ""
        self.lastError = nil
    }

    // MARK: - Export

    /// Export the derived preset as an .xmp file (Photoshop Camera Raw /
    /// Lightroom Classic). Prompts the user for a save location.
    func exportXMP() {
        guard let preset = preset else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        panel.nameFieldStringValue = "\(safeFileName(presetName))-look.xmp"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            let xmp = XMPWriter.make(name: presetName, preset: preset)
            do {
                try xmp.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.lastError = "Failed to write XMP: \(error.localizedDescription)"
            }
        }
    }

    /// Export a "recreation sheet" — a Markdown file with each slider
    /// value, for editors that don't read XMP (e.g. Pixelmator Pro).
    /// The user opens this next to their editor and dials the values in.
    func exportRecreationSheet() {
        guard let preset = preset else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(safeFileName(presetName))-recreation.md"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            let sheet = RecreationSheetWriter.make(name: presetName, preset: preset)
            do {
                try sheet.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.lastError = "Failed to write recreation sheet: \(error.localizedDescription)"
            }
        }
    }

    /// Strip characters that are awkward in filenames. Conservative —
    /// we don't try to handle every edge case, just the obvious ones.
    private func safeFileName(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return s.components(separatedBy: invalid).joined(separator: "_")
    }
}