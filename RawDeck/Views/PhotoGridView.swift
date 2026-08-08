import SwiftUI
import AppKit

/// The main photo grid.
///
/// Design discipline (v2):
///  - Contact-sheet style: cells touch each other (1px gap), no padding
///    ring, 3:2 native RAW aspect. This is how Lightroom / Capture One /
///    Photo Mechanic do it.
///  - Empty-state inside the grid (filter hides everything) is a single
///    mono line, not a giant icon + headline + button.
///  - LazyVGrid is unchanged — it only renders visible cells. The cap
///    on in-flight thumbnails lives in PhotoStore.loadThumbnails.
struct PhotoGridView: View {
    @EnvironmentObject var store: PhotoStore

    /// Column template: 3:2 aspect cells, min 220pt wide, max 320pt wide.
    /// 1pt gap so the cell's hairline border renders cleanly between cells.
    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 1)
    ]

    var body: some View {
        if store.visiblePhotos.isEmpty && !store.photos.isEmpty {
            emptyFilteredState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(Array(store.visiblePhotos.enumerated()), id: \.element.id) { idx, photo in
                        ThumbnailCell(photo: photo)
                            .onAppear {
                                // Lazy-load thumbnails for cells coming into view.
                                // The visiblePhotos index can shift as the
                                // filter/sort changes, but `loadThumbnails`
                                // dedupes by photo id, so reloading the same
                                // range multiple times is harmless.
                                let start = max(0, idx - 10)
                                let end = min(store.visiblePhotos.count, idx + 30)
                                store.loadThumbnails(in: start..<end)
                            }
                    }
                }
                .padding(0)
            }
            .background(RDColor.surfaceBase)
        }
    }

    /// Human-readable description of the active filters. Used in the
    /// "no photos match" empty state.
    private var filterDescription: String {
        var parts: [String] = []
        switch store.ratingFilterMode {
        case .none:
            break
        case .minimum(let n):
            parts.append(n == 5 ? "★5 only" : "★\(n) and up")
        case .exact(let n):
            parts.append("★\(n) only")
        }
        if store.showRejectsOnly {
            parts.append("rejects only")
        } else if store.hideRejected {
            parts.append("rejects hidden")
        }
        return parts.isEmpty ? "no filter" : parts.joined(separator: ", ")
    }

    /// Shown when the filter hides every photo. Single mono line + click-to-clear.
    /// No icon, no headline. Matches the rest of the v2 chrome.
    private var emptyFilteredState: some View {
        VStack(spacing: RDSpace.s) {
            Text("no photos match")
                .font(RDType.caption)
                .foregroundStyle(RDColor.textTertiary)
            Text(filterDescription)
                .font(RDType.microMono)
                .foregroundStyle(RDColor.textSecondary)
            Button("clear filter") {
                store.resetFilters()
            }
            .buttonStyle(.plain)
            .font(RDType.microMono)
            .foregroundStyle(RDColor.accentPrimary)
            .padding(.top, RDSpace.xs)
            .help("Show every photo in the folder")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RDColor.surfaceBase)
    }
}