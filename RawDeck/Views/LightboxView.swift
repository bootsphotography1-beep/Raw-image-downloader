import SwiftUI
import AppKit

/// Full-screen photo viewer. Covers the main grid when open.
///
/// Design discipline (v2):
///  - Header & thumbnail strip use plain rgba(0,0,0,0.55) strips, no
///    backdrop-filter blur (that's the LLM glassmorphism tell). The web
///    design also strips it.
///  - Rating HUD is text buttons (1-5) over the stage, not a star-row
///    component. The Reject action is a text button labelled "REJECT".
///  - 3:2 native RAW aspect, true black stage, no rounded corners on
///    the strip cell.
///  - All store APIs unchanged.
///
/// Keyboard (handled in ContentView via HiddenKeyButton):
/// - `Esc` / `Space` (no photo hovered): close
/// - `←` / `→`: previous / next
/// - `1`-`5`: rate current
/// - `0`: clear rating
/// - `X`: toggle reject
/// - `Delete`: trash current
/// - `⌘⇧O`: open current in Pixelmator
struct LightboxView: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        if let photo = store.lightboxPhoto {
            LightboxContents(photo: photo)
        }
    }
}

struct LightboxContents: View {
    @EnvironmentObject var store: PhotoStore
    @ObservedObject var photo: Photo

    var body: some View {
        ZStack {
            // Solid black backdrop so the photo pops.
            // The stage is intentionally true black — the deepest possible
            // void against which the sensor pixels are seen. This is the
            // one surface in the app where pure black is correct.
            RDColor.stageBlack.ignoresSafeArea()

            VStack(spacing: 0) {
                photoStage
                Spacer(minLength: 0)
                thumbnailStrip
            }
        }
        .contentShape(Rectangle())
        // Double-click on the stage opens in Pixelmator.
        .onTapGesture(count: 2) {
            store.openSelectionInPixelmator(photo: photo)
        }
        // Capture single clicks on the backdrop so they don't fall
        // through to the grid behind us.
        .onTapGesture {
            store.closeLightbox()
        }
        .transition(.opacity)
    }

    // MARK: - Photo stage

