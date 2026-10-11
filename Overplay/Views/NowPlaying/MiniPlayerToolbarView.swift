import SwiftData
import SwiftUI

/// The Mac's mini player in the title bar while the Now Playing column is
/// hidden. Tapping the song opens the column. Taller than the bar: it keeps
/// the bar's bottom and right edges and rises towards the window's top. Its
/// background is the sidebar's: plain glass under the same faint wash of the
/// artwork's colour, so it fades with the window as the sidebar does, with the
/// iOS mini player's progress line along the top. Where the window has less
/// room above the bar (full screen), it moves down over the content rather
/// than past the window's top.
struct MiniPlayerToolbarView: View {
    var settings: OverplaySettings
    var onOpen: () -> Void

    static let height: CGFloat = 68
    static let barHeight: CGFloat = 32
    /// Level with the bottom of the bar's other glass.
    private static let drop: CGFloat = 5
    /// Full screen has no room above the bar: it moves down this far.
    private static let fullScreenPushDown: CGFloat = 18

    var body: some View {
        ThemedPlayerHost { artworkTheme, _ in
            MiniPlayerToolbarPill(
                settings: settings,
                artworkTheme: artworkTheme.isFallback ? nil : artworkTheme,
                height: Self.height,
                onOpen: onOpen
            )
        }
        // The bar lays it out at its own height, bottom-aligned, so the extra
        // height rises above the bar instead of pushing it down.
        .frame(height: Self.barHeight, alignment: .bottom)
        .offset(y: Self.drop + (MacWindowState.shared.isFullScreen ? Self.fullScreenPushDown : 0))
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
                    .frame(width: height - 12, height: height - 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackController.nowPlayingDisplayTrack?.title ?? "Nothing playing")
                            .font(.headline)
                        Text(playbackController.nowPlayingDisplayTrack?.artistName ?? "Choose a playlist")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(width: 210, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show Now Playing")
            .accessibilityHint("Opens Now Playing")

            HStack(spacing: 20) {
                PlaybackControlsView(settings: settings, controlSize: .compact, usesSystemGlass: true)
                // The Now Playing toggle, which lives here while the column is
                // hidden, drawn as the skip buttons are.
                Button(action: onOpen) {
                    Image(systemName: "sidebar.trailing")
                }
                .buttonStyle(PlaybackControlButtonStyle(controlSize: .compact, prominence: .secondary,
                                                        artworkTheme: nil, usesSystemGlass: true))
                .accessibilityLabel("Show Now Playing")
                .help("Show Now Playing")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
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
