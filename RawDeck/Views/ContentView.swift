import SwiftUI
import AppKit

/// The main window content. Either shows the drop zone (no folder imported)
/// or the toolbar + grid (folder imported).
///
/// A small ZStack of hidden keyboard buttons sits on top so the rating
/// shortcuts (1-5, 0, X) work no-modifier. Cmd+letter shortcuts are
/// handled in `RawDeckApp` via CommandMenu.
struct ContentView: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        ZStack {
            Group {
                if store.photos.isEmpty && !store.isLoading {
                    DropZoneView()
                } else {
                    VStack(spacing: 0) {
                        ToolbarView()
                        Divider()
                        PhotoGridView()
                        StatusBarView()
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 600)

            // Hidden shortcut buttons for no-modifier keys.
            // Order matters: SwiftUI fires the first match. 1-5 rate, 0 clears,
            // X toggles reject, Delete trashes.
            VStack(spacing: 0) {
                HiddenKeyButton(key: "1", modifiers: []) { store.setRating(1) }
                HiddenKeyButton(key: "2", modifiers: []) { store.setRating(2) }
                HiddenKeyButton(key: "3", modifiers: []) { store.setRating(3) }
                HiddenKeyButton(key: "4", modifiers: []) { store.setRating(4) }
                HiddenKeyButton(key: "5", modifiers: []) { store.setRating(5) }
                HiddenKeyButton(key: "0", modifiers: []) { store.setRating(0) }
                HiddenKeyButton(key: "x", modifiers: []) { store.toggleReject() }
            }
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
            Text("1-5: rate · X: reject · Delete: trash · ⌘A: select all · Esc: clear · ⌘O: import · ⌘⇧O: open in Pixelmator · Double-click: open photo")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
