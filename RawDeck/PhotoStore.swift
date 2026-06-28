import Foundation
import AppKit
import Combine

/// The central state store for the current import session.
///
/// Holds the array of Photo objects, the current selection set, the
/// current folder URL, and the loading-progress counter. All views
/// observe this object via @EnvironmentObject.
@MainActor
final class PhotoStore: ObservableObject {

    @Published var photos: [Photo] = []
    @Published var currentFolder: URL? = nil
    @Published var selectedIDs: Set<UUID> = []
    @Published var isLoading: Bool = false
    @Published var loadingProgress: (done: Int, total: Int) = (0, 0)
    @Published var lastError: String? = nil

    /// When non-nil, the lightbox is open and showing this photo.
    /// The id is used (not the Photo directly) so views can resolve the
    /// live Photo instance from `photos` — preserving @ObservedObject updates.
    @Published var lightboxPhotoID: UUID? = nil

    /// Currently-hovered photo id. The spacebar opens the lightbox on this
    /// photo (per Fin B's spec: "press spacebar when hovering over an image").
    @Published var hoveredPhotoID: UUID? = nil

    /// Currently-running import task. Cancelled when a new import starts
    /// so we never have two scans racing to write to `photos`.
    private var importTask: Task<Void, Never>? = nil

    /// Photos whose thumbnail is currently being generated. Prevents the
    /// "thundering herd" of N cells all kicking off the same decode.
    private var thumbnailInFlight: Set<UUID> = []

    /// Photos whose 1600px preview is currently being generated. Same
    /// dedupe pattern as `thumbnailInFlight` for the lightbox.
    private var previewInFlight: Set<UUID> = []

    /// Convenience: the currently-selected Photo objects in display order.
    var selectedPhotos: [Photo] {
        photos.filter { selectedIDs.contains($0.id) }
    }

    /// Convenience: the photo currently shown in the lightbox, if any.
    /// Resolves the id against `photos` so the live @ObservedObject is
    /// returned (not a stale copy).
    var lightboxPhoto: Photo? {
        guard let id = lightboxPhotoID else { return nil }
        return photos.first { $0.id == id }
    }

    /// Convenience: count of photos at each star rating (for the status bar).
    func count(rating: Int) -> Int {
        photos.filter { $0.starRating == rating }.count
    }

    /// Convenience: count of rejected photos.
    var rejectedCount: Int { photos.filter { $0.isRejected }.count }

    // MARK: - Import

    /// Import a folder of RAWs. Replaces the current session.
    /// If a previous import is in progress it is cancelled.
    func importFolder(_ url: URL) {
        importTask?.cancel()
        currentFolder = url
        isLoading = true
        loadingProgress = (0, 0)
        lastError = nil
        photos = []
        selectedIDs = []
        // Always close the lightbox on a fresh import.
        lightboxPhotoID = nil
        hoveredPhotoID = nil

        // Capture only the URL (a value type) and the directory enumeration
        // happens on a detached task; we hop back to MainActor to publish.
        importTask = Task { [weak self] in
            let imported = await Task.detached(priority: .userInitiated) {
                ImportService.importFolder(at: url)
            }.value

            guard let self = self else { return }
            // If the user kicked off another import while we were running,
            // `importTask` now points at a newer task and we should bail.
            guard !Task.isCancelled else { return }
            self.photos = imported
            self.loadingProgress = (0, imported.count)
            self.isLoading = false
        }
    }

    // MARK: - Thumbnails

    /// Lazy-load thumbnails for visible cells. Dedupes via `thumbnailInFlight`
    /// so the same photo is never decoded more than once concurrently.
    func loadThumbnails(in range: Range<Int>) {
        guard !isLoading else { return }
        let toLoad = photos[range].filter { $0.thumbnail == nil && !thumbnailInFlight.contains($0.id) }
        guard !toLoad.isEmpty else { return }

        // Mark all of them in-flight up front so the next cell's
        // `.onAppear` sees them as already-loading and skips.
        for p in toLoad { thumbnailInFlight.insert(p.id) }

        Task { [weak self] in
            for photo in toLoad {
                if Task.isCancelled { break }
                let url = photo.url
                let thumb = await Task.detached(priority: .userInitiated) {
                    ThumbnailService.generateThumbnail(for: url)
                }.value
                guard let self = self, let thumb = thumb else {
                    await MainActor.run { [weak self] in
                        self?.thumbnailInFlight.remove(photo.id)
                    }
                    continue
                }
                photo.thumbnail = thumb
                self.thumbnailInFlight.remove(photo.id)
            }
        }
    }

    // MARK: - Previews (for the lightbox)

