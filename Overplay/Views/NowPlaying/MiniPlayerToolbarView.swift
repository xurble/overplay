import SwiftData
import SwiftUI

/// The Mac's mini player at the bottom of the window while the Now Playing
/// column is hidden (owner request, 2026-10-31). Tapping the song opens the
/// column; the toolbar keeps the column's button. Its background is the
/// sidebar's: plain glass under the same faint wash of the artwork's colour,
/// so it fades with the window as the sidebar does, with the iOS mini
/// player's progress line along the top.
struct MiniPlayerToolbarView: View {
    var settings: OverplaySettings
    var onOpen: () -> Void

    // Chosen when the Mac drew at 77% (`SplitLayoutPolicy.macScale`).
    static let height: CGFloat = 76 * SplitLayoutPolicy.macScale
    /// The art and buttons keep their size as the pill's padding grows.
    static let artworkSide: CGFloat = 56 * SplitLayoutPolicy.macScale

    var body: some View {
        ThemedPlayerHost { artworkTheme, _ in
            MiniPlayerToolbarPill(
                settings: settings,
                artworkTheme: artworkTheme.isFallback ? nil : artworkTheme,
                height: Self.height,
                onOpen: onOpen
            )
        }
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
    var height: CGFloat
    var onOpen: () -> Void

    private static let progressLineHeight: CGFloat = 3

    /// Where the capsule's curve shows half the line's height, as in the iOS
    /// mini player.
    private var progressLineEndInset: CGFloat {
        let radius = height / 2
        let depth = radius - Self.progressLineHeight / 2
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
                    .frame(width: MiniPlayerToolbarView.artworkSide, height: MiniPlayerToolbarView.artworkSide)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackController.nowPlayingDisplayTrack?.title ?? "Nothing playing")
                            .font(.headline)
                        Text(playbackController.nowPlayingDisplayTrack?.artistName ?? "Choose a playlist")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(width: 210 * SplitLayoutPolicy.macScale, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show Now Playing")
            .accessibilityHint("Opens Now Playing")

            HStack(spacing: 0) {
                PlaybackControlsView(settings: settings, controlSize: .compact, usesSystemGlass: true)
                // Three buttons' room, then shuffle, repeat and the song's
                // moves as Now Playing has them, the size of the skip buttons
                // (owner request, 2026-10-31).
                Color.clear.frame(width: 3 * PlaybackControlSize.compact.secondaryButtonSize, height: 1)
                NowPlayingActionButtonsView(settings: settings, compactSize: .compact)
            }
        }
        .padding(.horizontal, 18 * SplitLayoutPolicy.macScale)
        .frame(height: height)
        .overlay(alignment: .top) { progressLine }
        // The tint is drawn, not the glass's: a glass tint drops out when the
        // window loses focus, the sidebar's wash does not.
        .background {
            if let artworkTheme {
                artworkTheme.background.opacity(SidebarArtworkTint.opacity)
            }
        }
        .clipShape(.capsule)
        .contentShape(.capsule)
        .glassEffect(.regular, in: .capsule)
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
            lineEndInset: progressLineEndInset
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
