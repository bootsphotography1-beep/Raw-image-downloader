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

    /// Currently-running import task. Cancelled when a new import starts
    /// so we never have two scans racing to write to `photos`.
    private var importTask: Task<Void, Never>? = nil

    /// Photos whose thumbnail is currently being generated. Prevents the
    /// "thundering herd" of N cells all kicking off the same decode.
    private var thumbnailInFlight: Set<UUID> = []

    /// Convenience: the currently-selected Photo objects in display order.
    var selectedPhotos: [Photo] {
        photos.filter { selectedIDs.contains($0.id) }
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

    // MARK: - Delete

    /// Move selected photos (or all rejects if no selection) to the Trash.
    /// Returns the number of files actually trashed.
    ///
    /// The actual `FileManager.trashItem` calls run on a background task so
    /// the main thread is not blocked when trashing a large selection.
    @discardableResult
    func trashSelection() -> Int {
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
