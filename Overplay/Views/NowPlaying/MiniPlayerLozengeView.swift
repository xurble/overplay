import SwiftUI

struct MiniPlayerLozengeView: View {
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var expandedProgress: Double

    var body: some View {
        ZStack {
            compactContent
                .opacity(1 - expandedProgress)
                .allowsHitTesting(expandedProgress < 0.5)

            expandedContent
                .opacity(expandedProgress)
                .allowsHitTesting(expandedProgress >= 0.5)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(.smooth(duration: 0.22), value: expandedProgress)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(height: 1)
                .opacity(1 - expandedProgress)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 12) {
            NowPlayingArtworkView(
                urlString: playbackController.currentTrack?.artworkURLTemplate,
                playlistID: playbackController.currentPlaylistID,
                cornerRadius: 10
            )
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(playbackController.currentTrack?.title ?? "Nothing playing")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(playbackController.currentTrack?.artistName ?? "Choose a playlist to start playback")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            PlaybackControlsView(settings: settings, controlSize: .compact)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var expandedContent: some View {
        PlaybackControlsView(settings: settings, controlSize: .regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

#Preview {
    MiniPlayerLozengeView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"),
        expandedProgress: 0
    )
    .environment(PlaybackController())
    .frame(height: 96)
}
