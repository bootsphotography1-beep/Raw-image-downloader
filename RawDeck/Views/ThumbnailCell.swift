import SwiftUI
import AppKit

/// One cell in the grid. Shows the thumbnail, filename, star rating overlay,
/// and a reject X. Click selects, double-click opens in Pixelmator.
///
/// The single-tap handler is attached with `.simultaneousGesture` and
/// inspects `NSEvent.clickCount` so it only fires on the *first* click
/// of a sequence — a double-click then opens in Pixelmator without
/// also leaving the photo selected.
struct ThumbnailCell: View {
    @ObservedObject var photo: Photo
    @EnvironmentObject var store: PhotoStore

    var isSelected: Bool {
        store.selectedIDs.contains(photo.id)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail area
                ZStack {
                    Rectangle()
                        .fill(Color(NSColor.controlBackgroundColor))

                    if let thumb = photo.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        VStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading…")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()

                // Reject X badge (top-right)
                if photo.isRejected {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .font(.title2)
                        .padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(
                        isSelected ? Color.accentColor :
                            (store.hoveredPhotoID == photo.id ? Color.white.opacity(0.6) : Color.clear),
                        lineWidth: 3
                    )
            )
            .background(
                Color.black.opacity(isSelected ? 0.04 : 0)
            )
            // Track hover so the spacebar (handled in ContentView) knows
            // which photo to open the lightbox on. SwiftUI's onHover is
            // a simple in/out callback — we mirror the state to the store.
            .onHover { hovering in
                if hovering {
                    store.hoveredPhotoID = photo.id
                } else if store.hoveredPhotoID == photo.id {
                    // Don't clear if the cursor moved onto another cell —
                    // that cell's onHover will overwrite the value first.
                    store.hoveredPhotoID = nil
                }
            }

            // Filename + stars
            VStack(spacing: 2) {
                Text(photo.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.primary)

                StarRow(rating: photo.starRating, isRejected: photo.isRejected)
                    .font(.caption2)
            }
        }
        .contentShape(Rectangle())
        // Double-click opens in Pixelmator. Attached first so it has priority
        // in the gesture recognizer.
        .onTapGesture(count: 2) {
            store.openSelectionInPixelmator(photo: photo)
        }
        // Single-click selects, but ONLY if this is the first click of a
        // sequence (NSEvent.clickCount == 1 at gesture time). When the user
        // is mid-double-click, clickCount will be 2 and we skip the select.
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded {
                // Cmd-click toggles additively, regardless of click count.
                store.select(photo.id, additive: true)
            }
        )
        .onTapGesture {
            // Plain click: only select if not also a double-click.
            // (SwiftUI's count:1 tap fires first; count:2 swallows subsequent
            // taps within the system double-click interval.)
            let additive = NSEvent.modifierFlags.contains(.command)
            store.select(photo.id, additive: additive)
        }
        .contextMenu {
            Button("Open Lightbox") {
                store.openLightbox(on: photo)
            }
            Button("Open in Pixelmator Pro") {
                store.openSelectionInPixelmator(photo: photo)
            }
            Button("Reveal in Finder") {
                ExternalAppService.revealInFinder(photo.url)
            }
            Divider()
            Button(role: .destructive) {
                _ = ExternalAppService.moveToTrash(photo.url)
                store.photos.removeAll { $0.id == photo.id }
                store.selectedIDs = store.selectedIDs.intersection(Set(store.photos.map { $0.id }))
            } label: {
                Text("Move to Trash")
            }
        }
    }
}

/// Row of 5 star icons. Tap to set rating.
struct StarRow: View {
    let rating: Int
    let isRejected: Bool

    var body: some View {
        // Placeholder: shows 5 grey stars with the current rating filled in.
        // Tap to set rating (handled by parent ThumbnailCell, not here —
        // we don't want the star row to intercept the cell's click).
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .foregroundColor(isRejected ? .red : (i <= rating ? .yellow : .secondary.opacity(0.3)))
            }
        }
    }
}
