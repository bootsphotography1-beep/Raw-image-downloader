import SwiftUI
import UniformTypeIdentifiers

/// The drop zone shown when no folder is loaded. Big dashed border, large
/// icon, "Drop a folder of RAW photos here" text. Also a "Choose Folder…"
/// button as a backup for users who don't know they can drag.
struct DropZoneView: View {
    @EnvironmentObject var store: PhotoStore
    @State private var isTargeted: Bool = false

    var body: some View {
        ZStack {
            // Background: subtle paper-tone (matches editorial design language)
            Color(NSColor.windowBackgroundColor)

            VStack(spacing: 24) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)
                    .foregroundColor(isTargeted ? .accentColor : .secondary)

                VStack(spacing: 8) {
                    Text("Drop a folder of RAW photos here")
                        .font(.title2)
                        .fontWeight(.medium)

                    Text("CR3, ARW, NEF, RAF, DNG, ORF, RW2 and more")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                Button {
                    pickFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding(48)
            .frame(maxWidth: 560)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                    )
            )
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // `NSItemProvider.loadItem(forTypeIdentifier:)` is the most reliable
        // way to get a URL out of a drag-and-drop on macOS — the provider
        // hands us the item as `Data` (the bookmark/file-url blob) or, in
        // some configurations, an already-coerced `URL`. We try the
        // fast-path (URL directly) first and fall back to decoding the
        // data representation.
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL? = {
                if let url = item as? URL { return url }
                if let data = item as? Data {
                    return URL(dataRepresentation: data, relativeTo: nil)
                }
                if let str = item as? String { return URL(string: str) }
                return nil
            }()
            guard let url = url else { return }
            // loadItem's completion runs on a background queue — hop to
            // main before touching the store (PhotoStore is @MainActor).
            Task { @MainActor in
                store.importFolder(url)
            }
        }
        return true
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a folder of RAW photos"
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            store.importFolder(url)
        }
    }
}