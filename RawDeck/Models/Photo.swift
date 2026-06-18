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
@MainActor
final class Photo: Identifiable, ObservableObject {
    let id: UUID = UUID()
    let url: URL
    let fileName: String
    let fileSize: Int64

    @Published var starRating: Int = 0   // 0–5
    @Published var isRejected: Bool = false
    @Published var thumbnail: NSImage? = nil  // lazy-loaded by ThumbnailService

    init(url: URL) {
        self.url = url
        self.fileName = url.lastPathComponent

        // File size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            self.fileSize = size
        } else {
            self.fileSize = 0
        }
    }
}
