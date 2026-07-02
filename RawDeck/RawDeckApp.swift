import SwiftUI
import AppKit

@main
struct RawDeckApp: App {
    @StateObject private var store = PhotoStore()
    @StateObject private var colorwayParser = ColorwayParserModel()

    var body: some Scene {
        Window("RawDeck", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(colorwayParser)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Replace the default "New" with mode-aware imports.
            // Cmd+O: Library → Import Folder, Colorway Parser → Open Image.
            // Disabled when the action doesn't apply to the current mode.
            CommandGroup(replacing: .newItem) {
                Button("Import Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Import"
                    if panel.runModal() == .OK, let url = panel.url {
                        store.importFolder(url)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store.mode != .library)

                Button("Open Image…") {
                    colorwayParser.openImageViaPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store.mode != .colorwayParser)
            }

            // Custom "Photo" menu — Library-mode actions (Pixelmator,
            // Reveal, Export, Select All, Trash). Disabled in Colorway
            // Parser mode because they don't apply to a single reference image.
            CommandMenu("Photo") {
                Button("Open in Pixelmator Pro") {
                    store.openSelectionInPixelmator()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(store.mode != .library || store.photos.isEmpty)

                Button("Reveal in Finder") {
                    store.revealSelectionInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.mode != .library || store.photos.isEmpty)

                ExportCommand(store: store)

                                SaveRatingsCommand(store: store)

                                Divider()

                Button("Select All") {
                    store.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(store.mode != .library)

                Button("Clear Selection") {
                    store.deselectAll()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(store.mode != .library)

                Divider()

                Button("Move to Trash") {
                    _ = store.trashSelection()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(store.mode != .library)
            }

            // Colorway-mode menu — export actions. Cmd+E for .xmp,
            // Cmd+Shift+E for the recreation sheet. Disabled until an
            // image is loaded and analyzed.
            CommandMenu("Colorway") {
                Button("Export Preset (.xmp)…") {
                    colorwayParser.exportXMP()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.mode != .colorwayParser || !colorwayParser.canExport)

                Button("Export Recreation Sheet…") {
                    colorwayParser.exportRecreationSheet()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.mode != .colorwayParser || !colorwayParser.canExport)

                Divider()

                Button("Clear") {
                    colorwayParser.reset()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(store.mode != .colorwayParser || colorwayParser.displayImage == nil)
            }
        }
    }
}

/// Batch export selected photos as their ORIGINAL files (.cr3, .nef,
/// .arw, .dng, etc.) into a user-chosen destination folder. Shows a
/// folder picker, runs the copies off-main, and reports a summary in
/// an alert. See `PhotoStore.exportSelection` for the selection rules
/// (selected photos, or all visible photos if nothing is selected).
///
/// Declared at file scope (outside `RawDeckApp`) so it can be
/// referenced as a menu item inside the `.commands { CommandMenu }`
/// builder — Commands syntax doesn't accept inline `Button` declarations
/// with arbitrary modifiers, but it happily accepts a nested View.
///
/// **Why `store` is passed in instead of fetched via `@EnvironmentObject`:**
/// `ExportCommand` is instantiated from `CommandMenu` inside the
/// Scene's `.commands { ... }` modifier. The `.environmentObject(store)`
/// modifier lives on the `Window` (the View tree), but **Commands are
/// not descendants of the Window's view hierarchy** — they live in a
/// separate SwiftUI environment. So `@EnvironmentObject var store` here
/// resolves to nil and SwiftUI's runtime crashes with:
///
///     Fatal error: No ObservableObject of type PhotoStore found.
///     A View.environmentObject(_:) for PhotoStore may be missing
///     as an ancestor of this view.
///
/// Passing `store` directly as a constructor parameter captures the
/// `@StateObject` reference from `RawDeckApp` (which is in scope here)
/// instead, sidestepping the broken environment chain. This matches the
/// pattern used by the sibling `Button(...) { store.foo() }` menu
/// items, which capture `store` directly from `RawDeckApp`'s StateObject.
struct ExportCommand: View {
    @ObservedObject var store: PhotoStore
    var body: some View {
        Button("Export Selected as Originals…") {
            store.exportSelection()
        }
        .keyboardShortcut("e", modifiers: [.command, .option])
        .disabled(store.mode != .library || store.photos.isEmpty)
        .help("Copy selected photos to a folder of your choice, preserving the original .cr3 / .nef / .arw / .dng bytes (no re-encoding)")
    }
}

/// Save Ratings & Eject menu command. Writes XMP sidecars next to
/// every photo with a rating/reject flag, then asks the user to
/// confirm before ejecting the volume so they can remove the SD card.
///
/// Sidecars are placed alongside the original .cr3 (e.g.
/// `IMG_1234.CR3` → `IMG_1234.xmp`) and use the standard XMP
/// `xmp:Rating` and `xmp:Reject` tags that every RAW-aware app
/// (Lightroom, Apple Photos, Photo Mechanic, Capture One) reads on
/// import — so when the user re-inserts the card, their ratings
/// carry over without modifying the original RAW bytes.
struct SaveRatingsCommand: View {
    @ObservedObject var store: PhotoStore
    /// Pending eject confirmation: non-nil while the alert is showing.
    /// The value is the closure that, when invoked with `true`, runs
    /// the actual save-and-eject.
    @State private var pendingConfirmation: ((Bool) -> Void)? = nil

    var body: some View {
        Button("Save Ratings & Eject…") {
            store.saveRatingsAndEject { proceed in
                // Stash the decision callback in @State so the alert
                // can fire it when the user clicks Save / Cancel.
                pendingConfirmation = proceed
            }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(store.mode != .library || store.photos.isEmpty)
        .help("Write your star ratings and reject flags as .xmp sidecars (Lightroom/Photos/Photo Mechanic compatible), then eject the SD card so you can remove it safely")
        .alert("Save ratings and eject?", isPresented: Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )) {
            Button("Save & Eject", role: .destructive) {
                pendingConfirmation?(true)
                pendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                pendingConfirmation?(false)
                pendingConfirmation = nil
            }
        } message: {
            Text("This writes .xmp sidecar files next to every rated photo, then ejects the card volume. The original RAW files are not modified.")
        }
    }
}

/// Hidden zero-size button used to host a no-modifier keyboard shortcut
/// (e.g. `1`-`5` for ratings, `X` for reject). Using a `Button` with
/// `.keyboardShortcut` is the supported SwiftUI way to bind a shortcut
/// to an arbitrary action.
struct HiddenKeyButton: View {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void

    var body: some View {
        Button("") { action() }
            .keyboardShortcut(key, modifiers: modifiers)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}