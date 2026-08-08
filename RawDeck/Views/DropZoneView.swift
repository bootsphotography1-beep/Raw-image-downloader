import SwiftUI
import UniformTypeIdentifiers

/// The drop zone shown when no folder is loaded.
///
/// Design discipline (v2):
///  - NO centered modal with circle icon + paragraph + "Choose Folder…"
///    button. That's the LLM default empty state.
///  - Pro tools show an empty grid + a one-line hint + the keyboard
///    shortcut that already works.
///  - Layout: a single-line mono command strip pinned to the top of the
///    grid area. The grid IS the empty state.
///
/// On drag-over, the strip outlines with the accent color and the rest of
/// the area shows a subtle scrim so the user knows the drop will be received.
struct DropZoneView: View {
    @EnvironmentObject var store: PhotoStore
    @State private var isTargeted: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            // Subtle scrim under the entire empty area when targeted.
            // Otherwise transparent so the underlying grid surface shows through.
            Rectangle()
                .fill(isTargeted ? RDColor.accentPrimaryDim : Color.clear)
                .ignoresSafeArea()

            // Single-line mono command strip at top of the empty area.
            // Visual: `no folder loaded · drop a DCIM folder · or press ⌘O`
            HStack(spacing: RDSpace.s) {
                Text("no folder loaded")
                    .foregroundStyle(RDColor.textTertiary)
                Text("·")
                    .foregroundStyle(RDColor.hairlineStrong)
                Text("drop a DCIM folder")
                    .foregroundStyle(RDColor.textSecondary)
                Text("·")
                    .foregroundStyle(RDColor.hairlineStrong)
                Text("or press")
                    .foregroundStyle(RDColor.textTertiary)
                Kbd("⌘O")
            }
            .font(RDType.microMono)
            .padding(.horizontal, RDSpace.m)
            .padding(.vertical, RDSpace.s)
            .background(RDColor.surfaceRaised)
            .overlay(
                Rectangle()
                    .fill(isTargeted ? RDColor.accentPrimary : RDColor.hairlineStrong)
                    .frame(height: 1),
                alignment: .bottom
            )
            .padding(.top, RDSpace.l)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
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
}

/// Minimal monospace key-cap label. Mirrors the `kbd` HTML element rendered
/// in our web design. Used in the toolbar and the drop zone strip to show
/// keyboard shortcuts inline with prose.
private struct Kbd: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(RDType.microMono)
            .foregroundStyle(RDColor.textPrimary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RDColor.surfaceElevated)
            .overlay(
                Rectangle()
                    .strokeBorder(RDColor.hairlineStrong, lineWidth: 0.5)
            )
    }
}