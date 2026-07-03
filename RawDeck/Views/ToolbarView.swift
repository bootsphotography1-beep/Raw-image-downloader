import SwiftUI
import AppKit

/// Top toolbar: back-to-drop-zone button, folder name + count, a Sort
/// menu (Lightroom-style: single dropdown button labelled with the
/// current sort), star-count badges, and the photo actions (Open in
/// Pixelmator / Reveal / Trash).
struct ToolbarView: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        HStack(spacing: RDSpace.m) {
            // Back to drop zone
            Button {
                store.photos = []
                store.selectedIDs = []
                store.currentFolder = nil
                store.resetFilters()
            } label: {
                Label("New Import", systemImage: "chevron.left")
            }
            .help("Close current session and import a different folder")

            Divider().frame(height: 20)

            // Folder name + photo count
            if let folder = store.currentFolder {
                HStack(spacing: RDSpace.xs) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(RDColor.textSecondary)
                    Text(folder.lastPathComponent)
                        .font(RDType.titleMedium)
                    Text("(\(store.photos.count) photos)")
                        .font(RDType.caption)
                        .foregroundStyle(RDColor.textSecondary)
                }
            }

            // Sort menu
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
                Label(store.sortMode.label, systemImage: store.sortMode.systemImage)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort the grid by filename or star rating")

            Spacer()

            // Star count badges
            HStack(spacing: RDSpace.s) {
                ForEach(1...5, id: \.self) { i in
                    let n = store.count(rating: i)
                    if n > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(RDColor.starActive)
                            Text("\(n)")
                                .font(RDType.caption)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, RDSpace.xs + 2)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: RDRadius.button, style: .continuous)
                                .fill(RDColor.surfaceElevated)
                        )
                    }
                }
                if store.rejectedCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(RDColor.destructive)
                        Text("\(store.rejectedCount)")
                            .font(RDType.caption)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, RDSpace.xs + 2)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: RDRadius.button, style: .continuous)
                            .fill(RDColor.destructiveDim)
                    )
                }
            }

            Divider().frame(height: 20)

            // Actions
            Button {
                store.openSelectionInPixelmator()
            } label: {
                Label("Open in Pixelmator", systemImage: "wand.and.stars")
            }
            .disabled(store.photos.isEmpty)
            .help("Open selected photos (or all visible photos) in Pixelmator Pro")

            Button {
                store.revealSelectionInFinder()
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
            }
            .disabled(store.photos.isEmpty)
            .help("Reveal selected photos in Finder")

            Button {
                store.exportSelection()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(store.photos.isEmpty)
            .help("Copy selected photos to a folder of your choice, preserving the original .cr3 / .nef / .arw / .dng bytes (no re-encoding)")

            Button {
                store.writeRatingsToMetadata { written, failed, firstError in
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
                    store.alertMessage = lines.joined(separator: "\n")
                }
            } label: {
                if store.hasUnsavedRatings {
                    Label("Write Stars (\(store.dirtyPhotoIDs.count))", systemImage: "square.and.arrow.down")
                } else {
                    Label("Write Stars", systemImage: "checkmark.circle")
                }
            }
            .disabled(store.photos.isEmpty)
            .help(store.hasUnsavedRatings
                  ? "Save your current star ratings and reject flags to .xmp sidecars (Lightroom/Photos/Photo Mechanic compatible). Original RAW bytes are not modified."
                  : "All current ratings are already saved to .xmp sidecars.")

            Button(role: .destructive) {
                _ = store.trashSelection()
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .disabled(store.photos.isEmpty)
            .help("Move selected photos (or all rejected photos) to the Trash")
        }
        .padding(.horizontal, RDSpace.l)
        .padding(.vertical, RDSpace.s + 2)
        .background(RDColor.surfaceRaised)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RDColor.hairline)
                .frame(height: 0.5)
        }
    }
}