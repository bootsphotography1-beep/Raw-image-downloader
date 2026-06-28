import SwiftUI
import AppKit

/// Filter bar shown above the photo grid. Lightroom-style — a horizontal
/// strip with the filter controls and a status text. Sits between the
/// ToolbarView (sort + counts) and the PhotoGridView (the actual photos).
///
/// Layout (left to right):
/// - "Showing N of M" status (e.g. "Showing 247 of 1,243")
/// - "· ★4 and up" hint when a rating filter is active
/// - 5 star icons (★1 through ★5). Clicking sets the rating floor.
/// - A clear (×) button when any filter is active
/// - A reject toggle (pill button) — when on, rejected photos are hidden
struct FilterBarView: View {
    @EnvironmentObject var store: PhotoStore

    /// True when any filter is narrowing the grid below the raw photo count.
    var hasActiveFilter: Bool {
        store.ratingFilter > 0 || store.hideRejected
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status text
            HStack(spacing: 6) {
                if hasActiveFilter {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundColor(.accentColor)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Rating floor — 5 star buttons. Each button sets the
            // rating filter to that value (so clicking ★3 means "show
            // 3, 4, and 5 stars"). The currently-active floor is
            // highlighted yellow.
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { i in
                    StarFilterButton(stars: i)
                }
            }

            // Clear filter — only visible when a filter is active.
            if hasActiveFilter {
                Button {
                    store.resetFilters()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear all filters (show every photo)")
            }

            Divider().frame(height: 16)

            // Reject toggle — pill button. Off (default): rejected photos
            // are shown normally. On: rejected photos hidden.
            Button {
                store.hideRejected.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.hideRejected ? "eye.slash.fill" : "eye.slash")
                        .font(.caption)
                    Text(store.hideRejected ? "Hiding rejected" : "Hide rejected")
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(store.hideRejected
                              ? Color.red.opacity(0.15)
                              : Color.secondary.opacity(0.1))
                )
                .foregroundColor(store.hideRejected ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(store.hideRejected
                  ? "Show rejected photos again"
                  : "Hide rejected photos from the grid")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// "Showing N of M" text. Includes the rating floor when active.
    private var statusText: String {
        let shown = store.visibleCount
        let total = store.photos.count
        var parts: [String] = []
        parts.append("Showing \(shown) of \(total)")
        if store.ratingFilter > 0 {
            let suffix = store.ratingFilter == 5 ? "★5 only" : "★\(store.ratingFilter) and up"
            parts.append(suffix)
        }
        if store.hideRejected {
            parts.append("rejects hidden")
        }
        return parts.joined(separator: " · ")
    }
}

/// One button in the rating-floor row. Shows `stars` filled stars (yellow
/// when active, dim otherwise) and `5 - stars` empty stars. Clicking
/// sets `store.ratingFilter = stars`. Clicking the already-active button
/// clears the filter back to 0 (toggle behaviour).
struct StarFilterButton: View {
    @EnvironmentObject var store: PhotoStore
    let stars: Int

    var isActive: Bool { store.ratingFilter == stars }

    var body: some View {
        Button {
            if isActive {
                // Toggle off — clicking the active button clears the floor.
                store.setRatingFilter(0)
            } else {
                store.setRatingFilter(stars)
            }
        } label: {
            HStack(spacing: 0) {
                // Filled stars
                ForEach(1...stars, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: 13))
                        .foregroundColor(isActive ? .yellow : .yellow.opacity(0.7))
                }
                // Empty stars. Guard against the empty range: when
                // stars == 5 there are no empty stars, and `6...5`
                // traps at runtime in Swift. Use a static empty array
                // in that case.
                ForEach(emptyStarIndices, id: \.self) { _ in
                    Image(systemName: "star")
                        .font(.system(size: 13))
                        .foregroundColor(isActive ? .yellow.opacity(0.5) : .secondary.opacity(0.4))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? Color.yellow.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isActive ? Color.yellow.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
        )
        .help("Show photos rated \(stars) or higher")
    }

    /// Indices for the dim/empty stars. Empty when `stars == 5` to avoid
    /// the runtime trap on the reversed `6...5` range.
    private var emptyStarIndices: [Int] {
        guard stars < 5 else { return [] }
        return Array((stars + 1)...5)
    }
}