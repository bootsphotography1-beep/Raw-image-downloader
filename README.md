# RawDeck

A fast, minimal RAW culling app for macOS. Drag a folder of RAW photos in, star-rate, reject, and send the keepers to **Pixelmator Pro** for editing.

Built natively in SwiftUI for photographers who don't want to pay for PhotoMechanic.

## Features

- 🖱️ **Drag-and-drop import** — drop a folder of RAWs, get instant previews
- 🔦 **Lightbox viewer** — hover an image and press `Space` to open it full-screen with a thumbnail strip of every photo along the bottom. Navigate with `←` / `→`. Press `Esc` (or `Space` again) to close.
- 🔃 **Sort & filter** — Lightroom-style. The toolbar has a Sort dropdown (`Filename`, `Rating ↓`, `Rating ↑`). Below it, a filter bar lets you set a rating floor (★1+, ★2+, …, ★5 only) and toggle rejected-photo visibility. Arrows in the lightbox respect the filter.
- ⭐ **5-star rating** — press `1`–`5` to rate, `0` to clear. Works in both grid and lightbox modes; in the lightbox the number keys always rate the photo you're currently viewing.
- ❌ **Quick reject** — press `X` to mark a photo as rejected
- 🗑️ **Trash or remove** — press `Delete` to send selected (or all rejected) photos to the macOS Trash (recoverable)
- 🎨 **Open in Pixelmator Pro** — press `⌘⇧O` or double-click to open the selected photo(s) in Pixelmator Pro. Edits save back to the source folder automatically.
- 🔍 **Reveal in Finder** — see the original file location (`⌘⇧R`)
- ⚡ **Fast previews** — uses macOS's built-in RAW decoder (CoreImage/ImageIO) for instant thumbnails. No third-party libraries.

## Supported RAW formats

Any format macOS can decode natively: **CR3, CR2** (Canon), **ARW, SR2** (Sony), **NEF, NRW** (Nikon), **RAF** (Fujifilm), **DNG** (Adobe), **ORF** (Olympus), **RW2** (Panasonic), **PEF** (Pentax), **3FR** (Hasselblad), and more. If your camera's RAW format works in macOS Preview, it works here.

## Prerequisites

- **macOS 13.0 (Ventura) or later**
- **Xcode 15 or later**
- **Git** — `xcode-select --install` (ships with macOS Command Line Tools)
- **GitHub CLI** — `brew install gh` then `gh auth login`
- **Pixelmator Pro** *(optional)* — for the "Open in Pixelmator" feature. Without it, files open in your default RAW handler.
- A GitHub account with push access to `bootsphotography1-beep`

## Installation

### Option A — Use the one-shot setup script (recommended)

From your Mac, in the `rawdeck/` directory:

```bash
chmod +x setup.sh        # one-time: make the script executable (Windows line endings may have stripped the +x bit)
./setup.sh
```

The script will:
1. Verify `gh`, `git`, and `gh auth` are set up
2. `git init` the project (if needed)
3. Create the GitHub repo at `bootsphotography1-beep/Raw-image-downloader`
4. Push the initial commit

### Option B — Manual setup

```bash
# 1. Clone
git clone https://github.com/bootsphotography1-beep/Raw-image-downloader.git
cd rawdeck

# 2. Open in Xcode
open RawDeck.xcodeproj
```

### First run in Xcode

1. Select the `RawDeck` scheme (top-left, next to the play button)
2. **Set a signing team** — click the project in the navigator → `RawDeck` target → Signing & Capabilities → pick your "Personal Team" from the Team dropdown. Without a team, Xcode will refuse to build.
3. Press `⌘R` to build and run

To run the app **outside** Xcode (as a standalone `.app`):

1. In Xcode: `Product → Archive`
2. In the Organizer: `Distribute App → Copy App`
3. Drag `RawDeck.app` to your Applications folder

## Usage

| Shortcut | Action |
|---|---|
| `1` – `5` | Set star rating (1 = weak, 5 = keeper). Targets the lightbox photo if open, else the selection. |
| `0` | Clear star rating |
| `X` | Toggle reject flag |
| `Space` *(hovering an image)* | Open lightbox on that photo |
| `Space` *(lightbox open)* | Close lightbox |
| `←` / `→` | Previous / next photo (lightbox only) |
| `Esc` | Close lightbox (or clear selection in grid) |
| `Delete` | Move selected (or all rejected) to Trash. In lightbox mode, trashes the current photo. |
| `⌘A` | Select all |
| `Esc` *(grid)* | Clear selection |
| `⌘O` | Import folder |
| `⌘⇧O` | Open selection in Pixelmator Pro |
| `⌘⇧R` | Reveal in Finder |
| Double-click | Open single photo in Pixelmator Pro |
| Right-click | Context menu (Open Lightbox / Open in Pixelmator / Reveal in Finder / Trash) |

