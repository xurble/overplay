import SwiftData
import SwiftUI

/// The mini player in compact width: a glass bar over the bottom of the
/// screen. Tapping it or swiping it up opens the full-screen player.
struct MiniPlayerLozengeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var onOpen: () -> Void

    static let height: CGFloat = 68

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    NowPlayingArtworkView(
                        urlString: playbackController.nowPlayingDisplayTrack?.artworkURLTemplate,
                        playlistID: playbackController.currentPlaylistContext?.musicPlaylistID,
                        cornerRadius: 10,
                        pixelSize: 128
                    )
                    .frame(width: 50, height: 50)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(playbackController.nowPlayingDisplayTrack?.title ?? "Nothing playing")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(playbackController.nowPlayingDisplayTrack?.artistName ?? "Choose a playlist to start playback")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Now Playing")

            PlaybackControlsView(settings: settings, controlSize: .compact)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: Self.height)
        // Progress along the top edge, coloured as Now Playing's bar.
        .overlay(alignment: .top) { progressLine }
        .clipShape(.capsule)
        .contentShape(.capsule)
        .simultaneousGesture(
            DragGesture(minimumDistance: 16).onEnded { value in
                if value.translation.height < -30 { onOpen() }
            }
        )
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-player")
    }

    private var progressLine: some View {
        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: playbackController,
            settings: settings,
            context: modelContext
        )
        return NowPlayingProgressBar(
            progress: presentation.progress,
            phase: presentation.progressPhase,
            durationSeconds: presentation.durationSeconds,
            isPlaying: presentation.isPlaying,
            trackID: presentation.trackID,
            lineHeight: 3
        )
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

#Preview {
    MiniPlayerLozengeView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"),
        onOpen: {}
    )
    .environment(PlaybackController())
    .padding()
}
