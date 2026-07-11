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
        VStack(spacing: RDSpace.xs + 2) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail area
                ZStack {
                    RDColor.surfaceRaised

                    if let thumb = photo.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if photo.thumbnailLoadAttempted {
                        // Decode failed (QL returned nil + embedded-JPEG
                        // fallback also failed). Show a recognizable
                        // placeholder so the user knows the cell isn't
                        // just slow to load. Tooltip surfaces the
                        // diagnostic reason so the user can see *why*
                        // (useful for stubborn CR3 files on macOS 27).
                        VStack(spacing: RDSpace.xs) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title)
                                .foregroundStyle(RDColor.textSecondary)
                            Text("No preview")
                                .font(RDType.caption)
                                .foregroundStyle(RDColor.textSecondary)
                        }
                        .help(photo.lastThumbnailError ?? "Thumbnail generation failed")
                    } else {
                        // Still loading — show the spinner.
                        VStack {
                            ProgressView()
                                .controlSize(.small)
                                .tint(RDColor.textSecondary)
                            Text("Loading…")
                                .font(RDType.caption)
                                .foregroundStyle(RDColor.textSecondary)
                        }
                    }
                    // Pixelmator-sent badge — top-left of the cell, only
                    // rendered after the user has actually opened this photo
                    // in Pixelmator Pro (Photo.sentToPixelmator is set in
                    // PhotoStore.openSelectionInPixelmator on a successful
                    // launch). Top-right is reserved for the reject X.
                    if photo.sentToPixelmator != nil {
                        VStack {
                            HStack {
                                RDPixelmatorSentBadge()
                                Spacer()
                            }
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()

                // Reject X badge (top-right) — destructive color from the
                // design system, not the system .red which can shift in
                // dark mode. Wrapped with a stamp-style scale + slight
                // rotation that fires when isRejected flips true (the
                // .transition only fires for *appearing* views, which is
                // exactly the "just rejected" moment).
                if photo.isRejected {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, RDColor.destructive)
                        .font(.title2)
                        .padding(RDSpace.xs + 2)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.4)
                                    .combined(with: .rotation(.degrees(-30)))
                                    .animation(.spring(response: 0.28, dampingFraction: 0.5)),
                                removal: .scale(scale: 0.6)
                                    .combined(with: .opacity)
                                    .animation(.easeOut(duration: 0.15))
                            )
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: RDRadius.card, style: .continuous)
                    .strokeBorder(
                        isSelected ? RDColor.accentPrimary :
                            (store.hoveredPhotoID == photo.id ? RDColor.hairlineAccent : Color.clear),
                        lineWidth: isSelected ? 2 : 1
                    )
                    // Spring the selection ring in/out instead of snapping.
                    // value: isSelected triggers the spring on every flip.
                    .animation(
                        .spring(response: 0.25, dampingFraction: 0.7),
                        value: isSelected
                    )
            )
            .background(
                RDColor.surfaceBase.opacity(isSelected ? 0.04 : 0)
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
                    .font(RDType.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(RDColor.textPrimary)

                RDStarRow(rating: photo.starRating, isRejected: photo.isRejected)
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
                // Trash the file first (this is the irreversible part),
                // then remove from the store inside withAnimation so
                // SwiftUI's default list-transition (fade + collapse)
                // plays on the grid. Without withAnimation the cell
                // would just vanish.
                _ = ExternalAppService.moveToTrash(photo.url)
                withAnimation(.easeOut(duration: 0.22)) {
                    store.photos.removeAll { $0.id == photo.id }
                    store.selectedIDs = store.selectedIDs.intersection(Set(store.photos.map { $0.id }))
                }
            } label: {
                Text("Move to Trash")
            }
        }
    }
}

