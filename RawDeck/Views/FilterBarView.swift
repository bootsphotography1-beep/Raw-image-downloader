import SwiftUI
import AppKit

/// Filter bar shown above the photo grid. Lightroom-style — a horizontal
/// strip with the filter controls and a status text. Sits between the
/// ToolbarView (sort + counts) and the PhotoGridView (the actual photos).
///
/// Layout (left to right):
/// - "Showing N of M" status (e.g. "Showing 247 of 1,243")
/// - "· ★4 and up" / "· ★4 only" hint when a rating filter is active
/// - 5 star buttons (★1 through ★5). Clicking cycles through three states:
///     off → "≥N" (minimum) → "=N only" (exact) → off
///   so the user can isolate a single rating bucket ("show me ONLY 1-stars")
///   for targeted culling/delete.
/// - "Rejects only" pill — when on, only rejected photos show (inverse of
///   "Hide rejected"). Useful for reviewing your rejects before trashing.
/// - "Hide rejected" pill — when on, rejected photos are hidden.
/// - Clear (×) button when any filter is active.
struct FilterBarView: View {
    @EnvironmentObject var store: PhotoStore

    /// True when any filter is narrowing the grid below the raw photo count.
    var hasActiveFilter: Bool {
        store.ratingFilterMode != .none || store.hideRejected || store.showRejectsOnly
    }

    var body: some View {
        HStack(spacing: RDSpace.m) {
            // Status text
            HStack(spacing: RDSpace.xs + 2) {
                if hasActiveFilter {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(RDColor.accentPrimary)
                }
                Text(statusText)
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.textSecondary)
            }

            Spacer()

            // Rating floor — 5 star buttons. Each button cycles through
            // three states (off → minimum → exact → off). The currently-
            // active state is highlighted: minimum = dim amber background,
            // exact = bright amber background with a small "=" badge.
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
                        .foregroundStyle(RDColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear all filters (show every photo)")
            }

            Divider().frame(height: 16)

            // Reject controls — two pill buttons that are mutually
            // exclusive. Only one can be active at a time.
            //
            // "Rejects only" (left): when on, ONLY rejected photos are
            // shown. Useful for reviewing your X-marked photos before
            // bulk-deleting them ("let me see what I marked X, then
            // select-all and trash").
            //
            // "Hide rejected" (right): when on, rejected photos are
            // hidden from the grid (so you can focus on the keepers).
            // Off (default): rejected photos are shown normally.
            HStack(spacing: RDSpace.xs) {
                Button {
                    store.toggleShowRejectsOnly()
                } label: {
                    HStack(spacing: RDSpace.xs) {
                        Image(systemName: store.showRejectsOnly
                              ? "xmark.circle.fill"
                              : "xmark.circle")
                            .font(.caption)
                        Text(store.showRejectsOnly ? "Rejects only" : "Rejects only")
                            .font(RDType.caption)
                    }
                    .padding(.horizontal, RDSpace.s)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(store.showRejectsOnly
                                  ? RDColor.destructive
                                  : RDColor.surfaceElevated)
                    )
                    .foregroundStyle(store.showRejectsOnly ? RDColor.textOnStage : RDColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help(store.showRejectsOnly
                      ? "Showing only rejected photos. Click to show everything."
                      : "Show only photos marked with X (rejected).")

                Button {
                    store.toggleHideRejected()
                } label: {
                    HStack(spacing: RDSpace.xs) {
                        Image(systemName: store.hideRejected ? "eye.slash.fill" : "eye.slash")
                            .font(.caption)
                        Text(store.hideRejected ? "Hiding rejected" : "Hide rejected")
                            .font(RDType.caption)
                    }
                    .padding(.horizontal, RDSpace.s)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(store.hideRejected
                                  ? RDColor.destructiveDim
                                  : RDColor.surfaceElevated)
                    )
                    .foregroundStyle(store.hideRejected ? RDColor.destructive : RDColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help(store.hideRejected
                      ? "Show rejected photos again"
                      : "Hide rejected photos from the grid")
            }
        }
        .padding(.horizontal, RDSpace.l)
        .padding(.vertical, RDSpace.xs + 2)
        .background(RDColor.surfaceRaised)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RDColor.hairline)
                .frame(height: 0.5)
        }
    }

    /// "Showing N of M" text. Includes the rating filter suffix when active
    /// ("· ★3 and up" or "· ★3 only") and the rejects-mode suffix.
    private var statusText: String {
        let shown = store.visibleCount
        let total = store.photos.count
        var parts: [String] = []
        parts.append("Showing \(shown) of \(total)")
        switch store.ratingFilterMode {
        case .none:
            break
        case .minimum(let n):
            let suffix = n == 5 ? "★5 only" : "★\(n) and up"
            parts.append(suffix)
        case .exact(let n):
            parts.append("★\(n) only")
        }
        if store.showRejectsOnly {
            parts.append("rejects only")
        } else if store.hideRejected {
            parts.append("rejects hidden")
        }
        return parts.joined(separator: " · ")
    }
}

/// One button in the rating-filter row. Shows `stars` filled stars
/// (warm amber) plus `5 - stars` outlined stars, with state-specific
/// styling to indicate which mode the button is in.
///
/// State-derived styling:
/// - `.none` for that star (filter inactive for this bucket): dim/no
///   background, regular amber stars
/// - `.minimum(stars)` (filter is "≥N" — showing this star and above):
///   amber-tinted background
/// - `.exact(stars)` (filter is "=N only" — showing exactly this bucket):
///   bright amber background with a small "=" badge next to the stars
///
/// Clicking cycles the filter through the three states for this star.
/// See `PhotoStore.cycleRatingFilter(to:)` for the full transition rules.
struct StarFilterButton: View {
    @EnvironmentObject var store: PhotoStore
    let stars: Int

    /// The current mode of this star's filter, or `.none` if not active.
    private var currentMode: PhotoStore.RatingFilterMode {
        switch store.ratingFilterMode {
        case .none: return .none
        case .minimum(let n) where n == stars: return .minimum(stars)
        case .exact(let n) where n == stars: return .exact(stars)
        default: return .none
        }
    }

    var body: some View {
        Button {
            store.cycleRatingFilter(to: stars)
        } label: {
            HStack(spacing: 2) {
                RDStarRow(
                    rating: stars,
                    size: 13,
                    isInteractive: false
                )
                if currentMode == .exact(stars) {
                    Text("=")
                        .font(.system(size: 11, weight: .bold, design: .default))
                        .foregroundStyle(RDColor.starActive)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RDSpace.xs)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: RDRadius.button, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RDRadius.button, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .help(helpText)
    }

    /// Background color depends on which mode this star's filter is in.
    private var backgroundFill: Color {
        switch currentMode {
        case .none:
            return .clear
        case .minimum:
            return RDColor.starActiveDim
        case .exact:
            return RDColor.starActive.opacity(0.35)
        }
    }

    /// Border color depends on mode. None = no border, exact = bright.
    private var borderColor: Color {
        switch currentMode {
        case .none: return .clear
        case .minimum: return RDColor.starActive.opacity(0.30)
        case .exact: return RDColor.starActive.opacity(0.70)
        }
    }

    /// Tooltip text reflects the current mode and what the next click does.
    private var helpText: String {
        switch currentMode {
        case .none:
            return "Click: show \(stars)+ stars · click again for exact \(stars)-only"
        case .minimum:
            return "Currently showing \(stars)+ stars · Click to switch to \(stars)-only · Click again to clear"
        case .exact:
            return "Currently showing ONLY \(stars)-star photos · Click to clear filter"
        }
    }
}