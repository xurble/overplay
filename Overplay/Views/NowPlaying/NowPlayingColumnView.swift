import SwiftData
import SwiftUI

/// The full player: a column beside the regular-width layout, and the
/// full-screen player in compact width.
struct NowPlayingColumnView: View {
    var settings: OverplaySettings
    /// Space under the last control. Full screen sits it just above the
    /// home indicator, leaving more room for the art.
    var bottomPadding: CGFloat = 28
    /// Space between the transport and the volume pill.
    var transportPillGap: CGFloat = 16

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
                .padding(.bottom, AudioOutputPillView.isAvailable ? transportPillGap : bottomPadding)
                if AudioOutputPillView.isAvailable {
                    AudioOutputPillView(artworkTheme: artworkTheme)
                        .padding(.bottom, bottomPadding)
                }
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

