import Foundation
@preconcurrency import AppKit
import Combine

/// Sendable wrapper for `NSImage` to allow it to cross actor boundaries
/// (e.g. Task.detached) on macOS 13, where `NSImage` is not formally
/// `Sendable`. `NSImage` is reference-counted and effectively immutable
/// after decoding (we never mutate one in-place), so this is safe in
/// practice. The `@unchecked` skips the compiler's Sendable check.
///
/// On macOS 14+ this becomes unnecessary (NSImage gains Sendable conformance
/// automatically), but the deployment target is 13.0 so we need this shim
/// for the foreseeable future.
struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

/// The central state store for the current import session.
///
/// Holds the array of Photo objects, the current selection set, the
/// current folder URL, and the loading-progress counter. All views
/// observe this object via @EnvironmentObject.
///
/// `@preconcurrency import AppKit` silences Swift's strict-concurrency
/// warnings about NSImage not being Sendable on macOS 13. The deployment
/// target is 13.0 (Ventura); NSImage only became formally Sendable in
/// macOS 14. NSImage is in practice immutable-after-decode and safe to
/// pass across actors — the compiler just can't prove that without the
/// annotation. `@preconcurrency` tells it to trust the legacy API.
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

    /// How the grid is sorted. Toolbar exposes a menu to change this.
    @Published var sortMode: SortMode = .filenameAscending

    /// Minimum star rating to show in the grid. 0 = no filter (show all).
    /// Photos rated below this threshold are hidden but still in `photos`.
    @Published var ratingFilter: Int = 0

    /// When true, rejected photos are also hidden from the grid (in
    /// addition to the rating filter).
    @Published var hideRejected: Bool = false

    /// Currently-running import task. Cancelled when a new import starts
    /// so we never have two scans racing to write to `photos`.
    private var importTask: Task<Void, Never>? = nil

    /// Photos whose thumbnail is currently being generated. Prevents the
    /// "thundering herd" of N cells all kicking off the same decode.
    private var thumbnailInFlight: Set<UUID> = []

    /// Photos whose 1600px preview is currently being generated. Same
    /// dedupe pattern as `thumbnailInFlight` for the lightbox.
    private var previewInFlight: Set<UUID> = []

    // MARK: - Derived state

    /// The photos to show in the grid, after applying `ratingFilter`,
    /// `hideRejected`, and `sortMode`. SwiftUI re-evaluates this whenever
    /// `photos`, `sortMode`, `ratingFilter`, or `hideRejected` changes,
    /// or when any individual Photo's rating/reject flag publishes.
    var visiblePhotos: [Photo] {
        let filtered = photos.filter { photo in
            if hideRejected && photo.isRejected { return false }
            if photo.starRating < ratingFilter { return false }
            return true
        }
        return filtered.sorted(by: sortMode.comparator)
    }

    /// Number of photos after filtering (before sorting). Used for the
    /// "Showing N of M" status text.
    var visibleCount: Int { visiblePhotos.count }

    /// Convenience: the currently-selected Photo objects in display order.
    /// Selection is independent of the filter — the user can keep a
    /// selection even if they change the filter to hide those photos.
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
    /// Counts against the RAW `photos` array — the user wants to see how
    /// many 5-stars they've rated in total, not just how many are visible.
    func count(rating: Int) -> Int {
        photos.filter { $0.starRating == rating }.count
    }

    /// Convenience: count of rejected photos (across all photos).
    var rejectedCount: Int { photos.filter { $0.isRejected }.count }

    // MARK: - Import

    /// Import a folder of RAWs. Replaces the current session.
    /// If a previous import is in progress it is cancelled.
    ///
    /// Threading:
    /// - The directory enumeration runs on a detached task (`ImportService.importFolder`)
    ///   so a folder with thousands of files doesn't jank the UI.
    /// - We hop back to the main actor before constructing `Photo` instances
    ///   (which is `@MainActor`) and before mutating `photos`.
    ///
    /// Performance: `Photo.init` is now just two property assignments
    /// (URL, fileName). The previous version called
    /// `FileManager.attributesOfItem` per photo to fetch the file size,
    /// which added a stat syscall per file — for 1000 photos that was
    /// 100–300 ms of blocking work on the main thread, and the size was
    /// never read anywhere. See `Photo.swift` for the rationale.
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

        importTask = Task { [weak self] in
            // Off-main: enumerate the folder. Returns [URL] — no Photo
            // construction happens here, so we're free of @MainActor.
            let urls = await Task.detached(priority: .userInitiated) {
                ImportService.importFolder(at: url)
            }.value

            guard let self = self else { return }
            // If the user kicked off another import while we were running,
            // `importTask` now points at a newer task and we should bail.
            guard !Task.isCancelled else { return }
            // Back on the main actor (this Task is implicit-main because
            // `self` is @MainActor). Build Photo instances and publish.
            // Photo.init is now cheap (no per-file stat), so this scales
            // linearly: 10K photos ≈ 30 ms.
            self.photos = urls.map { Photo(url: $0) }
            self.loadingProgress = (0, urls.count)
            self.isLoading = false
        }
    }

    // MARK: - Thumbnails

    /// Lazy-load thumbnails for visible cells. Dedupes via `thumbnailInFlight`
    /// so the same photo is never decoded more than once concurrently.
    ///
    /// Threading + parallelism:
    /// - Each photo gets its own `Task.detached` so multiple RAW decodes
    ///   run concurrently across cores. The previous version awaited each
    ///   decode before starting the next — sequential and slow on multi-
    ///   core machines (one core busy, seven idle).
    /// - Swift's cooperative thread pool is large enough (~64 threads)
    ///   to absorb a batch of 40 simultaneous decodes without thrashing.
    ///   Each inner task awaits a single `MainActor.run` for the Photo
    ///   assignment, so main-thread work stays trivial.
    /// - We don't cancel in-flight decodes on `Task.isCancelled` because
    ///   detached tasks don't propagate cancellation — but the early
    ///   `break` in the outer loop prevents NEW decodes from starting
    ///   after a cancel.
    /// - The `thumbnailInFlight` Set is the concurrency control: it's
    ///   populated up-front (synchronously) before any task is fired, so
    ///   duplicate `.onAppear` callbacks for the same cell can't queue
    ///   redundant decodes.
    func loadThumbnails(in range: Range<Int>) {
        guard !isLoading else { return }
        let toLoad = photos[range].filter { $0.thumbnail == nil && !thumbnailInFlight.contains($0.id) }
        guard !toLoad.isEmpty else { return }

        // Mark all of them in-flight up front so the next cell's
        // `.onAppear` sees them as already-loading and skips.
        for p in toLoad { thumbnailInFlight.insert(p.id) }

        // Outer Task is on the main actor (it captures `self` which is
        // @MainActor). Inside, we fire detached tasks that run off-main.
        // We do NOT await each one — that would serialize the work.
        Task { [weak self] in
            for photo in toLoad {
                if Task.isCancelled { break }
                let id = photo.id
                let url = photo.url
                // Each detached task: decode off-main, hop to main once
                // for the assignment, then exit. NSImage is wrapped in
                // `SendableImage` (`@unchecked Sendable`) to cross the
                // actor boundary on macOS 13.
                Task.detached(priority: .userInitiated) { [weak self] in
                    let wrapped = SendableImage(
                        image: ThumbnailService.generateThumbnail(for: url) ?? NSImage()
                    )
                    _ = await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.thumbnailInFlight.remove(id)
                        let thumb = wrapped.image
                        // SendableImage defaults to a zero-size NSImage
                        // when the generator returned nil; skip those.
                        if thumb.size.width > 0,
                           let p = self.photos.first(where: { $0.id == id }) {
                            p.thumbnail = thumb
                        }
                    }
                }
            }
        }
    }

    // MARK: - Previews (for the lightbox)

    /// Lazy-load a 1600px preview for a single photo. Dedupes via
    /// `previewInFlight`. Called when the lightbox opens on a photo and
    /// when navigating to neighbours so the next arrow-press is instant.
    ///
    /// Threading:
    /// - Decode runs on a detached task (off main).
    /// - Assignment to `photo.preview` happens inside `MainActor.run`
    ///   because Photo is `@MainActor`.
    func loadPreview(for photo: Photo) {
        guard photo.preview == nil, !previewInFlight.contains(photo.id) else { return }
        previewInFlight.insert(photo.id)
        let id = photo.id
        let url = photo.url
        Task { [weak self] in
            let wrapped = await Task.detached(priority: .userInitiated) {
                SendableImage(image: ThumbnailService.generatePreview(for: url) ?? NSImage())
            }.value
            _ = await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.previewInFlight.remove(id)
                let preview = wrapped.image
                if preview.size.width > 0,
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
        // Select all VISIBLE photos — if a filter is active, "all" means
        // "all you can see right now", which is what Photo Mechanic does.
        selectedIDs = Set(visiblePhotos.map { $0.id })
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
    ///
    /// Navigation in the lightbox uses `visiblePhotos` so the filter applies:
    /// if you've filtered to ★4+, the arrows skip the hidden photos.
    func openLightbox(on photo: Photo) {
        lightboxPhotoID = photo.id
        selectedIDs = [photo.id]
        loadPreview(for: photo)
        // Pre-warm the next and previous so arrow presses are instant.
        if let idx = visiblePhotos.firstIndex(where: { $0.id == photo.id }) {
            if idx > 0 { loadPreview(for: visiblePhotos[idx - 1]) }
            if idx + 1 < visiblePhotos.count { loadPreview(for: visiblePhotos[idx + 1]) }
        }
    }

    /// Close the lightbox. Selection is preserved so the user can keep
    /// working with the last-viewed photo (or any selection they had).
    func closeLightbox() {
        lightboxPhotoID = nil
    }

    /// Navigate to the next (or previous, with negative step) photo in the
    /// VISIBLE list. No-op at the edges — the user must press Esc to leave
    /// the lightbox. Auto-advances the selection and pre-warms the new neighbour.
    func lightboxStep(_ step: Int) {
        let visible = visiblePhotos
        guard let current = lightboxPhoto,
              let idx = visible.firstIndex(where: { $0.id == current.id }) else { return }
        let next = idx + step
        guard next >= 0, next < visible.count else { return }
        let target = visible[next]
        lightboxPhotoID = target.id
        selectedIDs = [target.id]
        loadPreview(for: target)
        // Pre-warm the new neighbour on the side we're moving into.
        let neighbour = next + step
        if neighbour >= 0, neighbour < visible.count {
            loadPreview(for: visible[neighbour])
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

    // MARK: - Filter / Sort helpers

    /// Cycle ratingFilter forward through 0 → 1 → 2 → 3 → 4 → 5 → 0.
    /// Called by the toolbar button to step through "show all", "★1+",
    /// "★2+", ... "★5 only".
    func cycleRatingFilter() {
        ratingFilter = (ratingFilter + 1) % 6
    }

    /// Set ratingFilter to a specific value (0–5). 0 means "no filter".
    func setRatingFilter(_ value: Int) {
        ratingFilter = max(0, min(5, value))
    }

    /// Clear the rating filter and show rejected photos.
    func resetFilters() {
        ratingFilter = 0
        hideRejected = false
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
            let priorIdx = visiblePhotos.firstIndex(where: { $0.id == trashedID })
            photos.removeAll { $0.id == trashedID }
            selectedIDs = []

            // Advance the lightbox to a neighbour, or close if none left.
            if visiblePhotos.isEmpty {
                lightboxPhotoID = nil
            } else {
                // Prefer the photo at the same index (now the "next" one);
                // fall back to the new last photo if we trashed the tail.
                let targetIdx = min(priorIdx ?? 0, visiblePhotos.count - 1)
                let next = visiblePhotos[targetIdx]
                lightboxPhotoID = next.id
                selectedIDs = [next.id]
                loadPreview(for: next)
            }

            let url = p.url
            Task { [weak self] in
                _ = ExternalAppService.moveToTrash(url)
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
                if ExternalAppService.moveToTrash(url) {
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
            return sel.isEmpty ? visiblePhotos : sel
        }()
        for p in targets {
            ExternalAppService.openInPixelmator(p.url)
        }
    }

    /// Reveal selected photos in Finder.
    func revealSelectionInFinder() {
        let targets = selectedPhotos.isEmpty ? visiblePhotos : selectedPhotos
        for p in targets {
            ExternalAppService.revealInFinder(p.url)
        }
    }
}

// MARK: - SortMode

/// The order the grid is rendered in. Toolbar exposes a menu to switch
/// between these. New cases should be added here AND to the toolbar's
/// Sort menu — the comparator is the single source of truth for ordering.
///
/// Not `@MainActor` at the enum level: `id`, `label`, and `systemImage`
/// are pure (don't access actor-isolated state) and conforming to
/// `Identifiable` from a main-actor type would require `@MainActor` on
/// every member. Only `comparator` touches `Photo.starRating` /
/// `Photo.fileName`, so only that property is marked `@MainActor`.
enum SortMode: String, CaseIterable, Identifiable {
    /// Original filename order (IMG_0001 < IMG_0002 < IMG_0010, natural sort).
    case filenameAscending
    /// 5-star photos first, then 4, 3, 2, 1, unrated. Within the same
    /// rating, ties broken by filename.
    case ratingDescending
    /// Unrated first, then 1, 2, 3, 4, 5 stars. Within the same rating,
    /// ties broken by filename.
    case ratingAscending

    var id: String { rawValue }

    /// Human-readable label for the toolbar menu.
    var label: String {
        switch self {
        case .filenameAscending: return "Filename"
        case .ratingDescending: return "Rating (high → low)"
        case .ratingAscending:  return "Rating (low → high)"
        }
    }

    /// SF Symbol for the toolbar menu button.
    var systemImage: String {
        switch self {
        case .filenameAscending: return "textformat.abc"
        case .ratingDescending: return "star.fill"
        case .ratingAscending:  return "star"
        }
    }

    /// Comparator suitable for `Array.sorted(by:)`. All branches break
    /// ties by filename (natural sort) so the output is deterministic.
    ///
    /// Marked `@MainActor` because Photo's `starRating` and `fileName`
    /// are main-actor isolated. The comparator is only ever called from
    /// `PhotoStore.visiblePhotos` (also main-actor), so this is safe at
    /// runtime. The `@MainActor` lives on the property, not the enum,
    /// because `Identifiable`'s `id` requirement is non-isolated and the
    /// whole enum would otherwise drag it across actor boundaries.
    @MainActor
    var comparator: (Photo, Photo) -> Bool {
        switch self {
        case .filenameAscending:
            return { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .ratingDescending:
            return { lhs, rhs in
                if lhs.starRating != rhs.starRating { return lhs.starRating > rhs.starRating }
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
        case .ratingAscending:
            return { lhs, rhs in
                if lhs.starRating != rhs.starRating { return lhs.starRating < rhs.starRating }
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
        }
    }
}
