import SwiftUI
import AppKit

/// Top toolbar: back-to-drop-zone button, folder name, "Open in Pixelmator Pro"
/// action, "Reveal in Finder" action, "Move to Trash" action. Plus the
/// star-count badges (how many photos at each rating).
struct ToolbarView: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        HStack(spacing: 12) {
            // Back to drop zone
            Button {
                store.photos = []
                store.selectedIDs = []
                store.currentFolder = nil
            } label: {
                Label("New Import", systemImage: "chevron.left")
            }
            .help("Close current session and import a different folder")

            Divider().frame(height: 20)

            // Folder name
            if let folder = store.currentFolder {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.secondary)
                    Text(folder.lastPathComponent)
                        .font(.headline)
                    Text("(\(store.photos.count) photos)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Star count badges
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { i in
                    let n = store.count(rating: i)
                    if n > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundColor(.yellow)
                            Text("\(n)")
                                .font(.caption)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.1))
                        )
                    }
                }
                if store.rejectedCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                        Text("\(store.rejectedCount)")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red.opacity(0.1))
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
            .help("Open selected photos (or all photos) in Pixelmator Pro")

            Button {
                store.revealSelectionInFinder()
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
            }
            .disabled(store.photos.isEmpty)
            .help("Reveal selected photos in Finder")

            Button(role: .destructive) {
                _ = store.trashSelection()
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .disabled(store.photos.isEmpty)
            .help("Move selected photos (or all rejected photos) to the Trash")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
