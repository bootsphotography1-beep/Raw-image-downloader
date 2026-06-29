import SwiftUI
import AppKit

@main
struct RawDeckApp: App {
    @StateObject private var store = PhotoStore()
    @StateObject private var presetter = PresetterModel()

    var body: some Scene {
        Window("RawDeck", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(presetter)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Replace the default "New" with mode-aware imports.
            // Cmd+O: Library → Import Folder, Presetter → Open Image.
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
                    presetter.openImageViaPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store.mode != .presetter)
            }

            // Custom "Photo" menu — Library-mode actions (Pixelmator,
            // Reveal, Select All, Trash). Disabled in Presetter mode
            // because they don't apply to a single reference image.
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

            // Presetter-mode menu — export actions. Cmd+E for .xmp,
            // Cmd+Shift+E for the recreation sheet. Disabled until an
            // image is loaded and analyzed.
            CommandMenu("Presetter") {
                Button("Export Preset (.xmp)…") {
                    presetter.exportXMP()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.mode != .presetter || !presetter.canExport)

                Button("Export Recreation Sheet…") {
                    presetter.exportRecreationSheet()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.mode != .presetter || !presetter.canExport)

                Divider()

                Button("Clear") {
                    presetter.reset()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(store.mode != .presetter || presetter.displayImage == nil)
            }
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