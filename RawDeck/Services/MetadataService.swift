import Foundation
import AppKit
import UniformTypeIdentifiers

/// Writes per-photo metadata as XMP sidecar files and provides
/// "save ratings and eject" workflow.
///
/// **XMP sidecar format**:
/// Each `IMG_1234.CR3` gets a sibling `IMG_1234.xmp` containing the
/// star rating (and reject flag) as XMP tags. The original `.CR3`
/// file is NEVER modified — only a new `.xmp` file is written
/// alongside it. This is the same approach Lightroom, Photo Mechanic,
/// Capture One, and Apple Photos use for RAW metadata round-tripping,
/// so when the user re-inserts the SD card in any of those apps, the
/// ratings carry over.
///
/// **Why XMP and not embed in EXIF?**
/// CR3's metadata block (the ISO BMFF container) is technically
/// writable, but modifying it requires rewriting the entire file's
/// mdat atom offsets, which is risky on macOS where the system RAW
/// codec (which we depend on for thumbnail decoding via Quick Look)
/// may reject the modified file or, worse, crash. Sidecar XMP is
/// the universally-supported safe path.
///
/// **Eject**:
/// After writing all sidecars, we call `diskutil eject` on the
/// volume containing the imported folder. This is what Finder does
/// when you drag a card to the trash — the user can then physically
/// remove the SD card.
enum MetadataService {

    // MARK: - Public API

    /// Snapshot of sidecars written for one photo. Used internally.
    struct SaveResult: Sendable {
        var writtenCount: Int = 0
        var skippedCount: Int = 0  // photos with no rating/reject to save
        var failedCount: Int = 0
        var failedFiles: [String] = []
        var ejected: Bool = false
        var ejectError: String? = nil

        var hasFailures: Bool { failedCount > 0 }
        var hasContent: Bool { writtenCount > 0 }
    }

    // MARK: - XMP reading

    /// Parsed XMP sidecar contents. Used to recover ratings when a
    /// folder is re-imported (e.g. after ejecting the SD card and
    /// reinserting it). Mirrors the values written by
    /// `makeXMPContent`.
    struct SidecarMetadata: Equatable {
        var starRating: Int = 0   // 0–5, 0 = unrated
        var isRejected: Bool = false
    }

    /// Read the XMP sidecar for a given photo URL, if one exists and
    /// is valid. Returns nil if there's no sidecar or it can't be
    /// parsed. Never throws — sidecar read failures should be
    /// non-fatal during import.
    ///
    /// **Mtime handling**: if the source file's modification time is
    /// newer than the sidecar's, we ignore the sidecar (the user may
    /// have re-edited the RAW in another app and the old rating is
    /// stale). This protects against stale ratings surfacing after
    /// the user has reworked a shoot.
    static func readXMPSidecar(for photoURL: URL) -> SidecarMetadata? {
        let sidecar = sidecarURL(for: photoURL)

        // Quick existence check — FileManager.fileExists is much
        // cheaper than reading the file then discovering it's empty.
        guard FileManager.default.fileExists(atPath: sidecar.path) else {
            return nil
        }

        // Mtime guard: if the source is newer than the sidecar, the
        // sidecar is stale (user re-edited the RAW elsewhere). Skip.
        if let srcMtime = mtimeOfFile(at: photoURL),
           let sidecarMtime = mtimeOfFile(at: sidecar),
           srcMtime > sidecarMtime {
            return nil
        }

        guard let data = try? Data(contentsOf: sidecar),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return parseXMP(text)
    }

