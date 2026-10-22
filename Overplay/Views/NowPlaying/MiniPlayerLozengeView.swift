import SwiftData
import SwiftUI

/// The mini player in compact width: a glass bar over the bottom of the
/// screen. Tapping it or swiping it up opens the full-screen player.
struct MiniPlayerLozengeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var onOpen: () -> Void
    /// A swipe up, as it moves (upward distance) and on release.
    var onOpenDragChanged: (CGFloat) -> Void = { _ in }
    var onOpenDragEnded: (DragGesture.Value) -> Void = { _ in }

    static let height: CGFloat = 68
    private static let progressLineHeight: CGFloat = 3

    /// Where the capsule's curve shows half the line's height: progress maps
    /// from here to the same point on the right, so the first second already
    /// marks the curve and the end meets the right one.
    private static var progressLineEndInset: CGFloat {
        let radius = height / 2
        let depth = radius - progressLineHeight / 2
        return radius - (radius * radius - depth * depth).squareRoot()
    }

    /// How strongly the glass takes the playing track's theme colour.
    private static let tintOpacity = 0.8

    var body: some View {
        ThemedPlayerHost { artworkTheme, _ in
            lozenge(theme: artworkTheme.isFallback ? nil : artworkTheme)
        }
    }

    /// Plain glass until the track's colours are known, then glass tinted
    /// with its theme colour and the text and controls in the theme's colours.
    private func lozenge(theme: AlbumArtworkTheme?) -> some View {
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
                            .foregroundStyle(theme?.trackTitle ?? .primary)
                            .lineLimit(1)
                        Text(playbackController.nowPlayingDisplayTrack?.artistName ?? "Choose a playlist to start playback")
                            .font(.caption)
                            .foregroundStyle(theme?.artistName ?? .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Now Playing")

            PlaybackControlsView(settings: settings, controlSize: .compact, artworkTheme: theme)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: Self.height)
        // Progress along the top edge, coloured as Now Playing's bar.
        .overlay(alignment: .top) { progressLine }
        .clipShape(.capsule)
        .contentShape(.capsule)
        .simultaneousGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { value in onOpenDragChanged(-value.translation.height) }
                .onEnded { value in onOpenDragEnded(value) }
        )
        // Not interactive: its press bulge would leave the player, which
        // grows from and shrinks into this frame, a size out of step.
        .glassEffect(.regular.tint(theme?.background.opacity(Self.tintOpacity)), in: .capsule)
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
            lineHeight: Self.progressLineHeight,
            lineEndInset: Self.progressLineEndInset
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
