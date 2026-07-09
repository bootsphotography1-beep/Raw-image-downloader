import Foundation

/// Moves a library from one backend's root to another's. Tree `mv`,
/// atomic per-subtree.
///
/// We expose this *now* even though v1 ships a single backend by default,
/// because switching backends is a use case the user is going to hit on day
/// one: "I started on iCloud, now I want to use Google Photos." Shipping the
/// migrator keeps that flow honest and avoids a v2 data-migration problem.
enum LibraryMigrator {

    enum MigrationError: Error, LocalizedError {
        case sourceUnreachable(URL)
        case destinationUnreachable(URL)
        case sourceEmpty
        case ioFailure(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .sourceUnreachable(let url):
                return "Source library is not reachable: \(url.path)"
            case .destinationUnreachable(let url):
                return "Destination library is not reachable: \(url.path)"
            case .sourceEmpty:
                return "Source library has no files to migrate."
            case .ioFailure(let e):
                return "I/O failure: \(e.localizedDescription)"
            }
        }
    }

    /// Progress callback, fires once per top-level subfolder
    /// (`Library`, `Inbox`, `Trash`). Use it to drive a UI progress bar.
    typealias Progress = (_ phase: String, _ completed: Int, _ total: Int) -> Void

    /// Move all RAW + XMP sidecar files from `from` to `to`. Photos are
    /// reparented into the same `Library/Inbox/Trash` shape at the
    /// destination. Returns when all three phases are complete.
    static func migrate(from fromBackend: SyncBackend,
                       to toBackend: SyncBackend,
                       progress: Progress? = nil) throws {

        guard let fromRoot = fromBackend.resolveRootURL() else {
            throw MigrationError.sourceUnreachable(URL(fileURLWithPath: "/"))
        }
        guard let toRoot = toBackend.resolveRootURL() else {
            throw MigrationError.destinationUnreachable(URL(fileURLWithPath: "/"))
        }

        let fm = FileManager.default

        // Refuse to operate on identical or overlapping paths.
        let fromPath = fromRoot.standardizedFileURL.path
        let toPath   = toRoot.standardizedFileURL.path
        guard fromPath != toPath else { return }
        guard !toPath.hasPrefix(fromPath + "/") else {
            // Destination is *inside* source. Refuse.
            throw MigrationError.destinationUnreachable(toRoot)
        }

        let phases = ["Library", "Inbox", "Trash"]
        var totalFiles = 0
        var movedFiles = 0

        for phase in phases {
            let srcPhase = fromRoot.appendingPathComponent(phase, isDirectory: true)
            guard fm.fileExists(atPath: srcPhase.path) else { continue }

            let enumerator = fm.enumerator(at: srcPhase,
                                            includingPropertiesForKeys: nil,
                                            options: [.skipsHiddenFiles])
            guard let enumerator else { continue }

            // First pass: count.
            var count = 0
            for _ in enumerator { count += 1 }

            // Second pass: enumerate and move. We re-create the enumerator
            // because the first one is exhausted.
            let moveEnum = fm.enumerator(at: srcPhase,
                                          includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles])
            guard let moveEnum else { continue }

            for case let url as URL in moveEnum {
                guard url.pathExtension.lowercased() != "" else { continue }
                // We only migrate RAW + XMP files. Anything else (notes,
                // receipts, etc.) stays at the source.
                let ext = url.pathExtension.lowercased()
                let isRaw = ThumbnailService.isLikelyRAW(url)
                let isXMP = ext == "xmp"
                guard isRaw || isXMP else { continue }

                let relative = relativePath(of: url, from: fromRoot)
                let dst = toRoot.appendingPathComponent(relative)
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dst.path) {
                        try fm.removeItem(at: dst)
                    }
                    try fm.moveItem(at: url, to: dst)
                    movedFiles += 1
                    progress?(phase, movedFiles, totalFiles + count)
                } catch {
                    throw MigrationError.ioFailure(underlying: error)
                }
            }

            totalFiles += count
            progress?(phase, movedFiles, totalFiles)
        }
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let urlPath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if urlPath.hasPrefix(rootPath + "/") {
            return String(urlPath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