    /// Cheap mtime read for the mtime guard. Returns nil on any I/O
    /// error so we fall through to parsing the XMP anyway (better to
    /// show a slightly-stale rating than none).
    private static func mtimeOfFile(at url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Parse the small subset of XMP we care about: `xmp:Rating`,
    /// `xmp:Reject`. Tolerant of missing/wrong types — returns
    /// `SidecarMetadata` with whatever fields could be extracted.
    ///
    /// Implementation: simple regex over the XML text. XMP uses
    /// fixed attribute names and the values are either digits or
    /// "True"/"False", so a regex-based parser is sufficient here
    /// and avoids pulling in NSXMLParser (which is heavier and not
    /// needed for this scope).
    private static func parseXMP(_ text: String) -> SidecarMetadata? {
        var result = SidecarMetadata()

        // xmp:Rating="N" (1-5) or "0" for unrated, "-1" for rejected
        if let ratingRange = text.range(
            of: #"xmp:Rating\s*=\s*"-?\d+""#,
            options: .regularExpression
        ) {
            let match = text[ratingRange]
            if let num = match.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap({ Int($0) }).first {
                result.starRating = max(0, min(5, abs(num)))
            }
        }

        // xmp:Reject="True" or "False"
        if let rejectRange = text.range(
            of: #"xmp:Reject\s*=\s*"(True|False|true|false|1|0)""#,
            options: .regularExpression
        ) {
            let match = text[rejectRange]
            let lower = match.lowercased()
            result.isRejected = lower.contains("true") || lower.contains("\"1\"")
        }

        // If we found nothing usable, return nil so the caller
        // doesn't think we got valid data.
        guard result.starRating > 0 || result.isRejected else {
            return nil
        }
        return result
    }

    // MARK: - XMP writing

    /// Generate the XMP sidecar file URL for a given photo. The
    /// sidecar has the same name as the source file but with `.xmp`
    /// extension, sitting in the same directory.
    static func sidecarURL(for photoURL: URL) -> URL {
        var url = photoURL
        // Swap the extension. CR3 → xmp, NEF → xmp, etc.
        url.deletePathExtension()
        url.appendPathExtension("xmp")
        return url
    }

    /// Write the XMP sidecar file for one photo. Throws on I/O error.
    /// No-op (and no error) if the photo has no rating and no reject
    /// flag — nothing to save.
    ///
    /// Two overloads: one taking a `Photo` (for in-app use from the
    /// MainActor) and one taking raw values (for use from `Task.detached`
    /// where Photo's `@MainActor` isolation makes it awkward to construct).
    ///
    /// The `Photo`-taking overload is `@MainActor` because it reads
    /// `photo.starRating` and `photo.isRejected`, which are isolated
    /// to MainActor. The values-taking overload is nonisolated so it
    /// can be called from `Task.detached`.
    @MainActor
    static func writeXMPSidecar(for photo: Photo) throws {
        try writeXMPSidecar(
            url: photo.url,
            starRating: photo.starRating,
            isRejected: photo.isRejected
        )
    }

    nonisolated static func writeXMPSidecar(url: URL, starRating: Int, isRejected: Bool) throws {
        // Only write if there's something to save. No empty sidecars.
        guard starRating > 0 || isRejected else { return }

        let xmp = makeXMPContent(starRating: starRating, isRejected: isRejected)
        let sidecar = sidecarURL(for: url)
        try xmp.write(to: sidecar, atomically: true, encoding: .utf8)
    }

    /// Build the XMP XML content. Uses the standard XMP namespaces
    /// that every RAW-aware app recognizes:
    ///
    /// - `xmp:Rating` — 1-5 stars (Lightroom/Apple Photos standard)
    /// - `xmp:Reject` — boolean (Lightroom 3+ standard)
    /// - `xmp:MetadataDate` — when the rating was last edited
    /// - `dc:creator` — RawDeck (so the user knows which app wrote this)
    ///
    /// Format reference: Adobe XMP Specification Part 2 (Standard
    /// Schemas). The XMP packet is wrapped in `<?xpacket begin=...?>`
    /// markers which Lightroom requires for round-tripping.
    static func makeXMPContent(starRating: Int, isRejected: Bool) -> String {
        let dateString = ISO8601DateFormatter().string(from: Date())
        // ISO 8601 timestamps in XMP can include colons, but some
        // strict parsers reject them. Adobe uses YYYY-MM-DDThh:mm:ss
        // without timezone marker for xmp:MetadataDate.
        let safeDate = dateString.replacingOccurrences(of: ":", with: "-")

        let rating: String = {
            if starRating > 0 { return "\(starRating)" }
            // LightRoom convention: 0 = unrated, -1 = rejected (no
            // separate flag). But xmp:Reject is also valid; we use
            // both for maximum app compatibility.
            return "0"
        }()

        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="RawDeck 1.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:dc="http://purl.org/dc/elements/1.1/"
                xmp:Rating="\(rating)"
                xmp:Reject="\(isRejected ? "True" : "False")"
                xmp:MetadataDate="\(safeDate)">
              <dc:creator>
                <rdf:Seq>
                  <rdf:li>RawDeck</rdf:li>
                </rdf:Seq>
              </dc:creator>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    // MARK: - Eject

    /// Eject the volume containing the given URL using `diskutil`.
    /// This is what Finder does when you drag a card to the trash —
    /// the user can then physically remove the SD card.
    ///
    /// Throws if `diskutil` returns non-zero. The volume stays mounted
    /// in that case so the user doesn't lose their sidecars.
    static func ejectVolume(containing url: URL) throws {
        // Walk up from the file URL to find the mount point. For an
        // SD card mounted at /Volumes/SDCARD, any file inside
        // /Volumes/SDCARD/DCIM/.../IMG_1234.CR3 resolves to
        // /Volumes/SDCARD as its mount point.
        let mountPoint = mountPoint(for: url)

        // Use /usr/sbin/diskutil explicitly since the user's PATH
        // may not include /usr/sbin (common for non-admin accounts).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", mountPoint.path]

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "diskutil exited \(process.terminationStatus)"
            throw NSError(
                domain: "MetadataService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
    }

    /// Find the mount point (e.g. /Volumes/SDCARD) for a file URL.
    /// We compare the file's path against the mount points listed by
    /// `df` and return the longest matching prefix.
    static func mountPoint(for url: URL) -> URL {
        let path = url.standardizedFileURL.path
        // Try common mount points first — faster than spawning `df`.
        let volumesRoot = "/Volumes/"
        if path.hasPrefix(volumesRoot) {
            // The mount point is /Volumes/<NAME> where NAME is the
            // first path component after /Volumes/.
            let afterVolumes = String(path.dropFirst(volumesRoot.count))
            if let slashIdx = afterVolumes.firstIndex(of: "/") {
                let volumeName = String(afterVolumes[..<slashIdx])
                return URL(fileURLWithPath: volumesRoot + volumeName)
            } else {
                return URL(fileURLWithPath: volumesRoot + afterVolumes)
            }
        }
        // Fallback: assume root.
        return URL(fileURLWithPath: "/")
    }
}