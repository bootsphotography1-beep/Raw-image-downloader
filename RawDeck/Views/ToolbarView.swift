import SwiftUI
import AppKit

/// Top toolbar.
///
/// Design discipline (v2):
///  - One row, 32pt tall, dense. No padding ring.
///  - All action labels in sans-serif at 12pt; all metadata (counts,
///    star counts, rejected count) in monospace.
///  - Hotkey hints inline next to the action they belong to.
///  - No rounded pill backgrounds on the star-count chips — they sit as
///    mono text next to the divider.
///  - Wordmark is a single uppercase tracked label, not a "logo + dot"
///    pair (which was the v1 SaaS-look mistake).
///
/// All action methods on PhotoStore are unchanged — this is a chrome
/// refactor only.
struct ToolbarView: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        HStack(spacing: 0) {
            // Wordmark — single uppercase tracked label.
            Text("RAWDECK")
                .font(RDType.microMono)
                .tracking(1.8)
                .foregroundStyle(RDColor.textPrimary)
                .padding(.trailing, RDSpace.s)

            VDivider()

            // New Import / Close session
            ToolbarAction(label: "New Import", hotkey: nil) {
                store.photos = []
                store.selectedIDs = []
                store.currentFolder = nil
                store.resetFilters()
            }

            VDivider()

            // Folder name + count (only when a folder is loaded)
            if let folder = store.currentFolder {
                HStack(spacing: RDSpace.xs) {
                    Text(folder.lastPathComponent)
                        .font(RDType.titleMedium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("· \(store.photos.count)")
                        .font(RDType.captionMono)
                        .foregroundStyle(RDColor.textSecondary)
                }
                .padding(.horizontal, RDSpace.s)
                VDivider()
            }

            // Sort menu — borderless button, label only.
            Menu {
                ForEach(SortMode.allCases) { mode in
                    Button {
                        store.sortMode = mode
                    } label: {
                        if store.sortMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                Text(store.sortMode.label)
                    .font(RDType.body)
                    .foregroundStyle(RDColor.textPrimary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, RDSpace.s)
            .help("Sort the grid by filename or star rating")

            Spacer()

            // Star count chips — mono text, no rounded backgrounds.
            // v1 had each count inside a RoundedRectangle; v2 just shows
            // the number in mono with a star icon. Pro tools don't box
            // their metadata.
            HStack(spacing: RDSpace.m) {
                ForEach(1...5, id: \.self) { i in
                    let n = store.count(rating: i)
                    if n > 0 {
                        HStack(spacing: 3) {
                            Text("★\(i)")
                                .font(RDType.microMono)
                                .foregroundStyle(RDColor.starActive)
                            Text("\(n)")
                                .font(RDType.captionMono)
                                .foregroundStyle(RDColor.textPrimary)
                                .monospacedDigit()
                        }
                    }
                }
                if store.rejectedCount > 0 {
                    HStack(spacing: 3) {
                        Text("✕")
                            .font(RDType.microMono)
                            .foregroundStyle(RDColor.destructive)
                        Text("\(store.rejectedCount)")
                            .font(RDType.captionMono)
                            .foregroundStyle(RDColor.textPrimary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, RDSpace.s)

            VDivider()

            // Pixelmator
            ToolbarAction(
                label: "Open in Pixelmator",
                hotkey: "⌘⇧O",
                disabled: store.photos.isEmpty
            ) {
                store.openSelectionInPixelmator()
            }
            .help("Open selected photos (or all visible photos) in Pixelmator Pro")

            // Reveal
            ToolbarAction(
                label: "Reveal",
                hotkey: "⌘⇧R",
                disabled: store.photos.isEmpty
            ) {
                store.revealSelectionInFinder()
            }
            .help("Reveal selected photos in Finder")

            // Export
            ToolbarAction(
                label: "Export",
                hotkey: "⌘E",
                disabled: store.photos.isEmpty
            ) {
                store.exportSelection()
            }
            .help("Copy selected photos to a folder of your choice (no re-encoding)")

            // Write Stars — with the dirty-count badge inline as a count.
            ToolbarAction(
                label: store.hasUnsavedRatings
                    ? "Write Stars (\(store.dirtyPhotoIDs.count))"
                    : "Write Stars",
                hotkey: "⌘S",
                disabled: store.photos.isEmpty,
                accent: store.hasUnsavedRatings
            ) {
                NSLog("RawDeck: Write Stars button clicked; dirty=\(store.dirtyPhotoIDs.count)")
                store.writeRatingsToMetadata { written, failed, firstError in
                    NSLog("RawDeck: Write Stars completion: written=\(written) failed=\(failed) err=\(firstError ?? "none")")
                    var lines: [String] = []
                    let plural = (written + failed) == 1 ? "" : "s"
                    lines.append("Saved \(written) of \(written + failed) rating\(plural) as XMP sidecars.")
                    if failed > 0 {
                        lines.append("\(failed) failed.")
                        if let err = firstError {
                            lines.append("First error: \(err)")
                        }
                    }
                    if written > 0 && failed == 0 {
                        lines.append("\nYour ratings are safe — you can quit the app, eject the card, or keep working.")
                    }
                    NSLog("RawDeck: setting alertMessage to: \(lines.joined(separator: " | "))")
                    store.alertMessage = lines.joined(separator: "\n")
                    NSLog("RawDeck: alertMessage set; current value=\(store.alertMessage ?? "nil")")
                }
            }
            .help(store.hasUnsavedRatings
                  ? "Save your current star ratings and reject flags to .xmp sidecars"
                  : "All current ratings are already saved to .xmp sidecars")

            // Trash
            ToolbarAction(
                label: "Trash",
                hotkey: "⌫",
                disabled: store.photos.isEmpty,
                destructive: true
            ) {
                _ = store.trashSelection()
            }
            .help("Move selected photos (or all rejected photos) to the Trash")
        }
        .frame(height: 32)
        .padding(.horizontal, RDSpace.l)
        .background(RDColor.surfaceRaised)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RDColor.hairline)
                .frame(height: 0.5)
        }
    }
}

// MARK: - Toolbar action button

/// A single toolbar action. Renders as a `Button` with a text label and
/// optional hotkey hint. No background fill — actions are text, not pills.
private struct ToolbarAction: View {
    let label: String
    var hotkey: String? = nil
    var disabled: Bool = false
    var destructive: Bool = false
    var accent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(RDType.body)
                    .foregroundStyle(textColor)
                if let hk = hotkey {
                    Text(hk)
                        .font(RDType.microMono)
                        .foregroundStyle(RDColor.textTertiary)
                }
            }
            .padding(.horizontal, RDSpace.s)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private var textColor: Color {
        if destructive { return RDColor.destructive }
        if accent { return RDColor.accentPrimary }
        return RDColor.textPrimary
    }
}

// MARK: - Vertical divider

private struct VDivider: View {
    var body: some View {
        Rectangle()
            .fill(RDColor.hairlineStrong)
            .frame(width: 1, height: 16)
            .padding(.horizontal, RDSpace.s)
    }
}