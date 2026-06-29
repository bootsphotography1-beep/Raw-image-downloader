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

    var body: some View {
        // The per-cell `.onHover` already clears `hoveredPhotoID` when the
        // cursor leaves the cell. When the cursor moves directly between
        // two cells, the outgoing cell's `onHover(false)` and the incoming
        // cell's `onHover(true)` fire in sequence; the guard
        // `store.hoveredPhotoID == photo.id` in `ThumbnailCell` prevents
        // the outgoing cell from clearing the value the incoming cell just
        // set.

        // One-shot alert — surfaced when store sets `alertMessage` (e.g.
        // "Pixelmator Pro isn't installed"). Manual Binding because
        // `@EnvironmentObject` doesn't expose `$store.alertMessage`
        // directly the way `@State` would.
        VStack(spacing: 0) {
            // Top: mode picker (Library | Colorway Parser)
            ModeBar()

            Divider()

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

    /// Library-mode content: drop zone OR grid+toolbar.
    @ViewBuilder
    private var libraryContent: some View {
        if store.photos.isEmpty && !store.isLoading {
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
        // back to Library mode to see it.
        if store.lightboxPhotoID != nil {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var libraryStatus: some View {
        if store.isLoading {
            ProgressView()
                .controlSize(.small)
            Text("Importing…")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("\(store.photos.count) photos")
                .font(.caption)
                .foregroundColor(.secondary)
            if !store.selectedIDs.isEmpty {
                Text("· \(store.selectedIDs.count) selected")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
    }

    @ViewBuilder
    private var colorwayParserStatus: some View {
        if colorwayParser.displayImage == nil {
            Text("Paste or drop a reference image to start.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let err = colorwayParser.lastError {
            Text(err)
                .font(.caption)
                .foregroundColor(.red)
        } else if colorwayParser.preset != nil {
            Text("Preset ready: \(colorwayParser.presetName)")
                .font(.caption)
                .foregroundColor(.accentColor)
        } else {
            Text("Analyzing…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var shortcutHint: some View {
        Group {
            switch store.mode {
            case .library:
                Text("1-5: rate · 0: clear · X: reject · Space: lightbox · ←/→: nav · Esc: close · Delete: trash · ⌘A: all · ⌘O: import · ⌘⇧O: open in Pixelmator · Double-click: open photo")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            case .colorwayParser:
                Text("⌘O: open · ⌘V: paste · ⌘E: export .xmp · ⌘⇧E: recreation sheet")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}