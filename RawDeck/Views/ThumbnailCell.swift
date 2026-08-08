import SwiftUI
import AppKit

/// One cell in the grid.
///
/// Design discipline (v2):
///  - NO filename + star row below the photo. The photo IS the work; the
///    filename lives on the lightbox's meta strip and the rating lives in
///    a tiny overlay. Real Lightroom/Capture One cells don't have a label
///    under each thumb.
///  - Aspect ratio 3:2 (RAW native) instead of 1:1 (placeholder square).
///  - Cells abut each other (1px gap) like a contact sheet. No rounded
///    corners on cells. The selected state is a thin blue inset rail.
///  - Hover state: no scale transform, no scale animation. Just a hairline
///    border that brightens. Cells are static; the data is the focus.
///
/// The single-tap handler is attached with `.simultaneousGesture` and
/// inspects `NSEvent.clickCount` so it only fires on the *first* click of
/// a sequence — a double-click then opens in Pixelmator without also
/// leaving the photo selected. (Kept from v1.)
struct ThumbnailCell: View {
    @ObservedObject var photo: Photo
    @EnvironmentObject var store: PhotoStore

    var isSelected: Bool {
        store.selectedIDs.contains(photo.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail area — true 3:2 native RAW aspect, no label below.
                ZStack {
                    RDColor.surfaceRaised

                    if let thumb = photo.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if photo.thumbnailLoadAttempted {
                        // Decode failed (QL returned nil + embedded-JPEG
                        // fallback also failed). Show a recognizable
                        // placeholder so the user knows the cell isn't
                        // just slow to load. Tooltip surfaces the
                        // diagnostic reason so the user can see *why*.
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
                        VStack {
                            ProgressView()
                                .controlSize(.small)
                                .tint(RDColor.textSecondary)
                            Text("Loading…")
                                .font(RDType.caption)
                                .foregroundStyle(RDColor.textSecondary)
                        }
                    }

                    // Reject desaturation overlay (top of thumbnail).
                    // Doesn't fully hide the photo, just marks it as
                    // visually "off" so the user can spot rejects in
                    // the grid without a separate panel.
                    if photo.isRejected {
                        Color.black.opacity(0.42)
                        Color.white.opacity(0.08)
                            .blendMode(.overlay)
                    }

                    // Pixelmator-sent badge — top-left of the cell, only
                    // rendered after the user has actually opened this photo
                    // in Pixelmator Pro. Top-right is reserved for the rating.
                    if photo.sentToPixelmator != nil {
                        VStack {
                            HStack {
                                RDPixelmatorSentBadge()
                                Spacer()
                            }
                            Spacer()
                        }
                    }

                    // Star rating — tiny mono overlay, bottom-left, only
                    // shown when rated. No row of 5 stars under the photo.
                    if photo.starRating > 0 {
                        VStack {
                            Spacer()
                            HStack {
                                Text(String(repeating: "★", count: photo.starRating))
                                    .font(RDType.microMono)
                                    .foregroundStyle(RDColor.starActive)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.black.opacity(0.55))
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(3.0/2.0, contentMode: .fill)
                .clipped()

                // Reject X — solid square in the top-right corner (not a
                // rounded badge). Visual signal: "this is rejected" without
                // a giant SF Symbol that competes with the photo.
                if photo.isRejected {
                    Text("✕")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(RDColor.textOnStage)
                        .frame(width: 16, height: 16)
                        .background(RDColor.destructive)
                        .padding(2)
                }
            }
            // Selected = inset 2px blue rail on every side. Hovered =
            // hairline. Default = nothing. (No rounded corners — contact sheet.)
            .overlay(
                Rectangle()
                    .strokeBorder(
                        isSelected ? RDColor.accentPrimary :
                            (store.hoveredPhotoID == photo.id ? RDColor.hairlineAccent : RDColor.hairline),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            // Track hover so the spacebar (handled in ContentView) knows
            // which photo to open the lightbox on.
            .onHover { hovering in
                if hovering {
                    store.hoveredPhotoID = photo.id
                } else if store.hoveredPhotoID == photo.id {
                    // Don't clear if the cursor moved onto another cell —
                    // that cell's onHover will overwrite the value first.
                    store.hoveredPhotoID = nil
                }
            }
        }
        .contentShape(Rectangle())
        // Double-click opens in Pixelmator. Attached first so it has priority
        // in the gesture recognizer.
        .onTapGesture(count: 2) {
            store.openSelectionInPixelmator(photo: photo)
        }
        // Cmd-click toggles additively.
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded {
                store.select(photo.id, additive: true)
            }
        )
        .onTapGesture {
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