    /// The full lightbox photo + meta HUD + rating/reject bar.
    private var photoStage: some View {
        ZStack {
            // The photo itself — fills the stage at native 3:2 aspect.
            photoImage

            // Meta strip — top-left, single line of mono, on a plain rgba strip.
            metaStrip
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(RDSpace.s)

            // Rating + reject HUD — bottom-left of stage, just above the strip.
            ratingHud
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, RDSpace.l)
                .padding(.bottom, RDSpace.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var photoImage: some View {
        if let preview = photo.preview {
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let thumb = photo.thumbnail {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.85)
        } else {
            VStack(spacing: RDSpace.s) {
                ProgressView()
                    .controlSize(.large)
                    .tint(RDColor.textOnStage)
                Text("Loading preview…")
                    .font(RDType.caption)
                    .foregroundStyle(RDColor.textOnStageDim)
            }
        }
    }

    /// Top-left mono meta strip — filename, position counter, image dimensions.
    /// Plain rgba(0,0,0,0.55) background, no blur.
    private var metaStrip: some View {
        HStack(spacing: RDSpace.s) {
            Text(photo.fileName)
                .font(RDType.captionMonoEmph)
                .foregroundStyle(RDColor.textOnStage)
                .lineLimit(1)
                .truncationMode(.middle)
            if let idx = store.photos.firstIndex(where: { $0.id == photo.id }) {
                Text("·")
                    .foregroundStyle(RDColor.textOnStageDim)
                Text("Photo \(idx + 1) of \(store.photos.count)")
                    .font(RDType.microMono)
                    .foregroundStyle(RDColor.textOnStageDim)
            }
            // Image dimensions derived from whichever Image we have.
            // NSImage.size is reliable post-decode; falls back to nothing
            // when neither thumbnail nor preview has decoded yet.
            if let dims = currentDimensions() {
                Text("·")
                    .foregroundStyle(RDColor.textOnStageDim)
                Text(dims)
                    .font(RDType.microMono)
                    .foregroundStyle(RDColor.textOnStageDim)
            }
        }
        .padding(.horizontal, RDSpace.s)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            // Close button at the right edge of the meta strip row.
            Button {
                store.closeLightbox()
            } label: {
                Text("×")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RDColor.textOnStage)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Close lightbox (Esc)")
            .padding(.trailing, RDSpace.s)
        }
    }

    /// Get the current photo dimensions as a string. Uses the preview if
    /// loaded (matches the lightbox's actual displayed image); falls back
    /// to the thumbnail's intrinsic size; returns nil if neither is loaded.
    private func currentDimensions() -> String? {
        let img = photo.preview ?? photo.thumbnail
        guard let img, img.size.width > 0, img.size.height > 0 else { return nil }
        return "\(Int(img.size.width))×\(Int(img.size.height))"
    }

    /// Rating + reject HUD — text buttons on a plain rgba strip.
    /// 1-5 are rate keys, · is a separator, REJECT is the toggle.
    private var ratingHud: some View {
        HStack(spacing: RDSpace.s) {
            ForEach(1...5, id: \.self) { n in
                Button {
                    store.setRating(photo.starRating == n ? 0 : n, photo: photo)
                } label: {
                    Text("\(n)")
                        .font(RDType.microMono)
                        .foregroundStyle(photo.starRating >= n
                                         ? RDColor.starActive
                                         : Color.white.opacity(0.30))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .help("Set rating to \(n) (or clear if already \(n))")
            }
            Text("·")
                .font(RDType.microMono)
                .foregroundStyle(Color.white.opacity(0.30))
                .padding(.horizontal, 2)
            Button {
                store.toggleReject(photo: photo)
            } label: {
                HStack(spacing: 3) {
                    Text("REJECT")
                        .font(RDType.microMono)
                        .tracking(0.4)
                        .foregroundStyle(photo.isRejected
                                         ? RDColor.textOnStage
                                         : Color.white.opacity(0.55))
                    if photo.isRejected {
                        Text("✓")
                            .font(RDType.microMono)
                            .foregroundStyle(RDColor.textOnStage)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(photo.isRejected
                            ? RDColor.destructive
                            : Color.clear)
            }
            .buttonStyle(.plain)
            .help("Toggle reject (X)")
        }
        .padding(.horizontal, RDSpace.s)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
    }

    // MARK: - Bottom thumbnail strip

    /// Bottom strip of thumbnails. Plain rgba strip, no blur, no rounded
    /// corners. Active cell shows a thin blue outline.
    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(store.photos.enumerated()), id: \.element.id) { idx, p in
                        LightboxStripCell(
                            photo: p,
                            index: idx,
                            isCurrent: p.id == photo.id
                        )
                        .id(p.id)
                        .onTapGesture {
                            store.openLightbox(on: p)
                        }
                    }
                }
                .padding(.horizontal, RDSpace.s)
                .padding(.vertical, RDSpace.s)
            }
            .frame(height: 64)
            .background(RDColor.surfaceBase)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(RDColor.hairlineStrong)
                    .frame(height: 0.5)
            }
            .onChange(of: photo.id) { newID in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }
}

/// One cell in the lightbox's bottom strip. Smaller than the grid cell;
/// shows the thumbnail with a thin blue outline when current and a tiny
/// star rating overlay in the bottom-left when rated.
struct LightboxStripCell: View {
    @ObservedObject var photo: Photo
    let index: Int
    let isCurrent: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RDColor.surfaceRaised.opacity(0.3)
                if let thumb = photo.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(RDColor.textOnStage)
                }
            }
            .frame(width: 96, height: 48)

            // Pixelmator-sent badge (top-left)
            if photo.sentToPixelmator != nil {
                VStack {
                    HStack {
                        RDPixelmatorSentBadge(size: 12)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(2)
            }

            // Reject badge (top-right) — small destructive square.
            if photo.isRejected {
                Text("✕")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RDColor.textOnStage)
                    .frame(width: 14, height: 14)
                    .background(RDColor.destructive)
                    .padding(2)
            }
        }
        // Active = thin blue outline; idle = hairline. No rounded corners.
        .overlay(
            Rectangle()
                .strokeBorder(
                    isCurrent ? RDColor.accentPrimary : RDColor.hairline,
                    lineWidth: isCurrent ? 1 : 1
                )
        )
        .opacity(isCurrent ? 1.0 : 0.7)
        // Saturation drop on idle cells to draw eye to the active one.
        .saturation(isCurrent ? 1.0 : 0.7)
        // Star rating overlay (bottom-left, only when rated)
        .overlay(alignment: .bottomLeading) {
            if photo.starRating > 0 {
                Text(String(repeating: "★", count: photo.starRating))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RDColor.starActive)
                    .textShadow(.init(color: .black.opacity(0.8), radius: 1, x: 0, y: 0))
                    .padding(.bottom, 2)
                    .padding(.leading, 3)
            }
        }
        .help("\(photo.fileName) (Photo \(index + 1))")
    }
}