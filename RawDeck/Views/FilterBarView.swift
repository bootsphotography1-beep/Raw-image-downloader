import SwiftUI
import AppKit

/// Filter bar shown above the photo grid.
///
/// Design discipline (v2):
///  - Single row of mono keys + toggles. NOT two stacked pill bars.
///  - Rating keys cycle through 3 states (off → minimum → exact → off)
///    just like v1 — the store API is unchanged. The visual presentation
///    is just tighter: mono labels, no rounded pills, accent-blue
///    background for the active state.
///  - Same filtering semantics as before, just rendered with pro-tool
///    chrome. The user can still click ★3 to "show ★3 and up", and click
///    it again to switch to "exact ★3 only", and again to clear.
///
/// Layout (left to right):
///  - Section label "FILTER" — uppercase tracked mono
///  - 5 star keys (★1 … ★5) showing current state via background color
///  - Section label "REJECTS" + 2 toggle keys (hide / only)
///  - Clear filter × (only when any filter is active)
struct FilterBarView: View {
    @EnvironmentObject var store: PhotoStore

    var hasActiveFilter: Bool {
        store.ratingFilterMode != .none || store.hideRejected || store.showRejectsOnly
    }

    var body: some View {
        HStack(spacing: 0) {
            SectionLabel("Filter")
            // 5 star keys. Each cycles through 3 states via store.cycleRatingFilter.
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { i in
                    StarKey(stars: i)
                }
            }
            .padding(.leading, RDSpace.s)

            Divider().frame(height: 16).padding(.horizontal, RDSpace.m)

            SectionLabel("Rejects")
            RejectKey(label: "hide", isActive: store.hideRejected) {
                store.toggleHideRejected()
            }
            RejectKey(label: "only", isActive: store.showRejectsOnly) {
                store.toggleShowRejectsOnly()
            }

            if hasActiveFilter {
                Divider().frame(height: 16).padding(.horizontal, RDSpace.m)
                Button {
                    store.resetFilters()
                } label: {
                    Text("×")
                        .font(RDType.microMono)
                        .foregroundStyle(RDColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear all filters")
            }

            Spacer()
        }
        .frame(height: 28)
        .padding(.horizontal, RDSpace.l)
        .background(RDColor.surfaceBase)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RDColor.hairline)
                .frame(height: 0.5)
        }
    }
}

// MARK: - Star key (rating filter button)

/// A single star filter key. Shows `stars` filled stars. Background
/// color indicates current mode:
///  - .none      → transparent (idle)
///  - .minimum   → starActiveDim (warm amber tint)
///  - .exact     → starActive.opacity(0.45) (bright amber)
///
/// Clicking calls `store.cycleRatingFilter(to:)` which advances through
/// the three states. The store API is unchanged.
private struct StarKey: View {
    @EnvironmentObject var store: PhotoStore
    let stars: Int

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
            HStack(spacing: 3) {
                // 5-star glyph for this bucket.
                Text(String(repeating: "★", count: stars) +
                     String(repeating: "·", count: max(0, 5 - stars)))
                    .font(RDType.microMono)
                    .foregroundStyle(foregroundColor)
                if case .exact = currentMode {
                    Text("=")
                        .font(RDType.microMono)
                        .foregroundStyle(RDColor.starActive)
                }
            }
            .padding(.horizontal, RDSpace.s)
            .padding(.vertical, 3)
            .background(Rectangle().fill(backgroundFill))
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var foregroundColor: Color {
        switch currentMode {
        case .none: return RDColor.textSecondary
        case .minimum: return RDColor.textPrimary
        case .exact: return RDColor.textPrimary
        }
    }

    private var backgroundFill: Color {
        switch currentMode {
        case .none: return .clear
        case .minimum: return RDColor.starActiveDim
        case .exact: return RDColor.starActive.opacity(0.45)
        }
    }

    private var helpText: String {
        switch currentMode {
        case .none:
            return "Click: ★\(stars) and up · click again for exact ★\(stars)-only"
        case .minimum:
            return "Currently ★\(stars) and up · Click for exact · Click again to clear"
        case .exact:
            return "Currently ★\(stars) only · Click to clear"
        }
    }
}

// MARK: - Reject toggle key

/// Mono text key for hide/only reject toggles. Active state is the
/// destructive color. Inactive is hairline.
private struct RejectKey: View {
    let label: String
    let isActive: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(RDType.microMono)
                .foregroundStyle(isActive ? RDColor.textOnStage : RDColor.textTertiary)
                .padding(.horizontal, RDSpace.s)
                .padding(.vertical, 3)
                .background(Rectangle().fill(isActive ? RDColor.destructive : .clear))
        }
        .buttonStyle(.plain)
        .padding(.leading, 1)
    }
}

// MARK: - Section label (uppercase tracked mono)

private struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(RDType.microMono)
            .tracking(1.8)
            .foregroundStyle(RDColor.textTertiary)
    }
}