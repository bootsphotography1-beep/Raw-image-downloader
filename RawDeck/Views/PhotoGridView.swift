import SwiftUI
import AppKit

/// The main photo grid. Adaptive columns: as many as fit at the current width,
/// each cell minimum 150px. LazyVGrid means we only render visible cells.
///
/// Reads from `store.visiblePhotos` (the filter-and-sorted subset), NOT
/// `store.photos` directly — so when the user picks a sort or rating
/// filter, only matching photos show up.
struct PhotoGridView: View {
    @EnvironmentObject var store: PhotoStore

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)
    ]

    var body: some View {
        // Empty-state inside the grid when the filter hides everything.
        // The toolbar/filterbar still shows the raw count so the user
        // knows what's hidden.
        if store.visiblePhotos.isEmpty && !store.photos.isEmpty {
            emptyFilteredState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(store.visiblePhotos.enumerated()), id: \.element.id) { idx, photo in
                        ThumbnailCell(photo: photo)
                            .onAppear {
                                // Lazy-load thumbnails for cells coming into view.
                                // Note: the visiblePhotos index can shift as the
                                // filter/sort changes, but `loadThumbnails`
                                // dedupes by photo id, so reloading the same
                                // range multiple times is harmless.
                                let start = max(0, idx - 10)
                                let end = min(store.visiblePhotos.count, idx + 30)
                                store.loadThumbnails(in: start..<end)
                            }
                    }
                }
                .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    /// Shown when the filter hides every photo. Tells the user what's
    /// happening and gives a one-click way to clear the filter.
    private var emptyFilteredState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No photos match the current filter")
                .font(.headline)
            Text("You have \(store.photos.count) photos in this folder, but none match ★\(store.ratingFilter) and up\(store.hideRejected ? " (and rejects are hidden)" : "").")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Clear filter") {
                store.resetFilters()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}