import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Main view for the Colorway Parser mode.
///
/// Three visible states:
///   1. **Empty** — no reference loaded. Show a centered drop zone
///      prompting for a reference image.
///   2. **Reference-only** — reference loaded, no target. Show the
///      reference on the left, a "drop your RAW here" slot on the
///      right, and a values panel below (Quick preset mode only).
///   3. **Coaching** — both images loaded. Show a split-slider
///      comparison stage (reference left, target right) with a
///      draggable divider, plus the right-rail delta panel with
///      per-row confidence dots and the "View in Pixelmator" CTA.
///
/// The view itself is stateless — all state lives in
/// `ColorwayParserModel`, which is injected via `@EnvironmentObject`.
struct ColorwayParserView: View {
    @EnvironmentObject var colorwayParser: ColorwayParserModel
    @State private var splitFraction: CGFloat = 0.5  // 0..1, position of divider

    var body: some View {
        Group {
            if colorwayParser.mode == .coaching {
                coachingLayout
            } else {
                // Quick preset — single-image flow. Reference on the
                // left, preset values on the right.
                quickPresetLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RDColor.surfaceBase)
    }

    // MARK: - Empty state

    private var emptyLayout: some View {
        VStack(spacing: RDSpace.l) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(RDColor.textSecondary)
            Text("Drop a reference image here")
                .font(RDType.titleMedium)
            Text("…or paste from clipboard (⌘V) or click below to open one.")
                .foregroundStyle(RDColor.textSecondary)
                .multilineTextAlignment(.center)

            Button("Open Image…") {
                colorwayParser.openReferenceViaPanel()
            }
            .rdButton(.primary)
            .keyboardShortcut("o", modifiers: .command)

            if let err = colorwayParser.lastError {
                Text(err)
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.destructive)
                    .padding(.top, RDSpace.s)
            }
        }
        .padding(RDSpace.xxxl)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers, asTarget: false)
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            handleDrop(providers: providers, asTarget: false)
        }
    }

    // MARK: - Quick preset layout (single image, right-side panel)

    private var quickPresetLayout: some View {
        Group {
            if colorwayParser.image == nil {
                emptyLayout
            } else {
                HSplitView {
                    quickPresetImagePanel
                        .frame(minWidth: 280, idealWidth: 480, maxWidth: 800)
                    quickPresetPanel
                        .frame(minWidth: 360, idealWidth: 420)
                }
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers, asTarget: false)
                }
                .onPasteCommand(of: [.image, .fileURL]) { providers in
                    handleDrop(providers: providers, asTarget: false)
                }
            }
        }
    }

    private var quickPresetImagePanel: some View {
        ZStack {
            RDColor.surfaceBase
            if let image = colorwayParser.displayImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(RDSpace.m)
            }
        }
    }

    private var quickPresetPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: name field + Clear button + mode dropdown
            HStack {
                TextField("Preset name", text: $colorwayParser.presetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                modePicker
                Button("Clear") { colorwayParser.reset() }
                    .controlSize(.small)
            }
            .padding(RDSpace.m)

            Divider()

            // Preset values list (Quick preset mode)
            ScrollView {
                if let preset = colorwayParser.preset {
                    VStack(alignment: .leading, spacing: 0) {
                        presetSectionHeader("Basic")
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

                        presetSectionHeader("White Balance")
                        presetRow("Temperature", preset.temperature)
                        presetRow("Tint", preset.tint)

                        presetSectionHeader("Detail")
                        presetNote("Sharpening and noise reduction are not inferred from a finished image. Suggested starting values: Sharpening 25, NR 25.")
                    }
                    .padding(.horizontal, RDSpace.m)
                    .padding(.vertical, RDSpace.s)
                } else if let err = colorwayParser.lastError {
                    Text(err)
                        .foregroundStyle(RDColor.destructive)
                        .padding(RDSpace.m)
                } else {
                    ProgressView("Analyzing…")
                        .padding(RDSpace.xxxl)
                }
            }

            Divider()

            // Export buttons (Quick preset mode)
            HStack(spacing: RDSpace.s) {
                Button {
                    colorwayParser.exportXMP()
                } label: {
                    Label("Export .xmp", systemImage: "square.and.arrow.up")
                }
                .rdButton(.secondary)
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!colorwayParser.canExport)

                Button {
                    colorwayParser.exportRecreationSheet()
                } label: {
                    Label("Recreation Sheet", systemImage: "doc.text")
                }
                .rdButton(.secondary)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!colorwayParser.canExport)
            }
            .padding(RDSpace.m)
        }
    }

    // MARK: - Coaching layout (two images, split slider, delta panel)

    private var coachingLayout: some View {
        Group {
            if colorwayParser.image == nil {
                emptyLayout
            } else {
                VStack(spacing: 0) {
                    coachingHeader
                    Divider().background(RDColor.hairline)
                    HStack(spacing: 0) {
                        comparisonStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider().background(RDColor.hairline)
                        coachingDeltaPanel
                            .frame(width: 360)
                    }
                }
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers, asTarget: false)
                }
                .onPasteCommand(of: [.image, .fileURL]) { providers in
                    handleDrop(providers: providers, asTarget: false)
                }
            }
        }
    }

    /// Top bar: reference name · target name · mode dropdown · Clear.
    private var coachingHeader: some View {
        HStack(spacing: RDSpace.m) {
            // Reference label
            HStack(spacing: RDSpace.xs) {
                Image(systemName: "photo")
                    .foregroundStyle(RDColor.textSecondary)
                Text("Reference:")
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.textTertiary)
                Text(colorwayParser.referenceName.isEmpty
                     ? "(none)"
                     : colorwayParser.referenceName)
                    .font(RDType.captionMonoEmph)
                    .foregroundStyle(RDColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Image(systemName: "arrow.right")
                .foregroundStyle(RDColor.textTertiary)

            // Target label
            HStack(spacing: RDSpace.xs) {
                Image(systemName: "photo.fill")
                    .foregroundStyle(RDColor.textSecondary)
                Text("Your RAW:")
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.textTertiary)
                Text(colorwayParser.targetName.isEmpty
                     ? "(drop one below)"
                     : colorwayParser.targetName)
                    .font(RDType.captionMonoEmph)
                    .foregroundStyle(colorwayParser.targetImage == nil
                                      ? RDColor.textTertiary
                                      : RDColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Confidence summary (only when delta is computed)
            if let summary = colorwayParser.confidenceSummary {
                Text("\(summary.high) high · \(summary.medium) medium · \(summary.low) low")
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.textSecondary)
            }

            modePicker

            Button("Clear") { colorwayParser.reset() }
                .controlSize(.small)
        }
        .padding(.horizontal, RDSpace.l)
        .padding(.vertical, RDSpace.s + 2)
        .background(RDColor.surfaceRaised)
    }

    /// Mode dropdown (Coaching / Quick preset).
    private var modePicker: some View {
        Picker("Mode", selection: $colorwayParser.mode) {
            ForEach(ColorwayParserModel.Mode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: 140)
    }

    /// The split-slider comparison: reference on the left of the
    /// divider, target on the right. Divider is draggable.
    private var comparisonStage: some View {
        GeometryReader { geo in
            ZStack {
                RDColor.stageBlack

                if let referenceImage = colorwayParser.displayImage,
                   let targetImage = colorwayParser.targetDisplayImage {
                    // Target image fills the whole stage behind the
                    // reference. Reference is overlaid with a
                    // clipping mask on the left of the divider.
                    Image(nsImage: targetImage)
                        .resizable()
                        .scaledToFit()

                    Image(nsImage: referenceImage)
                        .resizable()
                        .scaledToFit()
                        // Match the target's .scaledToFit rect so both
                        // images occupy identical pixels.
                        .frame(width: geo.size.width, height: geo.size.height)
                        // Clip to the area to the LEFT of the divider.
                        // The actual image content is centered inside
                        // the stage (because .scaledToFit centers), so
                        // we clip based on the divider x-coord which is
                        // in stage coordinates.
                        .mask(
                            HStack(spacing: 0) {
                                Color.black
                                    .frame(width: dividerX(in: geo.size))
                                Color.clear
                            }
                        )

                    // Labels for which side is which.
                    stageLabel("REFERENCE", alignment: .leading, padding: RDSpace.m)
                        .foregroundStyle(RDColor.textOnStage)
                        .frame(maxWidth: .infinity,
                               maxHeight: .infinity,
                               alignment: .topLeading)
                        .padding(RDSpace.m)
                        .allowsHitTesting(false)

                    stageLabel("YOUR RAW", alignment: .trailing, padding: RDSpace.m)
                        .foregroundStyle(RDColor.textOnStage)
                        .frame(maxWidth: .infinity,
                               maxHeight: .infinity,
                               alignment: .topTrailing)
                        .padding(RDSpace.m)
                        .allowsHitTesting(false)

                    // The draggable divider.
                    splitDivider(width: geo.size.width)
                        .position(x: dividerX(in: geo.size),
                                  y: geo.size.height / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let clamped = max(0.05,
                                                      min(0.95,
                                                          value.location.x / geo.size.width))
                                    splitFraction = clamped
                                }
                        )
                        // TODO: macOS 14+ keyboard nudges (←/→ 5%, Home/End jump).
                                                // Blocked by deployment target = 13.0. Add when project
                                                // moves to macOS 14. The drag gesture is the primary input.
                } else if let referenceImage = colorwayParser.displayImage {
                    // Reference-only — show the reference full-width
                    // and a drop hint for the target on the right.
                    HStack(spacing: 0) {
                        Image(nsImage: referenceImage)
                            .resizable()
                            .scaledToFit()
                            .padding(RDSpace.m)
                        targetDropSlot
                    }
                }
            }
        }
    }

    /// X-coordinate of the divider within the stage.
    private func dividerX(in size: CGSize) -> CGFloat {
        return max(8, min(size.width - 8, splitFraction * size.width))
    }

    /// The draggable divider line + handle.
    private func splitDivider(width: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(RDColor.surfaceElevated)
                .frame(width: 4)
                .overlay(
                    Rectangle().strokeBorder(RDColor.hairlineStrong, lineWidth: 0.5)
                )
            // Handle: pill shape in the middle of the divider.
            Capsule()
                .fill(RDColor.surfaceElevated)
                .frame(width: 32, height: 56)
                .overlay(
                    Capsule().strokeBorder(RDColor.hairlineStrong, lineWidth: 0.5)
                )
                .overlay(
                    HStack(spacing: 2) {
                        Capsule().fill(RDColor.textOnStageDim).frame(width: 2, height: 14)
                        Capsule().fill(RDColor.textOnStageDim).frame(width: 2, height: 14)
                    }
                )
                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)
        }
        .frame(width: 32)  // hit area wider than visible divider line
    }

    /// Right-side "drop your RAW here" slot shown when only reference
    /// is loaded.
    private var targetDropSlot: some View {
        VStack(spacing: RDSpace.m) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(RDColor.textSecondary)
            Text("Drop your RAW here")
                .font(RDType.titleMedium)
                .foregroundStyle(RDColor.textPrimary)
            Text("Paste (⌘V) or open (⌘O).")
                .font(RDType.caption)
                .foregroundStyle(RDColor.textSecondary)
            Button("Open RAW…") {
                colorwayParser.openTargetViaPanel()
            }
            .rdButton(.secondary)
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RDColor.surfaceRaised.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: RDRadius.card)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(RDColor.hairline)
                .padding(RDSpace.m)
        )
        .padding(RDSpace.m)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers, asTarget: true)
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            handleDrop(providers: providers, asTarget: true)
        }
    }

    /// Top-of-stage eyebrow label (REFERENCE / YOUR RAW).
    private func stageLabel(_ text: String,
                            alignment: Alignment,
                            padding: CGFloat) -> some View {
        Text(text)
            .font(RDType.eyebrow)
            .tracking(1.5)
            .foregroundStyle(RDColor.textOnStageDim)
    }

    // MARK: - Right rail: coaching delta panel

    private var coachingDeltaPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header strip: title + preset name field
            VStack(alignment: .leading, spacing: RDSpace.xs) {
                Text("Coaching Delta")
                    .font(RDType.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(RDColor.textTertiary)
                TextField("Preset name", text: $colorwayParser.presetName)
                    .textFieldStyle(.roundedBorder)
                    .font(RDType.caption)
            }
            .padding(RDSpace.m)

            Divider().background(RDColor.hairline)

            // Scrollable delta rows
            ScrollView {
                if colorwayParser.targetImage == nil {
                    Text("Drop your RAW on the left to see the coaching delta.")
                        .font(RDType.caption)
                        .foregroundStyle(RDColor.textTertiary)
                        .padding(RDSpace.m)
                } else if colorwayParser.coachingDeltaRows.isEmpty {
                    ProgressView("Analyzing…")
                        .padding(RDSpace.xxxl)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        presetSectionHeader("Basic")
                        ForEach(rows(matching: [.exposure, .contrast, .highlights,
                                                .shadows, .whites, .blacks,
                                                .vibrance, .saturation])) { row in
                            coachingRow(row)
                        }
                        presetSectionHeader("White Balance")
                        ForEach(rows(matching: [.temperature, .tint])) { row in
                            coachingRow(row)
                        }
                        presetSectionHeader("HSL (read-only)")
                        // Per spec: HSL panel is read-only with a
                        // "View in Pixelmator" CTA. We don't have HSL
                        // channels inferred yet (single-image analysis
                        // doesn't produce them). Show the guidance.
                        Text("HSL channels aren't inferred from the reference image — adjust manually in Camera Raw or Pixelmator.")
                            .font(RDType.caption)
                            .foregroundStyle(RDColor.textTertiary)
                            .padding(.horizontal, RDSpace.m)
                            .padding(.vertical, RDSpace.s)
                    }
                    .padding(.vertical, RDSpace.s)
                }
            }

            Divider().background(RDColor.hairline)

            // "View in Pixelmator" CTA at the bottom of the right rail
            VStack(spacing: RDSpace.s) {
                Button {
                    colorwayParser.viewInPixelmator()
                } label: {
                    Label("View in Pixelmator", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .rdButton(.primary)
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!colorwayParser.canExport)

                HStack(spacing: RDSpace.s) {
                    Button {
                        colorwayParser.exportXMP()
                    } label: {
                        Label("Export .xmp", systemImage: "square.and.arrow.up")
                    }
                    .rdButton(.secondary)
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!colorwayParser.canExport)

                    Button {
                        colorwayParser.exportRecreationSheet()
                    } label: {
                        Label("Sheet", systemImage: "doc.text")
                    }
                    .rdButton(.secondary)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!colorwayParser.canExport)
                }
            }
            .padding(RDSpace.m)
        }
        .background(RDColor.surfaceRaised)
    }

    /// Filter the delta rows to a subset of parameters.
    private func rows(matching params: [CoachingDeltaRow.Parameter]) -> [CoachingDeltaRow] {
        colorwayParser.coachingDeltaRows.filter { params.contains($0.parameter) }
    }

    /// One delta row: parameter name on the left, [confidence dot · signed value] on the right.
    private func coachingRow(_ row: CoachingDeltaRow) -> some View {
        HStack(spacing: RDSpace.s) {
            Text(row.label)
                .font(RDType.body)
                .foregroundStyle(RDColor.textPrimary)

            if let reasoning = row.reasoning {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(RDColor.textTertiary)
                    .help(reasoning)
            }

            Spacer()

            RDConfidenceDot(row.confidence)
            RDNumberReadout(
                row.value,
                format: rdFormat(for: row.format),
                dimmed: abs(row.value) < 0.005
            )
        }
        .padding(.horizontal, RDSpace.m)
        .padding(.vertical, 4)
    }

    /// Map our `CoachingDeltaRow.Format` (declared without a UI
    /// dependency) to `RDNumberReadout.Format`.
    private func rdFormat(for f: CoachingDeltaRow.Format) -> RDNumberReadout.Format {
        switch f {
        case .signed:  return .signed
        case .ev:      return .ev
        case .percent: return .percent
        case .integer: return .integer
        case .kelvin:  return .kelvin
        }
    }

    // MARK: - Quick preset shared helpers

    private func presetSectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(RDType.eyebrow)
            .tracking(1.2)
            .foregroundStyle(RDColor.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, RDSpace.l)
            .padding(.bottom, RDSpace.xs)
    }

    private func presetNote(_ text: String) -> some View {
        Text(text)
            .font(RDType.caption)
            .foregroundStyle(RDColor.textTertiary)
            .padding(.top, RDSpace.s)
    }

    private func presetRow(
        _ name: String,
        _ value: Double,
        format: NumberFormat = .signed,
        note: String? = nil,
        dimmed: Bool = false
    ) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(dimmed ? RDColor.textSecondary : RDColor.textPrimary)
            if let note = note {
                Text("(\(note))")
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.textTertiary)
            }
            Spacer()
            RDNumberReadout(value, format: format == .ev ? .ev : .signed, dimmed: dimmed)
        }
        .padding(.vertical, 2)
    }

    private enum NumberFormat {
        case signed
        case ev
    }

    // MARK: - Drop / paste handling

    /// Resolve a list of `NSItemProvider` from a drop or paste into
    /// a single image URL, then load it as either the reference or
    /// the target.
    @discardableResult
    private func handleDrop(providers: [NSItemProvider], asTarget: Bool) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in
                        if asTarget { colorwayParser.loadTarget(from: url) }
                        else         { colorwayParser.loadReference(from: url) }
                    }
                }
            }
            return true
        }

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                Task { @MainActor in
                    if asTarget { colorwayParser.loadTarget(from: image) }
                    else         { colorwayParser.loadReference(from: image) }
                }
            }
            return true
        }

        return false
    }
}
