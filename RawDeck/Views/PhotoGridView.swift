import SwiftUI
import AppKit

/// The main photo grid. Adaptive columns: as many as fit at the current width,
/// each cell minimum 150px. LazyVGrid means we only render visible cells.
struct PhotoGridView: View {
    @EnvironmentObject var store: PhotoStore

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(store.photos.enumerated()), id: \.element.id) { idx, photo in
                    ThumbnailCell(photo: photo)
                        .onAppear {
                            // Lazy-load thumbnails for cells coming into view
                            let start = max(0, idx - 10)
                            let end = min(store.photos.count, idx + 30)
                            store.loadThumbnails(in: start..<end)
                        }
                }
            }
            .padding(12)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}
