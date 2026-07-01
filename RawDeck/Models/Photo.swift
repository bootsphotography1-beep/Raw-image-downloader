import Foundation
import AppKit

/// A single RAW photo in the current import session.
///
/// `Photo` is the model. It wraps a file URL on disk and tracks the
/// session-only state (star rating, reject flag). The library does NOT
/// persist between launches — per Fin B's spec ("no library, just the
/// current folder"). All state lives in memory; close the app and the
/// stars vanish (intentional).
///
/// `@MainActor` because the rating/reject state is mutated only from the
/// `PhotoStore` (which is also `@MainActor`) and from SwiftUI views.
///
/// Performance note: `init` deliberately does NOT call
/// `FileManager.attributesOfItem` to fetch the file size. That syscall
/// adds ~0.1–0.3 ms per file, so 1000 photos added 100–300 ms of
/// blocking work on the main thread during import — and the size was
/// never read anywhere else. If a file size is needed in the future,
/// pre-fetch it during directory enumeration (see `ImportService`)
/// using `URL.resourceValues(forKeys: [.fileSizeKey])` instead of a
/// per-file stat.
@MainActor
final class Photo: Identifiable, ObservableObject {
    let id: UUID = UUID()
    let url: URL
    let fileName: String

    @Published var starRating: Int = 0   // 0–5
    @Published var isRejected: Bool = false
    @Published var sentToPixelmator: Date? = nil  // last time this photo was opened in Pixelmator Pro
    @Published var thumbnail: NSImage? = nil  // lazy-loaded by ThumbnailService
    @Published var preview: NSImage? = nil     // larger (1600px) lazy-loaded preview for the lightbox
    /// True after we've tried (and either succeeded or failed) to load
    /// the thumbnail. Distinguishes "still loading" from "failed to
    /// load" so the cell can show a "broken image" icon instead of a
    /// permanent spinner.
    @Published var thumbnailLoadAttempted: Bool = false

    init(url: URL) {
        self.url = url
        self.fileName = url.lastPathComponent
    }
}