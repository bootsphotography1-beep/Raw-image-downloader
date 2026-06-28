import SwiftUI
import AppKit

/// Full-screen photo viewer. Covers the main grid when open.
///
/// Layout:
/// - Top: filename + close hint
/// - Center: the current photo at fit-aspect, as large as the window allows
/// - Bottom: a horizontal scroll strip of every photo's thumbnail, with the
///   currently-viewed photo highlighted. Clicking a strip thumbnail jumps
///   the main view to that photo.
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
            // Wrap the header in an @ObservedObject subview so changes to
            // `photo.starRating` / `photo.isRejected` propagate (the parent
            // only observes `store`, not `photo`).
            LightboxContents(photo: photo)
        }
    }
}

/// The full lightbox UI, scoped to a single observed `Photo` instance.
/// Re-renders whenever the photo's @Published fields change.
struct LightboxContents: View {
    @EnvironmentObject var store: PhotoStore
    @ObservedObject var photo: Photo

    var body: some View {
        ZStack {
            // Solid black backdrop so the photo pops.
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                photoStage
                Spacer(minLength: 0)
                thumbnailStrip
            }
        }
        .contentShape(Rectangle())
        // Double-click on the stage opens in Pixelmator (matches the
        // grid's double-click behaviour). Attached FIRST so it has
        // priority over the single-tap-to-close.
        .onTapGesture(count: 2) {
            store.openSelectionInPixelmator(photo: photo)
        }
        // Capture single clicks on the backdrop so they don't fall
        // through to the grid behind us. (Placed after count:2 so a
        // double-click is not also treated as a single-click close.)
        .onTapGesture {
            store.closeLightbox()
        }
        .transition(.opacity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Filename + position counter
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.fileName)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let idx = store.photos.firstIndex(where: { $0.id == photo.id }) {
                    Text("Photo \(idx + 1) of \(store.photos.count)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            Spacer()
            // Star row for the current photo (read-only-ish; press 1-5 to change)
            StarRow(rating: photo.starRating, isRejected: photo.isRejected)
                .font(.title3)
            // Close button
            Button {
                store.closeLightbox()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Close lightbox (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.4))
    }

    // MARK: - Photo stage

    private var photoStage: some View {
        ZStack {
            if let preview = photo.preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Preview still decoding — show the thumbnail while waiting.
                if let thumb = photo.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(0.6)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Loading preview…")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }

            // Rejected X badge (top-left of the stage) — matches the grid cell.
            if photo.isRejected {
                VStack {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .font(.largeTitle)
                            .padding(12)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom thumbnail strip

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(store.photos.enumerated()), id: \.element.id) { idx, p in
                        LightboxStripCell(
                            photo: p,
                            index: idx,
                            isCurrent: p.id == photo.id
                        )
                        .id(p.id)
                        .onTapGesture {
                            // Jump directly to this photo.
                            store.openLightbox(on: p)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 96)
            .background(Color.black.opacity(0.6))
            .onChange(of: photo.id) { newID in
                // Auto-scroll the strip so the current cell is always visible.
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }
}

/// One cell in the lightbox's bottom strip. Smaller than the grid cell;
/// shows the thumbnail with a yellow border when current and a star/reject
/// overlay. Tapping jumps the main view to that photo.
struct LightboxStripCell: View {
    @ObservedObject var photo: Photo
    let index: Int
    let isCurrent: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Rectangle()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.3))
                if let thumb = photo.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Reject badge
            if photo.isRejected {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .font(.caption)
                    .padding(2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isCurrent ? Color.yellow : Color.white.opacity(0.2),
                    lineWidth: isCurrent ? 3 : 1
                )
        )
        .overlay(alignment: .bottom) {
            // Star rating in tiny form
            if photo.starRating > 0 {
                HStack(spacing: 1) {
                    ForEach(1...photo.starRating, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundColor(.yellow)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .help("\(photo.fileName) (Photo \(index + 1))")
    }
}