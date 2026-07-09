# RawDeck + Manual: Bridge Design Doc

**Author:** Hermes (for Fin)
**Status:** Approved by Fin 2026-07-07. Phase 1 in progress.
**Target:** macOS RawDeck v1 = sync + library + culling. Editor tab deferred to v2 (Settings card "Editor — coming soon"). Manual integration as a separate Swift package in v2.

---

## 1. What we're building

A two-app system that shares one photo library across a Mac and an iPhone:

- **Manual** (iOS) — full-manual camera capture for the iPhone. Shoots ProRAW. Designed to be the only capture app needed on the phone. *(Handed off — out of scope for this repo.)*
- **RawDeck** (macOS, this repo) — cull / rate / pick. Soon to gain a synced library rooted in iCloud Drive *or* a Google Photos local-mirror folder, watched live.

Same XMP sidecar metadata either app can write. Both apps can rate a photo; both apps see the result. Third-party tools (Lightroom, Photo Mechanic, Capture One) can read the same library because the format is universal.

**Phone** owns **capture**. **Mac** owns **cull + develop**. **Cloud** is the transport.

## 2. Out of scope (v1)

- Building Manual itself. Manual is a separate project. We don't touch it from this repo.
- The Editor tab. v1 ships **no toolbar tab**; a Settings card "Editor — coming soon" advertises the future work.
- Cross-platform beyond iCloud Drive + Google Photos local mirror.

## 3. Data model — already in place

RawDeck's existing file format is the contract.

- **Photo bytes** — `.dng` (ProRAW) and other RAW formats on disk. One file per photo.
- **Metadata** — `.xmp` sidecars next to each photo, e.g. `IMG_0001.dng` ↔ `IMG_0001.xmp`. Contains `xmp:Rating`, `xmp:RejectReason`, and Adobe `crs:` adjustment tags.
- **Library index** — generated. RawDeck builds the in-memory index by scanning supported extensions and reading sibling `.xmp`. **No central database file.** The directory listing IS the database.

This is intentional: **the file system is the API.** Phone and Mac write standard files. No coordination, no lock contention, no schema migrations. iCloud Drive ships them around.

## 4. Folder layout

Standard shape under the active backend's root.

```
<root>/
    Library/
        <year>/<month>/<day>/<event-or-default>/
            IMG_0001.dng
            IMG_0001.xmp
            ...
    Inbox/             # Quick captures — auto-sorted by RawDeck on first scan
    Trash/             # Mirror of Finder's Trash for cross-device recovery
```

- `year/month/day/` nesting matches what Apple's iCloud Drive UI and Files app expect.
- `Inbox/` — Manual captures land here initially. RawDeck auto-sorts into `Library/yyyy/mm/dd/` based on EXIF capture date on scan.
- `Trash/` — recovers on either device after a delete.

## 5. Sync mechanism — single code path, two backends

### 5.1 Backend abstraction

```swift
enum SyncBackend: String, Codable, CaseIterable {
    case iCloudDrive      // ~/Library/Mobile Documents/com~apple~CloudDocs/RawDeck/
    case googlePhotosMirror  // ~/Library/Group Containers/.../Photos Sync/.../RawDeck/
    case localFolder         // dev/test only
}
```

All three backends resolve to **a single on-disk URL**. Same `LibraryWatcher`, same `PhotoStore` flow. The only difference is which URL we hand the watcher.

**Important: Google Photos as a sync target is implemented via the user's local mirror of their Google Photos Mac client — *not* the PHPhotoLibrary API.** Rationale: a local folder is one code path; raw Google Photos upload is months of code for no v1 wins. Switching backends is `mv` between roots (atomic per-subtree), not a re-upload.

### 5.2 File system watch

`FSEventStream` (CoreServices) — directory-level change events, low overhead, ~12ms latency on iCloud Drive. The watcher is debounced (~250ms) so a burst of file events (typical for "phone just connected and uploaded 50 photos") becomes one scan.

macOS 14+ only at the watcher level. Existing macOS 13 floor is kept; the watcher code is gated with `#available(macOS 14.0, *)`. Below 14, the existing manual-import UX (`Cmd+O` → folder picker) is the only path.

### 5.3 Conflict policy — file-level last-write-wins (v1)

