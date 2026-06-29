import SwiftUI
import AppKit

/// The main window content. Either shows the drop zone (no folder imported)
/// or the toolbar + grid (folder imported).
///
/// A small ZStack of hidden keyboard buttons sits on top so the rating
/// shortcuts (1-5, 0, X) work no-modifier. Cmd+letter shortcuts are
/// handled in `RawDeckApp` via CommandMenu.
///
/// When the lightbox is open, `LightboxView` overlays the entire content
/// area — the grid remains mounted underneath so its state is preserved
/// on close (selection, scroll position, etc).
struct ContentView: View {
    @EnvironmentObject var store: PhotoStore

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
        ZStack {
            // Base layer: drop zone OR grid+toolbar.
            Group {
                if store.photos.isEmpty && !store.isLoading {
                    DropZoneView()
                } else {
                    VStack(spacing: 0) {
                        ToolbarView()
                        Divider()
                        FilterBarView()
                        Divider()
                        PhotoGridView()
                        StatusBarView()
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 600)

            // Lightbox overlay — only mounted when open.
            if store.lightboxPhotoID != nil {
                LightboxView()
            }

            // Hidden shortcut buttons for no-modifier keys.
            // Order matters: SwiftUI fires the first match.
            // - 1-5 / 0: rate the lightbox photo (if open), the single
            //   selection, or no-op (per Fin B's spec: numbers must
            //   correlate with stars regardless of mode).
            // - X: toggle reject on the same target.
            // - Space: open lightbox on hovered photo (or close if open).
            // - Left / Right: lightbox navigation.
            // - Esc: close lightbox (or deselect in grid).
            // - Delete: NOT bound here — `RawDeckApp.swift` binds it via
            //   the CommandMenu and `trashSelection()` is already
            //   lightbox-aware. A second binding would double-fire and
            //   trash two photos per keypress.
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
        .alert("RawDeck", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { newValue in if !newValue { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
    }
}

/// Thin status bar at the bottom: shows total photos, selected count,
/// and the keyboard shortcut hints.
struct StatusBarView: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        HStack(spacing: 16) {
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
            Spacer()
            Text("1-5: rate · 0: clear · X: reject · Space: lightbox · ←/→: nav · Esc: close · Delete: trash · ⌘A: all · ⌘O: import · ⌘⇧O: open in Pixelmator · Double-click: open photo")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
