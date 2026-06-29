import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Main view for the Colorway Parser mode. Shows either:
/// - An empty drop zone (when no image is loaded), prompting the user
///   to drop/paste/open an image
/// - A side-by-side layout: image preview on the left, derived preset
///   values on the right, with export buttons below
///
/// The view itself is stateless — all state lives in `ColorwayParserModel`,
/// which is injected via `@EnvironmentObject`.
struct ColorwayParserView: View {
    @EnvironmentObject var colorwayParser: ColorwayParserModel

    var body: some View {
        Group {
            if let image = colorwayParser.displayImage {
                loadedLayout(image: image)
                } else {
                emptyLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Empty state

    private var emptyLayout: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("Drop a reference image here")
                .font(.title2)
            Text("…or paste from clipboard (⌘V) or click below to open one.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Open Image…") {
                colorwayParser.openImageViaPanel()
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)

            if let err = colorwayParser.lastError {
                    Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 8)
            }
        }
                    .padding(40)
        // Drop target for image files. We accept any file that AppKit
        // can read as an image (JPEG/PNG/HEIC/TIFF/etc). The closure must
        // return a Bool — true signals "I accepted this drop" so other
        // drop targets don't also try to handle it.
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        // ⌘V pastes from clipboard. Bound at the view level so it works
        // regardless of which subview has focus.
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Loaded state

    private func loadedLayout(image: NSImage) -> some View {
        HSplitView {
            // Left: image preview. Capped to a max dimension so a huge
            // screenshot doesn't blow up the layout.
            imagePreview(image: image)
                .frame(minWidth: 280, idealWidth: 480, maxWidth: 800)

            // Right: derived preset values + export buttons.
            presetPanel
                .frame(minWidth: 360, idealWidth: 420)
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            handleDrop(providers: providers)
        }
    }

    /// SwiftUI `Image` rendering of the loaded NSImage. Uses `.resizable`
    /// + `.scaledToFit()` so the preview stays within its bounds at
    /// any window size.
    private func imagePreview(image: NSImage) -> some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                    .padding(12)
        }
    }

    /// Right-side panel showing the derived preset values. Each row is
    /// a slider name + value, formatted the way Camera Raw's UI does
    /// (e.g. "+0.67", "−25").
    private var presetPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: name field + Clear button
            HStack {
                TextField("Preset name", text: $colorwayParser.presetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Button("Clear") {
                    colorwayParser.reset()
                }
                .controlSize(.small)
            }
                    .padding(12)

            Divider()

            // Preset values list
            ScrollView {
                if let preset = colorwayParser.preset {
                    VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Basic")
                    presetRow("Exposure", preset.exposure, format: .ev)
                    presetRow("Contrast", preset.contrast)
                    presetRow("Highlights", preset.highlights, note: "negative = recover")
                    presetRow("Shadows", preset.shadows)
                    presetRow("Whites", preset.whites)
                    presetRow("Blacks", preset.blacks)
                    presetRow("Texture", 0, dimmed: true)
                    presetRow("Clarity", 0, dimmed: true)
                    presetRow("Dehaze", 0, dimmed: true)
                    presetRow("Vibrance", preset.vibrance)
                    presetRow("Saturation", preset.saturation)

                    sectionHeader("White Balance")
                    presetRow("Temperature", preset.temperature)
                    presetRow("Tint", preset.tint)

                    sectionHeader("Detail")
                    dimmedNote("Sharpening and noise reduction are not inferred from a finished image. Suggested starting values: Sharpening 25, NR 25.")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else if let err = colorwayParser.lastError {
                    Text(err)
                    .foregroundColor(.red)
                    .padding(12)
                } else {
                    // Shown only if analysis is slow enough that SwiftUI
                    // renders a frame between image-load and preset-set.
                    // Currently `analyze` runs synchronously on main, so
                    // this is rarely seen — but kept as a fallback for
                    // very large images.
                    ProgressView("Analyzing…")
                    .padding(40)
                }
            }

            Divider()

            // Export buttons
            HStack(spacing: 8) {
                Button {
                    colorwayParser.exportXMP()
                } label: {
                    Label("Export .xmp", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!colorwayParser.canExport)

                Button {
                    colorwayParser.exportRecreationSheet()
                } label: {
                    Label("Recreation Sheet", systemImage: "doc.text")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!colorwayParser.canExport)
            }
                    .padding(12)
        }
    }

    /// Section header inside the preset panel (e.g. "Basic", "White Balance").
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    /// Dimmed explanatory note (used for the "Detail" panel section).
    private func dimmedNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 8)
    }

    /// One row in the preset values list: name on the left, value on the right.
    /// `dimmed` is for values we explicitly set to 0 because we can't infer
    /// them — visually distinguishes them from inferred values that happen
    /// to be zero.
    private func presetRow(
        _ name: String,
        _ value: Double,
        format: NumberFormat = .signed,
        note: String? = nil,
        dimmed: Bool = false
    ) -> some View {
        HStack {
            Text(name)
                .foregroundColor(dimmed ? .secondary : .primary)
            if let note = note {
                Text("(\(note))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(formatValue(value, style: format))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(dimmed ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }

    private enum NumberFormat {
        case signed
        case ev
    }

    /// Format a signed Double with 2 decimal places, e.g. "+12.50".
    private func formatValue(_ d: Double, style: NumberFormat) -> String {
        if abs(d) < 0.005 { return "0" }
        let sign = d > 0 ? "+" : ""
        switch style {
        case .signed:
            return String(format: "\(sign)%.2f", d)
        case .ev:
            return String(format: "\(sign)%.2f EV", d)
        }
    }

    // MARK: - Drop / paste handling

    /// Resolve a list of `NSItemProvider` from a drop or paste into a
    /// single image URL, then load it. If multiple providers are given,
    /// we use the first image-bearing one.
    ///
    /// Marked `@discardableResult` because `.onDrop` and `.onPasteCommand`
    /// closures inferred from a single-statement body discard the Bool,
    /// triggering "Result of call is unused" warnings otherwise.
    @discardableResult
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Try file URL first (drag-from-Finder pattern).
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in
                    colorwayParser.loadImage(from: url)
                    }
                }
            }
            return true
        }

        // Try raw image data (paste from screenshot, drag from Photos/Safari).
        // Use the Swift-native `loadObject` API which returns Progress and
        // gives us a strongly-typed Any? that we cast to NSImage. The Obj-C
        // bridge variant (`loadObject(ofClass:completionHandler:)`) trips
        // a `_ObjectiveCBridgeable` warning on NSImage under Swift 6 mode.
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                Task { @MainActor in
                    colorwayParser.loadImage(from: image)
                }
            }
            return true
        }

        return false
    }
}