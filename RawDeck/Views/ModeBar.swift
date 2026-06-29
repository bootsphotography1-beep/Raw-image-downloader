import SwiftUI

/// Segmented mode picker shown at the very top of the RawDeck window.
///
/// Lets the user switch between Library mode (the original RawDeck
/// feature: import, cull, rate) and Presetter mode (paste a reference
/// image, derive a Camera Raw preset, export).
///
/// Implementation notes:
/// - Reads/writes `store.mode` (a `@Published AppMode` on PhotoStore).
/// - Uses `.pickerStyle(.segmented)` for the native macOS segmented
///   control look. Each segment shows an icon + label, matching the
///   standard "tabs at the top" pattern that the user requested.
/// - The Picker is "live" — switching modes immediately swaps the main
///   content area. There is no animation; mode switches are functional
///   transitions, not decorative ones.
struct ModeBar: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $store.mode) {
                ForEach(AppMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()  // the segmented control shows icon+text, no separate label needed
            .fixedSize()

            Spacer()

            // Right side: contextual info per mode. Currently a no-op
            // placeholder so the bar has visual weight. Could later
            // show "Library: 247 photos" or "Presetter: <image name>"
            // depending on mode.
            modeStatus
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var modeStatus: some View {
        switch store.mode {
        case .library:
            if store.photos.isEmpty {
                Text("No folder imported")
            } else {
                Text("\(store.photos.count) photos")
            }
        case .presetter:
            Text("Drop or paste a reference image")
        }
    }
}