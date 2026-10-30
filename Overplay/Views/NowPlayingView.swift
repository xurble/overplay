import SwiftData
import SwiftUI

struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext

    var settings: OverplaySettings

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: 24) {
                    NowPlayingArtworkView(
                        urlString: playbackController.currentTrack?.artworkURLTemplate,
                        playlistID: playbackController.currentPlaylistContext?.musicPlaylistID
                    )
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 18)

                    NowPlayingTrackTextView(presentation: nowPlayingPresentation, offersCollectionMenu: true)
                    NowPlayingProgressView(presentation: nowPlayingPresentation)
                    TrackPlaybackFactsView(presentation: nowPlayingPresentation)
                        .overlay(alignment: .top) {
                            PlayingFromView()
                                .alignmentGuide(.top) { $0[.bottom] - 8 }
                        }
                    PlaybackControlsView(settings: settings)
                    secondaryControls(settings: settings)

                    PlaybackFailureRetryView()
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
        NowPlayingActionButtonsView(settings: settings)
    }

    private var nowPlayingPresentation: NowPlayingPresentation {
        NowPlayingPresentationFactory.presentation(
            playbackController: playbackController,
            settings: settings,
            context: modelContext
        )
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
