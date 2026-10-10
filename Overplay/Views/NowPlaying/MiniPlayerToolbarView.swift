import SwiftData
import SwiftUI

/// The Mac's mini player in the title bar while the Now Playing column is
/// hidden. Tapping the song opens the column. Taller than the bar: it keeps
/// the bar's bottom and right edges and rises towards the window's top. Its
/// glass takes the artwork's colour, as the big player does, with the iOS
/// mini player's progress line along the top.
struct MiniPlayerToolbarView: View {
    var settings: OverplaySettings
    var onOpen: () -> Void

    static let height: CGFloat = 68
    static let barHeight: CGFloat = 32

    var body: some View {
        ThemedPlayerHost { artworkTheme, _ in
            MiniPlayerToolbarPill(
                settings: settings,
                artworkTheme: artworkTheme.isFallback ? nil : artworkTheme,
                onOpen: onOpen
            )
        }
        // The bar lays it out at its own height, bottom-aligned, so the extra
        // height rises above the bar instead of pushing it down.
        .frame(height: Self.barHeight, alignment: .bottom)
        // Level with the bottom of the bar's other glass.
        .offset(y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar-mini-player")
    }
}

private struct MiniPlayerToolbarPill: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    /// Nil until the artwork's colours are known: plain glass meanwhile.
    var artworkTheme: AlbumArtworkTheme?
    var onOpen: () -> Void

    private static let progressLineHeight: CGFloat = 3

    /// Where the capsule's curve shows half the line's height, as in the iOS
    /// mini player.
    private static var progressLineEndInset: CGFloat {
        let radius = MiniPlayerToolbarView.height / 2
        let depth = radius - progressLineHeight / 2
        return radius - (radius * radius - depth * depth).squareRoot()
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    NowPlayingArtworkView(
                        urlString: playbackController.nowPlayingDisplayTrack?.artworkURLTemplate,
                        playlistID: playbackController.currentPlaylistContext?.musicPlaylistID,
                        cornerRadius: 14,
                        pixelSize: 128
                    )
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackController.nowPlayingDisplayTrack?.title ?? "Nothing playing")
                            .font(.headline)
                            .foregroundStyle(artworkTheme?.trackTitle ?? .primary)
                        Text(playbackController.nowPlayingDisplayTrack?.artistName ?? "Choose a playlist")
                            .font(.subheadline)
                            .foregroundStyle(artworkTheme.map { AnyShapeStyle($0.artistName) } ?? AnyShapeStyle(.secondary))
                    }
                    .lineLimit(1)
                    .frame(width: 210, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show Now Playing")
            .accessibilityHint("Opens Now Playing")

            PlaybackControlsView(settings: settings, controlSize: .compact, artworkTheme: artworkTheme, usesSystemGlass: true)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: MiniPlayerToolbarView.height)
        .overlay(alignment: .top) { progressLine }
        .clipShape(.capsule)
        .contentShape(.capsule)
        .glassEffect(.regular.tint(artworkTheme?.background), in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
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
    MiniPlayerToolbarView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"),
        onOpen: {}
    )
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
    .padding()
}
