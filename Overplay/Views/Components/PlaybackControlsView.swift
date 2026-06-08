import SwiftData
import SwiftUI

struct PlaybackControlsView: View {
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings
    var controlSize: PlaybackControlSize = .regular
    var artworkTheme: AlbumArtworkTheme? = nil

    var body: some View {
        HStack(spacing: controlSize.spacing) {
            Button {
                Task { await playbackController.previous(context: modelContext) }
            } label: {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("Previous track")
            .disabled(!playbackController.canControlPlayback)
            .buttonStyle(PlaybackControlButtonStyle(
                controlSize: controlSize,
                prominence: .secondary,
                artworkTheme: artworkTheme
            ))

            Button {
                Task { await primaryPlaybackAction() }
            } label: {
                Image(systemName: controlsPresentation.primarySystemImage)
            }
            .accessibilityLabel(controlsPresentation.primaryAccessibilityLabel)
            .disabled(!canUsePrimaryPlaybackAction)
            .buttonStyle(PlaybackControlButtonStyle(
                controlSize: controlSize,
                prominence: .primary,
                artworkTheme: artworkTheme
            ))

            Button {
                Task { await playbackController.next(settings: settings, context: modelContext) }
            } label: {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("Next track")
            .disabled(!playbackController.canControlPlayback)
            .buttonStyle(PlaybackControlButtonStyle(
                controlSize: controlSize,
                prominence: .secondary,
                artworkTheme: artworkTheme
            ))
        }
    }

    private var canUsePrimaryPlaybackAction: Bool {
        playbackController.canControlPlayback || restoredPlaybackTarget != nil || defaultPlaybackPlaylist != nil
    }

    private var controlsPresentation: PlaybackControlsPresentation {
        PlaybackControlsPresentation(
            isPlaying: playbackController.isPlaying,
            shuffleEnabled: playbackController.shuffleEnabled,
            repeatEnabled: playbackController.repeatEnabled
        )
    }

    private var defaultPlaybackPlaylist: PlaylistRecord? {
        if let selectedPlaylistID = settings.selectedPlaylistID,
           let playlist = playlists.first(where: { $0.musicPlaylistID == selectedPlaylistID && $0.isActive }) {
            return playlist
        }

        return playlists.first { $0.role == .oneTruePlaylist && $0.isActive }
    }

    private func primaryPlaybackAction() async {
        if playbackController.canControlPlayback {
            await playbackController.togglePlayPause(context: modelContext)
            return
        }

        if let restoredPlayback = restoredPlaybackTarget {
            await playbackController.playPlaylist(
                restoredPlayback.playlist,
                startingAt: restoredPlayback.track,
                settings: settings,
                context: modelContext
            )
            return
        }

        guard let playlist = defaultPlaybackPlaylist else { return }
        await playbackController.playPlaylist(playlist, settings: settings, context: modelContext)
    }

    private var restoredPlaybackTarget: (playlist: PlaylistRecord, track: TrackRecord)? {
        guard let currentPlaylistID = playbackController.currentPlaylistID,
              let playlist = playlists.first(where: { $0.musicPlaylistID == currentPlaylistID && $0.isActive }) else {
            return nil
        }

        if let item = playbackController.currentPlaylistItem,
           let track = try? TrackRecordRepository.track(id: item.trackID, in: modelContext) {
            return (playlist, track)
        }

        if let musicItemID = playbackController.currentTrack?.id,
           let track = try? TrackRecordRepository.track(musicItemID: musicItemID, in: modelContext) {
            return (playlist, track)
        }

        return nil
    }
}

enum PlaybackControlSize {
    case compact
    case regular

    var spacing: CGFloat {
        switch self {
        case .compact:
            14
        case .regular:
            22
        }
    }

    var primaryButtonSize: CGFloat {
        switch self {
        case .compact:
            42
        case .regular:
            68
        }
    }

    var primaryIconSize: CGFloat {
        switch self {
        case .compact:
            18
        case .regular:
            28
        }
    }

    var secondaryIconSize: CGFloat {
        switch self {
        case .compact:
            16
        case .regular:
            24
        }
    }

    var secondaryButtonSize: CGFloat {
        switch self {
        case .compact:
            34
        case .regular:
            48
        }
    }
}

private struct PlaybackControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    enum Prominence {
        case primary
        case secondary
    }

    var controlSize: PlaybackControlSize
    var prominence: Prominence
    var artworkTheme: AlbumArtworkTheme?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: iconSize, weight: iconWeight))
            .foregroundStyle(foregroundStyle)
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
            .playbackControlBackdrop(
                palette,
                prominence: glassProminence,
                isPressed: configuration.isPressed,
                fallbackOpacity: backgroundOpacity(isPressed: configuration.isPressed)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
            .animation(.smooth(duration: 0.16), value: isEnabled)
    }

    private var buttonSize: CGFloat {
        switch prominence {
        case .primary:
            controlSize.primaryButtonSize
        case .secondary:
            controlSize.secondaryButtonSize
        }
    }

    private var iconSize: CGFloat {
        switch prominence {
        case .primary:
            controlSize.primaryIconSize
        case .secondary:
            controlSize.secondaryIconSize
        }
    }

    private var iconWeight: Font.Weight {
        prominence == .primary ? .bold : .semibold
    }

    private var palette: FullScreenPlayerControlPalette? {
        artworkTheme.flatMap(FullScreenPlayerControlPalette.init(theme:))
    }

    private var foregroundStyle: Color {
        guard let palette else {
            return isEnabled ? .primary : .secondary.opacity(0.55)
        }

        guard isEnabled else {
            return palette.disabledForeground
        }

        switch prominence {
        case .primary:
            return palette.foreground
        case .secondary:
            return palette.secondaryForeground
        }
    }

    private var glassProminence: FullScreenPlayerControlProminence {
        prominence == .primary ? .primary : .secondary
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        switch prominence {
        case .primary:
            isPressed ? 0.78 : 1
        case .secondary:
            isPressed ? 0.42 : 0.18
        }
    }
}

private struct PlaybackControlBackdropModifier: ViewModifier {
    var palette: FullScreenPlayerControlPalette?
    var prominence: FullScreenPlayerControlProminence
    var isPressed: Bool
    var fallbackOpacity: Double

    func body(content: Content) -> some View {
        if let palette {
            content.fullScreenPlayerGlassBackdrop(
                palette,
                shape: Circle(),
                prominence: prominence,
                isPressed: isPressed
            )
        } else {
            content
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(fallbackOpacity)
                }
                .overlay {
                    Circle()
                        .stroke(.white.opacity(isPressed ? 0.24 : 0.12), lineWidth: 1)
                }
        }
    }
}

private extension View {
    func playbackControlBackdrop(
        _ palette: FullScreenPlayerControlPalette?,
        prominence: FullScreenPlayerControlProminence,
        isPressed: Bool,
        fallbackOpacity: Double
    ) -> some View {
        modifier(PlaybackControlBackdropModifier(
            palette: palette,
            prominence: prominence,
            isPressed: isPressed,
            fallbackOpacity: fallbackOpacity
        ))
    }
}

#Preview {
    PlaybackControlsView(settings: OverplaySettings())
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
