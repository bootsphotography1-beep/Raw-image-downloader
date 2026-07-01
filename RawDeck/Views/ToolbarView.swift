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

            // Sort menu — single dropdown button labelled with the current
            // sort. Clicking opens a menu with the three sort options.
            // The currently-active one has a checkmark next to it.
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

            // Star count badges — show the TOTAL count of photos at each
            // rating (not filtered). Helps the user see at a glance how
            // many 5-stars they've rated in the whole session.
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