    /// Lazy-load a 1600px preview for a single photo. Dedupes via
    /// `previewInFlight`. Called when the lightbox opens on a photo and
    /// when navigating to neighbours so the next arrow-press is instant.
    func loadPreview(for photo: Photo) {
        guard photo.preview == nil, !previewInFlight.contains(photo.id) else { return }
        previewInFlight.insert(photo.id)
        let id = photo.id
        let url = photo.url
        Task { [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                ThumbnailService.generatePreview(for: url)
            }.value
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.previewInFlight.remove(id)
                if let preview = preview,
                   let p = self.photos.first(where: { $0.id == id }) {
                    p.preview = preview
                }
            }
        }
    }

    // MARK: - Selection

    func select(_ id: UUID, additive: Bool = false) {
        if additive {
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
        } else {
            selectedIDs = [id]
        }
    }

    func selectAll() {
        selectedIDs = Set(photos.map { $0.id })
    }

    func deselectAll() {
        selectedIDs = []
    }

    // MARK: - Ratings (apply to selection, or to a single photo if none selected)

    func setRating(_ rating: Int, photo: Photo? = nil) {
        let targets: [Photo] = {
            if let p = photo { return [p] }
            let sel = selectedPhotos
            return sel.isEmpty ? [] : sel
        }()
        for p in targets { p.starRating = rating }
    }

    func toggleReject(photo: Photo? = nil) {
        let targets: [Photo] = {
            if let p = photo { return [p] }
            let sel = selectedPhotos
            return sel.isEmpty ? [] : sel
        }()
        for p in targets { p.isRejected.toggle() }
    }

    // MARK: - Lightbox

    /// Open the lightbox on the given photo. Also selects it so the existing
    /// rating/reject shortcuts (`1`-`5`, `0`, `X`) target the photo being viewed.
    /// Pre-loads the current photo + immediate neighbours for smooth arrow nav.
    func openLightbox(on photo: Photo) {
        lightboxPhotoID = photo.id
        selectedIDs = [photo.id]
        loadPreview(for: photo)
        // Pre-warm the next and previous so arrow presses are instant.
        if let idx = photos.firstIndex(where: { $0.id == photo.id }) {
            if idx > 0 { loadPreview(for: photos[idx - 1]) }
            if idx + 1 < photos.count { loadPreview(for: photos[idx + 1]) }
        }
    }

    /// Close the lightbox. Selection is preserved so the user can keep
    /// working with the last-viewed photo (or any selection they had).
    func closeLightbox() {
        lightboxPhotoID = nil
    }

    /// Navigate to the next (or previous, with negative step) photo in the
    /// grid. No-op at the edges — the user must press Esc to leave the lightbox.
    /// Auto-advances the selection and pre-warms the new neighbour.
    func lightboxStep(_ step: Int) {
        guard let current = lightboxPhoto,
              let idx = photos.firstIndex(where: { $0.id == current.id }) else { return }
        let next = idx + step
        guard next >= 0, next < photos.count else { return }
        let target = photos[next]
        lightboxPhotoID = target.id
        selectedIDs = [target.id]
        loadPreview(for: target)
        // Pre-warm the new neighbour on the side we're moving into.
        let neighbour = next + step
        if neighbour >= 0, neighbour < photos.count {
            loadPreview(for: photos[neighbour])
        }
    }

    /// The photo being viewed in the lightbox, or the first selected photo,
    /// or nil. Used as the implicit target for the number-key shortcuts so
    /// "1-5 correlate with stars" works in both grid and lightbox modes.
    var ratingTarget: Photo? {
        if let p = lightboxPhoto { return p }
        let sel = selectedPhotos
        if sel.count == 1 { return sel[0] }
        return nil
    }

    // MARK: - Delete

    /// Move selected photos (or all rejects if no selection) to the Trash.
    /// Returns the number of files actually trashed.
    ///
    /// The actual `FileManager.trashItem` calls run on a background task so
    /// the main thread is not blocked when trashing a large selection.
    @discardableResult
    func trashSelection() -> Int {
        // Lightbox mode: trash the currently-viewed photo, even if the
        // grid selection is empty. After removal, advance to a neighbour
        // (next photo in the list, or previous if at the end) so the
        // user can keep culling without an extra Esc/click. If the grid
        // is now empty, close the lightbox.
        if lightboxPhotoID != nil, let p = lightboxPhoto {
            let trashedID = p.id
            // Capture the position BEFORE removal so we know which way to advance.
            let priorIdx = photos.firstIndex(where: { $0.id == trashedID })
            photos.removeAll { $0.id == trashedID }
            selectedIDs = []

            // Advance the lightbox to a neighbour, or close if none left.
            if photos.isEmpty {
                lightboxPhotoID = nil
            } else {
                // Prefer the photo at the same index (now the "next" one);
                // fall back to the new last photo if we trashed the tail.
                let targetIdx = min(priorIdx ?? 0, photos.count - 1)
                let next = photos[targetIdx]
                lightboxPhotoID = next.id
                selectedIDs = [next.id]
                loadPreview(for: next)
            }

            let url = p.url
            Task { [weak self] in
                _ = await ExternalAppService.moveToTrash(url)
                _ = self
            }
            return 1
        }

        let toTrash: [Photo] = {
            let sel = selectedPhotos
            if !sel.isEmpty { return sel }
            // If no selection, trash all rejects
            return photos.filter { $0.isRejected }
        }()
        guard !toTrash.isEmpty else { return 0 }

        let ids = Set(toTrash.map { $0.id })
        let urls = toTrash.map { $0.url }

        // Optimistically remove from the in-memory list (the trash op is
        // reversible via Finder's Trash, but we don't want the UI to keep
        // showing files we just told the system to remove).
        photos.removeAll { ids.contains($0.id) }
        selectedIDs = selectedIDs.intersection(Set(photos.map { $0.id }))

        Task { [weak self] in
            var trashed = 0
            for url in urls {
                if await ExternalAppService.moveToTrash(url) {
                    trashed += 1
                }
            }
            // No state to publish; the in-memory list is already correct.
            _ = trashed
            _ = self
        }
        return toTrash.count
    }

    // MARK: - External app

    /// Open selected photos (or a single photo) in Pixelmator Pro.
    func openSelectionInPixelmator(photo: Photo? = nil) {
        let targets: [Photo] = {
            if let p = photo { return [p] }
            let sel = selectedPhotos
            return sel.isEmpty ? photos : sel
        }()
        for p in targets {
            ExternalAppService.openInPixelmator(p.url)
        }
    }

    /// Reveal selected photos in Finder.
    func revealSelectionInFinder() {
        let targets = selectedPhotos.isEmpty ? photos : selectedPhotos
        for p in targets {
            ExternalAppService.revealInFinder(p.url)
        }
    }
}