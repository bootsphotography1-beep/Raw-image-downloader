import SwiftUI
import AppKit

/// The Settings window. Hosts three sections: Library, Sync, Editor.
/// Library and Sync are functional in v1; Editor is a "coming soon" card.
///
/// The window is non-modal by design: the user can keep culling photos
/// while adjusting backend settings. We attach an `NSWindow` lifecycle that
/// survives multiple `.commands` invocations — reopening focuses the
/// existing window rather than spawning duplicates.
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var settings: SyncSettings?

    /// Show (or refocus) the Settings window against the given store.
    func show(store: PhotoStore, settings: SyncSettings) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Stash the settings instance so we can refresh the window if a
        // backend change notification fires while it's open.
        self.settings = settings
        let root = SettingsView(store: store, settings: settings)
        let hosting = NSHostingController(rootView: root)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "RawDeck Settings"
        newWindow.contentViewController = hosting
        newWindow.isReleasedWhenClosed = false
        newWindow.center()

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Top-level Settings UI. Three sections in a TabView:
/// - Library: current root + "Show in Finder"
/// - Sync: backend picker + migration status
/// - Editor: "coming soon" card
struct SettingsView: View {

    let store: PhotoStore
    @ObservedObject var settings: SyncSettings
    @State private var migrationStatus: String? = nil
    @State private var migrationInProgress = false

    var body: some View {
        TabView {
            librarySection
                .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
            syncSection
                .tabItem { Label("Sync", systemImage: "icloud") }
            editorSection
                .tabItem { Label("Editor", systemImage: "wand.and.stars") }
        }
        .frame(minWidth: 560, minHeight: 480)
        .padding(20)
    }

    private var librarySection: some View {
        Form {
            Section("Library") {
                if let folder = store.currentFolder {
                    LabeledContent("Current folder") {
                        Text(folder.path)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                        Spacer()
                    }
                } else {
                    Text("No library open. Use Cmd+O to import a folder.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var syncSection: some View {
        Form {
            Section("Sync Backend") {
                Picker("Active backend", selection: Binding(
                    get: { settings.active },
                    set: { newBackend in
                        if migrationInProgress { return }
                        migrate(currentlyActive: settings.active, to: newBackend)
                    }
                )) {
                    ForEach(SyncBackend.allCases) { backend in
                        Text(backend.displayName)
                            .tag(backend)
                            // Disabled when the carrier isn't available
                            // (e.g. iCloud signed out). SwiftUI doesn't
                            // honor `.disabled` on a `Picker`'s row
                            // reliably, but the helper text and the
                            // orange notice below make the state clear.
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.active.helpText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !settings.isAvailable(settings.active) {
                    Label(
                        "This backend isn't reachable right now. Live sync is disabled.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }

            Section("Current Root") {
                if let url = settings.active.resolveRootURL() {
                    LabeledContent("Path") {
                        Text(url.path)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [url, url.appendingPathComponent("Inbox", isDirectory: true)]
                            )
                        }
                        Spacer()
                    }
                } else {
                    Text("Active backend has no resolvable root.")
                        .foregroundStyle(.secondary)
                }
            }

            if let status = migrationStatus {
                Section("Migration") {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
    }

    private var editorSection: some View {
        Form {
            Section {
                Label("Editor — coming soon", systemImage: "wand.and.stars")
                    .font(.title3)
                    .foregroundStyle(.primary)
                Text(
                    "A non-destructive RAW editor will ship in a future " +
                    "version of RawDeck. It will read the same `.xmp` " +
                    "sidecars already on disk, so today's ratings and " +
                    "rejections carry over."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text("v2 — not yet scheduled.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Migration

    private func migrate(currentlyActive from: SyncBackend, to to: SyncBackend) {
        guard from != to else { return }
        guard settings.isAvailable(to) else {
            migrationStatus = "Destination backend isn't available."
            return
        }
        migrationInProgress = true
        migrationStatus = "Migrating from \(from.displayName) → \(to.displayName)…"

        Task.detached(priority: .userInitiated) {
            do {
                try LibraryMigrator.migrate(from: from, to: to) { phase, done, total in
                    Task { @MainActor in
                        migrationStatus = "\(phase): \(done) / \(total)"
                    }
                }
                await MainActor.run {
                    settings.active = to
                    migrationStatus = "Migration complete."
                    migrationInProgress = false
                }
            } catch {
                await MainActor.run {
                    migrationStatus = "Migration failed: \(error.localizedDescription)"
                    migrationInProgress = false
                }
            }
        }
    }
}
