import SwiftUI
import AppKit

/// The main window content. Switches between Library mode (the original
/// RawDeck: import, cull, rate, lightbox) and Colorway Parser mode (paste a
/// reference image, derive a Camera Raw preset, export).
///
/// A small ZStack of hidden keyboard buttons sits on top so the rating
/// shortcuts (1-5, 0, X) work no-modifier in Library mode. Cmd+letter
/// shortcuts are handled in `RawDeckApp` via CommandMenu.
///
/// When the lightbox is open, `LightboxView` overlays the entire content
/// area — the grid remains mounted underneath so its state is preserved
/// on close (selection, scroll position, etc).
struct ContentView: View {
    @EnvironmentObject var store: PhotoStore
    @EnvironmentObject var colorwayParser: ColorwayParserModel

    /// Items shown in the left-edge nav rail. `id` matches `AppMode`'s
    /// raw value so we can bind directly.
    private let navItems: [RDNavItem] = [
        RDNavItem(id: "library", label: "Library", systemImage: "photo.on.rectangle"),
        RDNavItem(id: "colorwayParser", label: "Colorway", systemImage: "wand.and.stars"),
    ]

    var body: some View {
        // One-shot alert — surfaced when store sets `alertMessage` (e.g.
        // "Pixelmator Pro isn't installed"). Manual Binding because
        // `@EnvironmentObject` doesn't expose `$store.alertMessage`
        // directly the way `@State` would.
        HStack(spacing: 0) {
            // Left-edge nav rail (replaces the old top ModeBar).
            RDNavRail(
                selection: Binding(
                    get: { store.mode.rawValue },
                    set: { newValue in
                        if let mode = AppMode(rawValue: newValue) {
                            store.mode = mode
                        }
                    }
                ),
                items: navItems
            )

            VStack(spacing: 0) {
                // Main content area — switches based on the active mode.
                // We use ZStack with conditional children so SwiftUI keeps
                // each mode's view hierarchy mounted when you switch back
                // (preserves scroll position, text-field focus, etc.).
                ZStack {
                    libraryContent
                        .opacity(store.mode == .library ? 1 : 0)
                        .allowsHitTesting(store.mode == .library)

                    ColorwayParserView()
                        .opacity(store.mode == .colorwayParser ? 1 : 0)
                        .allowsHitTesting(store.mode == .colorwayParser)
                }

                Divider()

                // Status bar adapts per mode.
                StatusBarView()
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        // Library-mode keyboard shortcuts (1-5, 0, X, Space, arrows,
        // Esc) are only active when in Library mode. Wrapping them
        // in `if store.mode == .library` prevents them from firing
        // while the user is in Colorway Parser mode.
        .overlay(libraryShortcutsOverlay)
        .alert("RawDeck", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { newValue in if !newValue { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
    }

    /// Library-mode content: drop zone, full-screen import progress,
    /// or grid+toolbar (only after thumbnails have finished decoding).
    @ViewBuilder
    private var libraryContent: some View {
        if store.isImporting {
            // Full-screen import UI. The grid view is intentionally
            // NOT mounted here — every photo gets fully decoded
            // before the user can interact with the library. This
            // eliminates the "half loading, half aren't" bug where
            // some cells showed thumbnails while others were stuck
            // on a "Loading..." spinner indefinitely.
            ImportScreen(
                folderName: store.currentFolder?.lastPathComponent,
                totalCount: store.photos.count,
                isEnumerating: store.isLoading && store.photos.isEmpty,
                progress: store.importProgress
            )
        } else if store.photos.isEmpty {
            DropZoneView()
        } else {
            VStack(spacing: 0) {
                ToolbarView()
                Divider()
                FilterBarView()
                Divider()
                PhotoGridView()
            }
        }

        // Lightbox overlay — only mounted when open (anywhere in the
        // main area). When switching to Colorway Parser mode while the
        // lightbox is open, we keep it mounted but it's covered by
        // the mode switch — practical, since the user can just go
        // back to Library mode to see it. Hidden during import so
        // the user can't accidentally open it on a half-decoded photo.
        if store.lightboxPhotoID != nil && !store.isImporting {
            LightboxView()
        }
    }

    /// Hidden keyboard buttons for Library-mode no-modifier shortcuts.
    /// Only mounted when in Library mode (otherwise ⌘1 etc. would
    /// still try to rate a photo even though the user is in Colorway Parser).
    @ViewBuilder
    private var libraryShortcutsOverlay: some View {
        if store.mode == .library {
            VStack(spacing: 0) {
                HiddenKeyButton(key: "1", modifiers: []) {
                    store.setRating(1, photo: store.ratingTarget)
                }
                HiddenKeyButton(key: "2", modifiers: []) {
                    store.setRating(2, photo: store.ratingTarget)
                }
                HiddenKeyButton(key: "3", modifiers: []) {
                    store.setRating(3, photo: store.ratingTarget)
                }
                HiddenKeyButton(key: "4", modifiers: []) {
                    store.setRating(4, photo: store.ratingTarget)
                }
                HiddenKeyButton(key: "5", modifiers: []) {
                    store.setRating(5, photo: store.ratingTarget)
                }
                HiddenKeyButton(key: "0", modifiers: []) {
                    store.setRating(0, photo: store.ratingTarget)
                }
                HiddenKeyButton(key: "x", modifiers: []) {
                    if let target = store.ratingTarget {
                        store.toggleReject(photo: target)
                    } else {
                        store.toggleReject()
                    }
                }
                HiddenKeyButton(key: .space, modifiers: []) {
                    if store.lightboxPhotoID != nil {
                        store.closeLightbox()
                    } else if let id = store.hoveredPhotoID,
                              let p = store.photos.first(where: { $0.id == id }) {
                        store.openLightbox(on: p)
                    }
                }
                HiddenKeyButton(key: .leftArrow, modifiers: []) {
                    if store.lightboxPhotoID != nil {
                        store.lightboxStep(-1)
                    }
                }
                HiddenKeyButton(key: .rightArrow, modifiers: []) {
                    if store.lightboxPhotoID != nil {
                        store.lightboxStep(1)
                    }
                }
                HiddenKeyButton(key: .escape, modifiers: []) {
                    if store.lightboxPhotoID != nil {
                        store.closeLightbox()
                    } else {
                        store.deselectAll()
                    }
                }
            }
        }
    }
}

/// Thin status bar at the bottom: shows total photos, selected count,
/// and the keyboard shortcut hints. Adapts to the active mode.
struct StatusBarView: View {
    @EnvironmentObject var store: PhotoStore
    @EnvironmentObject var colorwayParser: ColorwayParserModel

    var body: some View {
        HStack(spacing: 16) {
            switch store.mode {
            case .library:
                libraryStatus
            case .colorwayParser:
                colorwayParserStatus
            }
            Spacer()
            shortcutHint
        }
        .padding(.horizontal, RDSpace.m)
        .padding(.vertical, RDSpace.xs + 2)
        .background(RDColor.surfaceRaised)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RDColor.hairline)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var libraryStatus: some View {
        if store.isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(RDColor.textSecondary)
            Text("Importing…")
                .font(RDType.caption)
                .foregroundStyle(RDColor.textSecondary)
        } else if let prog = store.exportProgress {
            ProgressView()
                .controlSize(.small)
                .tint(RDColor.accentPrimary)
            Text("Exporting \(prog.done) / \(prog.total)…")
                .font(RDType.caption)
                .foregroundStyle(RDColor.textSecondary)
        } else {
            Text("\(store.photos.count) photos")
                .font(RDType.caption)
                .foregroundStyle(RDColor.textSecondary)
            if !store.selectedIDs.isEmpty {
                Text("· \(store.selectedIDs.count) selected")
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.accentPrimary)
            }
        }
    }

    @ViewBuilder
    private var colorwayParserStatus: some View {
        if colorwayParser.displayImage == nil {
            Text("Paste or drop a reference image to start.")
                .font(RDType.caption)
                .foregroundStyle(RDColor.textSecondary)
        } else if let err = colorwayParser.lastError {
            Text(err)
                .font(RDType.caption)
                .foregroundStyle(RDColor.destructive)
        } else if colorwayParser.preset != nil {
            Text("Preset ready: \(colorwayParser.presetName)")
                .font(RDType.caption)
                .foregroundStyle(RDColor.accentPrimary)
        } else {
            Text("Analyzing…")
                .font(RDType.caption)
                .foregroundStyle(RDColor.textSecondary)
        }
    }

    private var shortcutHint: some View {
        Group {
            switch store.mode {
            case .library:
                Text("1-5: rate · 0: clear · X: reject · Space: lightbox · ←/→: nav · Esc: close · Delete: trash · ⌘A: all · ⌘O: import · ⌘⇧O: open in Pixelmator · Double-click: open photo")
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.textTertiary)
            case .colorwayParser:
                Text("⌘O: open · ⌘V: paste · ⌘E: export .xmp · ⌘⇧E: recreation sheet")
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.textTertiary)
            }
        }
    }
}


/// Top-of-grid progress strip showing how many thumbnails have been
/// decoded so far during the import phase and an ETA for the
/// remaining files. Visible only while `store.importProgress` is
/// non-nil. Slim (28pt) so it doesn't dominate the layout.
struct ImportProgressBar: View {
    let progress: PhotoStore.ImportProgress

