import SwiftData
import SwiftUI

/// The full player as a column beside the regular-width layout: the same
/// pane, transport and glass-over-art background as the expanded sheet, but
/// always beside the list instead of covering it.
struct NowPlayingColumnView: View {
    var settings: OverplaySettings

    var body: some View {
        ThemedPlayerHost { artworkTheme, applyRefreshedTheme in
            VStack(spacing: 0) {
                NowPlayingPaneView(
                    settings: settings,
                    artworkTheme: artworkTheme,
                    onArtworkThemeUpdated: applyRefreshedTheme
                )
                PlaybackControlsView(
                    settings: settings,
                    controlSize: .regular,
                    artworkTheme: artworkTheme.isFallback ? nil : artworkTheme
                )
                .padding(.bottom, 28)
            }
            .background {
                Group {
                    if artworkTheme.isFallback {
                        Rectangle().fill(.background)
                    } else {
                        PlayerGlassArtBackground(tint: artworkTheme.background)
                    }
                }
                .ignoresSafeArea()
            }
        }
    }
}

#Preview {
    NowPlayingColumnView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay")
    )
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}

/// The draggable edge between the list and the Now Playing column.
struct NowPlayingColumnDivider: View {
    static let minimumListWidth: CGFloat = 320

    @Binding var width: Double
    var range: ClosedRange<CGFloat>

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .overlay {
                Capsule()
                    .fill(.secondary)
                    .frame(width: 5, height: 44)
            }
            .frame(width: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = widthAtDragStart ?? min(max(CGFloat(width), range.lowerBound), range.upperBound)
                        widthAtDragStart = start
                        // Dragging left widens the column.
                        width = Double(min(max(start - value.translation.width, range.lowerBound), range.upperBound))
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Now Playing width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 40 : -40
                width = Double(min(max(CGFloat(width + step), range.lowerBound), range.upperBound))
            }
    }
}

#Preview("Divider") {
    NowPlayingColumnDivider(width: .constant(380), range: 280...700)
        .frame(height: 300)
}
