import SwiftUI

struct NowPlayingPaneView: View {
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings

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
                    detailLineLimit: 1
                )
                NowPlayingProgressView(presentation: presentation, tint: nil)
                TrackHealthStatusView(presentation: presentation)
                PlaybackModeControlsView()
                TrackActionControlsView(settings: settings)

                if let statusMessage = playbackController.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay")
    )
    .environment(PlaybackController())
}
