import SwiftUI

struct NowPlayingPaneView: View {
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var artworkTheme: AlbumArtworkTheme?

    var body: some View {
        GeometryReader { proxy in
            let compactLayout = proxy.size.height < 620
            let artworkSize = min(
                proxy.size.width - 56,
                compactLayout ? 170 : 260,
                max(proxy.size.height * (compactLayout ? 0.26 : 0.34), 112)
            )
            let presentation = NowPlayingPresentationFactory.presentation(
                playbackController: playbackController,
                settings: settings
            )
            let activeArtworkTheme = artworkTheme?.isFallback == false ? artworkTheme : nil

            VStack(spacing: compactLayout ? 12 : 18) {
                NowPlayingArtworkView(
                    urlString: playbackController.currentTrack?.artworkURLTemplate,
                    playlistID: playbackController.currentPlaylistID
                )
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 16)

                NowPlayingTrackTextView(
                    presentation: presentation,
                    titleLineLimit: 2,
                    detailLineLimit: 1,
                    artworkTheme: activeArtworkTheme
                )
                NowPlayingProgressView(
                    presentation: presentation,
                    foreground: activeArtworkTheme?.artistName
                )
                TrackHealthStatusView(presentation: presentation, artworkTheme: activeArtworkTheme)
                PlaybackModeControlsView(artworkTheme: activeArtworkTheme)
                TrackActionControlsView(settings: settings, artworkTheme: activeArtworkTheme)

                if let statusMessage = playbackController.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(activeArtworkTheme?.albumName ?? .secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, compactLayout ? 16 : 24)
            .padding(.bottom, compactLayout ? 12 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

#Preview {
    NowPlayingPaneView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"),
        artworkTheme: nil
    )
    .environment(PlaybackController())
}