    private var fraction: Double {
        guard progress.total > 0 else { return 0 }
        return Double(progress.done) / Double(progress.total)
    }

    private var etaText: String {
        guard let eta = progress.etaSeconds else { return "Estimating…" }
        if eta < 60 { return "\(Int(eta))s remaining" }
        if eta < 3600 {
            let m = Int(eta / 60)
            let s = Int(eta.truncatingRemainder(dividingBy: 60))
            return "\(m)m \(s)s remaining"
        }
        let h = Int(eta / 3600)
        let m = Int((eta.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(h)h \(m)m remaining"
    }

    var body: some View {
        HStack(spacing: RDSpace.m) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(RDColor.accentPrimary)
                .frame(maxWidth: 240)
            Text("Importing thumbnails \(progress.done) / \(progress.total)")
                .font(RDType.caption)
                .foregroundStyle(RDColor.textSecondary)
                .monospacedDigit()
            Spacer()
            Text(etaText)
                .font(RDType.caption)
                .foregroundStyle(RDColor.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, RDSpace.l)
        .padding(.vertical, RDSpace.xs + 2)
        .background(RDColor.surfaceRaised)
    }
}


    /// Full-screen import progress UI. Shown in place of the grid view
    /// during the entire import process (folder enumeration + thumbnail
    /// decode). The grid view is NOT mounted while this is on screen, so
    /// the user can't interact with half-decoded photos.
    ///
    /// Layout: large folder icon + folder name + photo count, then a
    /// horizontal progress bar with "X of Y loaded" and ETA. During the
    /// enumeration phase (when we don't yet know how many files we'll
    /// find) we show an indeterminate ProgressView and a "Reading
    /// folder…" caption instead of a determinate bar.
    struct ImportScreen: View {
        let folderName: String?
        let totalCount: Int
        let isEnumerating: Bool
        let progress: PhotoStore.ImportProgress?

        private var fraction: Double {
            guard let progress = progress, progress.total > 0 else { return 0 }
            return Double(progress.done) / Double(progress.total)
        }

        private var etaText: String {
            guard let eta = progress?.etaSeconds else { return "Estimating…" }
            if eta < 60 { return "\(Int(eta))s remaining" }
            if eta < 3600 {
                let m = Int(eta / 60)
                let s = Int(eta.truncatingRemainder(dividingBy: 60))
                return "\(m)m \(s)s remaining"
            }
            let h = Int(eta / 3600)
            let m = Int((eta.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(h)h \(m)m remaining"
        }

        var body: some View {
            VStack(spacing: RDSpace.xl) {
                Spacer()

                // Folder icon + name + count
                VStack(spacing: RDSpace.s) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(RDColor.textSecondary)
                    if let name = folderName {
                        Text(name)
                            .font(RDType.displayLarge)
                            .foregroundStyle(RDColor.textPrimary)
                    }
                    if totalCount > 0 {
                        Text("\(totalCount) photo\(totalCount == 1 ? "" : "s")")
                            .font(RDType.body)
                            .foregroundStyle(RDColor.textSecondary)
                    }
                }

                // Progress section
                VStack(spacing: RDSpace.m) {
                    if isEnumerating {
                        // Phase 1: enumerating the folder. We don't know
                        // how many files we'll find yet — show an
                        // indeterminate ProgressView.
                        ProgressView()
                            .controlSize(.large)
                            .tint(RDColor.accentPrimary)
                        Text("Reading folder…")
                            .font(RDType.body)
                            .foregroundStyle(RDColor.textSecondary)
                    } else if let progress = progress {
                        // Phase 2: decoding thumbnails. Determinate bar
                        // with done/total/ETA.
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(RDColor.accentPrimary)
                            .frame(width: 480)

                        HStack {
                            Text("\(progress.done) of \(progress.total) thumbnails loaded")
                                .font(RDType.body)
                                .foregroundStyle(RDColor.textPrimary)
                                .monospacedDigit()
                            Spacer()
                            Text(etaText)
                                .font(RDType.body)
                                .foregroundStyle(RDColor.textSecondary)
                                .monospacedDigit()
                        }
                        .frame(width: 480)
                    } else {
                        // Edge case: importing but neither enumerating
                        // nor decoding — should be transient.
                        ProgressView()
                            .controlSize(.large)
                            .tint(RDColor.accentPrimary)
                    }
                }

                Spacer()

                // Footer hint — explains what's happening so the user
                // doesn't think the app is frozen. Cold-cache CR3s take
                // 5-25s each, so a 408-photo import can take 30-90
                // minutes. Without this hint the user can't tell whether
                // it's working or stuck.
                Text("Importing may take several minutes for large folders. The grid will appear when all thumbnails are ready.")
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .padding(.bottom, RDSpace.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RDColor.surfaceBase)
        }
    }