### Workflow

1. **Connect your SD card or SSD.** A card reader will mount it as `/Volumes/...`.
2. **Drag the `DCIM/100CANON` (or similar) folder into the RawDeck window** (or press `⌘O`).
3. **Browse the grid.** Use `1`–`5` to rate keepers, `X` to reject duds.
4. **Hover a photo and press `Space`** to open the lightbox. Use `←` / `→` to flick through quickly; press `1`–`5` to rate as you go. Press `Esc` or `Space` to close.
5. **Press `Delete`** to trash all rejected photos (or select specific photos first, then `Delete` to trash just those).
6. **Select the keepers you want to edit** (or press `⌘A` for all rated 3+).
7. **Press `⌘⇧O`** to open them in Pixelmator Pro. Edit, save, done — your edits save back to the original RAW file's location.

## Important notes

- **No library, no DB.** When you close RawDeck, all your ratings vanish. This is intentional — the app is a session tool, not a DAM (Digital Asset Manager). Use it for culling, then export keepers to whatever DAM you prefer.
- **Trash, not delete.** Photos are moved to the macOS Trash (recoverable for 30 days by default). If you actually want to permanently delete, empty the Trash.
- **Edits in Pixelmator Pro save back to the source folder.** That means the `DCIM/100CANON/IMG_0001.CR3` file on your card will be modified when you save in Pixelmator. If you want to preserve the original RAW, **copy the folder to your Mac first** before importing into RawDeck.
- **Sandboxed app.** RawDeck uses App Sandbox (default for new SwiftUI apps). It can only read folders you explicitly select in the file picker or drop on the window. It can launch Pixelmator Pro and Finder to reveal files.

## Architecture

- **`RawDeckApp.swift`** — app entry point, scene, command menu, hidden key-button helper
- **`Views/ContentView.swift`** — main window: drop zone OR toolbar + filter bar + grid + status bar; hosts the no-modifier keyboard shortcuts (rating, lightbox open/close, arrow-nav, esc)
- **`Views/LightboxView.swift`** — full-screen photo viewer overlay: large photo + bottom thumbnail strip + close button. Auto-scrolls the strip to keep the current photo in view.
- **`Views/FilterBarView.swift`** — Lightroom-style filter strip between the toolbar and grid: rating floor (★1+ … ★5 only), reject toggle, "Showing N of M" status.
- **`PhotoStore.swift`** — `@MainActor`-isolated state store (selected IDs, photos array, import/load/select operations). Owns the `lightboxPhotoID` and `hoveredPhotoID` state plus `openLightbox`, `closeLightbox`, `lightboxStep`, and `loadPreview` helpers. Holds `sortMode` / `ratingFilter` / `hideRejected` and exposes `visiblePhotos` (filter-then-sort). `SortMode` enum (filename / rating ↓ / rating ↑) lives in the same file.
- **`Models/Photo.swift`** — single photo: file URL, star rating, reject flag, lazy-loaded thumbnail + 1600px preview
- **`Services/ThumbnailService.swift`** — uses `CGImageSourceCreateThumbnailAtIndex` to generate previews from RAW files. Two sizes: 512px (grid thumbnail) and 1600px (lightbox preview).
- **`Services/ImportService.swift`** — recursive folder scan, RAW file filter, natural sort
- **`Services/ExternalAppService.swift`** — "Open in Pixelmator" via `NSWorkspace`, "Move to Trash" via `FileManager.trashItem`
- **`Views/DropZoneView.swift`** — empty state, drag-and-drop target
- **`Views/PhotoGridView.swift`** — `LazyVGrid` of `ThumbnailCell`s
- **`Views/ThumbnailCell.swift`** — single thumbnail + star row + reject X; tracks hover state for the spacebar-open-lightbox gesture; double-click → Pixelmator
- **`Views/ToolbarView.swift`** — top action bar

## License

MIT — see `LICENSE` for the full text. You own this code, do whatever you want with it.