When the same `.xmp` is written on both devices while offline, **the file iCloud uploads last wins.** v1 also writes `dc:modified` on every field so v2 field-level merge is a cheap patch instead of a re-migration.

Last-write-wins can swallow a real rating in edge cases. Document as a known limitation in the Settings → Sync card.

## 6. The Mac-side change

### 6.1 New module: `Services/Library/`

```
Services/Library/
    SyncBackend.swift          // enum + root resolver + persisted user choice
    LibraryRoot.swift          // the active Library/Inbox/Trash URLs
    LibraryWatcher.swift       // FSEventStream wrapper, debounced
    SyncCoordinator.swift      // translates watcher events -> PhotoStore diffs
    InboxSorter.swift          // moves new Inbox/ files into dated folders
    LibraryMigrator.swift      // mv between backends
    SyncSettings.swift         // UserDefaults-backed persisted state
```

### 6.2 PhotoStore additions

- `func scanLibrary(at rootURL: URL)` — wrapper around `ImportService.importFolder`. Existing `importFolder(_ url: URL)` becomes thin.
- `func startWatchingLibrary()` — installs `LibraryWatcher` and routes events through `SyncCoordinator`.
- `func handleLibraryEvent(_ event: WatcherEvent)` — runs `InboxSorter` on new files in `Inbox/`, refreshes visible-photos diff for add/remove/rename elsewhere.
- `func stopWatchingLibrary()`.

### 6.3 Settings tab

`SettingsWindow.swift` (new) with sections:

- **Library** — Current root path (with "Show in Finder" button), open-in-RawDeck button.
- **Sync** — Backend picker (iCloud Drive / Google Photos mirror / Local). Active selection. "Migrate Library…" button (calls `LibraryMigrator`).
- **Editor (coming soon)** — v2-only card. Plain text. No action.

The Settings tab is **non-modal** (NSWindow with `styleMask` including `.resizable`, `.closable`, but not `.miniaturizable`). Selected backend persists via `UserDefaults` (`sync.backend` key, `sync.backendURL` key). Defaults to iCloud Drive.

### 6.4 Deployment target guard

macOS 13 floor kept. `LibraryWatcher` is `#available(macOS 14.0, *)`-gated. Below 14, the Settings tab shows a "Live sync requires macOS 14+" notice and the manual-import UX remains the only path.

## 7. Editor tab — deferred

No toolbar tab in v1. Settings card under §6.3 displays "Editor — coming soon."

## 8. Manual integration — v2

When Manual comes back online (XCode scratch-project recovery is a separate diagnosis), it will use a `RawDeckLibraryKit` Swift package exposing only Foundation:

```swift
public enum RawDeckLibrary {
    public static func writeCapture(_ data: Data, filename: String) throws -> URL
    public static func readXMP(for photoURL: URL) throws -> XMPDocument
    public static func writeXMP(_ doc: XMPDocument, for photoURL: URL) throws
}
```

iOS imports it; the bridge is the file system.

## 9. Plan (where we are)

| Phase | Status | What ships |
|---|---|---|
| 1 | **In progress** | LibraryWatcher + LibraryRoot + iCloud + Google mirror resolvers + InboxSorter + SyncCoordinator + LibraryMigrator + SyncSettings + SettingsWindow |
| 2 | Pending | Wire `LibraryWatcher` into `PhotoStore`; toolbar "Watch on/off" indicator; status bar sync state |
| 3 | Pending | Editor-card in Settings ("coming soon") |
| 4 | Pending | `RawDeckLibraryKit` Swift package for Manual |
| 5 | Pending | XMP `dc:modified` field-level groundwork on every rating write |

## 10. Decisions confirmed by Fin 2026-07-07

| Q | Answer | Notes |
|---|---|---|
| Q1 Editor tab | **(b1)** Settings page card "Editor — coming soon." | No toolbar tab in v1. |
| Q2 Conflict policy | **(a)** File-level last-write-wins. | Ship `dc:modified` now, v2 patches field-level merge. |
| Q3 Sync transport | **(c / local-folder)** Both iCloud Drive + Google Photos mirror. User picks. Settings tab to switch. | Local-folder backend = single code path; switching is `mv` between roots. |
| Q4 Auto-sort | **(a)** Inbox → Library/yyyy/mm/dd/... on scan. | |
| Q5 Storage | **(a)** Paid iCloud tier assumed. | No thin-folder shape in v1. |
