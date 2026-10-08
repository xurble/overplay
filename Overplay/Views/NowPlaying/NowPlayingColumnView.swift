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
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("now-playing-column")
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

