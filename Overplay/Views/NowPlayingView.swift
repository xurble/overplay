import SwiftData
import SwiftUI

struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: 24) {
                    NowPlayingArtworkView(
                        urlString: playbackController.currentTrack?.artworkURLTemplate,
                        playlistID: playbackController.currentPlaylistID,
                        healthStatus: NowPlayingPresentationFactory.healthStatus(
                            playbackController: playbackController,
                            settings: settings
                        )
                    )
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 18)

                    NowPlayingTrackTextView(presentation: nowPlayingPresentation)
                    NowPlayingProgressView(presentation: nowPlayingPresentation, tint: .white)
                    TrackHealthStatusView(presentation: nowPlayingPresentation)
                    PlaybackControlsView(settings: settings)
                    secondaryControls(settings: settings)

                    if let statusMessage = playbackController.statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .miniPlayerScrollContentInset()
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var background: some View {
        LinearGradient(
            colors: [.black, .indigo.opacity(0.75), .teal.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(.ultraThinMaterial)
    }

    private func secondaryControls(settings: OverplaySettings) -> some View {
        VStack(spacing: 12) {
            PlaybackModeControlsView()
            TrackActionControlsView(settings: settings)
        }
    }

    private var nowPlayingPresentation: NowPlayingPresentation {
        NowPlayingPresentationFactory.presentation(playbackController: playbackController, settings: settings)
    }
}

#Preview {
    NavigationStack {
        NowPlayingView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .environment(AppRuntime.shared)
    .modelContainer(PreviewContainer.make())
}
