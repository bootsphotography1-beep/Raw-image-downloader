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

    /// Which top-level mode the app is in. The mode determines what
    /// the main content area shows and which keyboard shortcuts are
    /// active. Library mode is the default; Colorway Parser mode adds the
    /// preset-extraction feature as a sibling tab.
    @Published var mode: AppMode = .library

    @Published var photos: [Photo] = []
    @Published var currentFolder: URL? = nil
    @Published var selectedIDs: Set<UUID> = []
    @Published var isLoading: Bool = false
    @Published var loadingProgress: (done: Int, total: Int) = (0, 0)
    @Published var lastError: String? = nil

    /// One-shot alert message for the view layer to surface. Non-nil
    /// means "show an alert with this message". The view sets it back
    /// to nil on dismiss.
    @Published var alertMessage: String? = nil

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
    /// Concurrency strategy:
    /// - The grid renders cells as they appear on screen, so each one's
    ///   `.onAppear` calls into here. With hundreds of cells visible this
    ///   used to fire hundreds of detached tasks at once, oversubscribing
    ///   the cooperative pool (and the memory bandwidth) during import.
    ///   Result: every decode slowed down, RAM pressure spiked, and the
    ///   lightbox (if the user hit Space mid-import) would jump in and
    ///   slam the system further.
    /// - Fix: bound parallelism to `ProcessInfo.activeProcessorCount` —
    ///   one RAW decode per physical core. Decodes pipeline into the
    ///   pool; the rest queue behind a DispatchSemaphore. End result is
    ///   roughly 2–4× faster wall-clock import on an 8-core machine
    ///   (you waste less time context-switching) and the lightbox stays
    ///   responsive.
    /// - `kCGImageSourceShouldCacheImmediately: false` (set in
    ///   ThumbnailService) means ImageIO defers bitmap allocation to
    ///   draw time, so we don't double the RAM cost by eagerly
    ///   materializing a 512-pixel thumbnail.
    func loadThumbnails(in range: Range<Int>) {
        guard !isLoading else { return }
        let toLoad = photos[range].filter { $0.thumbnail == nil && !thumbnailInFlight.contains($0.id) }
        guard !toLoad.isEmpty else { return }

        // Mark them in-flight up front so a subsequent .onAppear for the
        // same cell can't queue a redundant decode.
        for p in toLoad { thumbnailInFlight.insert(p.id) }

        let maxParallel = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let sem = DispatchSemaphore(value: maxParallel)

        Task { [weak self] in
            for photo in toLoad {
                if Task.isCancelled { break }
                let id = photo.id
                let url = photo.url
                // Acquire a slot. `sem.wait()` is fine inside a Task because
                // it suspends the task on a continuation, not blocks a thread.
                sem.wait()
                Task.detached(priority: .userInitiated) { [weak self] in
                    let wrapped = SendableImage(
                        image: ThumbnailService.generateThumbnail(for: url) ?? NSImage()
                    )
                    // Always release the slot, even if self vanished mid-decode
                    // (e.g. the user closed the window during import). Putting
                    // the signal here on the worker thread, before the main-actor
                    // hop, means a deallocated store can't deadlock the importer.
                    sem.signal()
                    _ = await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.thumbnailInFlight.remove(id)
                        let thumb = wrapped.image
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

    /// Lazy-load the full-resolution preview for a single photo. Dedupes
    /// via `previewInFlight`. Called when the lightbox opens on a photo
    /// and when navigating to neighbours so the next arrow-press is
    /// instant.
    ///
    /// Quality strategy:
    /// - Earlier versions decoded at 1600px via `CGImageSourceCreateThumbnailAtIndex`
    ///   — that's the camera's *embedded JPEG preview* (~1600×1080 baked
    ///   into the RAW by the camera). Stretched to fit a 5K iMac's
    ///   fullscreen lightbox, that looked grainy/dark/blurry: the JPEG
    ///   was lossy-compressed and upscaling made every compression
    ///   artefact obvious.
    /// - The fix uses `CGImageSourceCreateImageAtIndex`, which gets
    ///   ImageIO's RAW decoder to demosaic the full sensor capture. A
    ///   24MP CR3 becomes a 6000×4000 NSImage drawn at native pixels.
    ///   Cost: 200–500ms per decode off-main. RAM stays bounded because
    ///   `shouldCacheImmediately: false` defers inflation.
    ///
    /// Threading:
    /// - Decode runs on a detached task (off main).
    /// - Assignment to `photo.preview` happens inside `MainActor.run`
    ///   because Photo is `@MainActor`.
    ///
    /// For non-RAW files (JPEG/HEIC/TIFF/PNG) `generateFullPreview` falls
    /// back to a 2400px thumbnail from the embedded JPEG path, which is
    /// fine because the source has no sensor RAW to decode — it's
    /// already an output-quality pixel buffer.
    func loadPreview(for photo: Photo) {
        guard photo.preview == nil, !previewInFlight.contains(photo.id) else { return }
        previewInFlight.insert(photo.id)
        let id = photo.id
        let url = photo.url
        Task { [weak self] in
            let wrapped = await Task.detached(priority: .userInitiated) {
                SendableImage(image: ThumbnailService.generateFullPreview(for: url) ?? NSImage())
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
    ///
    /// If Pixelmator Pro isn't installed, sets `alertMessage` so the view
    /// layer can show a user-facing alert (instead of silently falling back
    /// to whatever the system default RAW handler is — which is often
    /// Photoshop, causing the confusing "I clicked Open in Pixelmator and
    /// it opened in Photoshop" UX).
    func openSelectionInPixelmator(photo: Photo? = nil) {
        let targets: [Photo] = {
            if let p = photo { return [p] }
            let sel = selectedPhotos
            return sel.isEmpty ? visiblePhotos : sel
        }()
        guard !targets.isEmpty else { return }
        var openedCount = 0
        for p in targets {
            if ExternalAppService.openInPixelmator(p.url) {
                openedCount += 1
                // Mark this photo as sent to Pixelmator Pro so the grid
                // cell can render a small badge (RDColor.wand.and.stars).
                // Session-only state — same lifetime as the star rating.
                p.sentToPixelmator = Date()
            }
        }
        if openedCount == 0 {
            // None of the opens succeeded — Pixelmator isn't installed.
            // Surface a clear alert instead of silently opening the system
            // default (which is what the previous version did, and it caused
            // "I clicked Open in Pixelmator but it opened in Photoshop"
            // confusion).
            alertMessage = "Pixelmator Pro isn't installed on this Mac.\n\nInstall it from pixelmator.com to use this feature, or change the system default RAW handler in Finder's Get Info panel."
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

// MARK: - AppMode

/// Top-level mode the RawDeck window is in. Determines which content
/// fills the main area and which keyboard shortcuts are active.
///
/// Currently two modes:
/// - `.library` — the original RawDeck: import a folder, cull/rate
///   photos, lightbox view, send to Pixelmator.
/// - `.colorwayParser` — paste/drop a reference image, derive a Camera
///   Raw preset, export as .xmp or as a recreation sheet for editors
///   that don't read XMP natively (e.g. Pixelmator Pro).
///
/// Adding a third mode (e.g. `.print`, `.export`) means adding a case
/// here, a switch arm in `ContentView`, and (if needed) per-mode
/// shortcut bindings in `RawDeckApp`.
enum AppMode: String, CaseIterable, Identifiable {
    case library
    case colorwayParser

    var id: String { rawValue }

    /// Display label for the segmented picker.
    var label: String {
        switch self {
        case .library:   return "Library"
        case .colorwayParser: return "Colorway"
        }
    }

    /// SF Symbol shown next to the label in the picker.
    var systemImage: String {
        switch self {
        case .library:   return "rectangle.stack"
        case .colorwayParser: return "wand.and.stars"
        }
    }
}
