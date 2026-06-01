import SwiftData
import SwiftUI

struct PlaybackControlsView: View {
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings
    var controlSize: PlaybackControlSize = .regular

    var body: some View {
        HStack(spacing: controlSize.spacing) {
            Button {
                Task { await playbackController.previous(context: modelContext) }
            } label: {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("Previous track")
            .disabled(!playbackController.canControlPlayback)
            .buttonStyle(PlaybackControlButtonStyle(controlSize: controlSize, prominence: .secondary))

            Button {
                Task { await primaryPlaybackAction() }
            } label: {
                Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(playbackController.isPlaying ? "Pause" : "Play")
            .disabled(!canUsePrimaryPlaybackAction)
            .buttonStyle(PlaybackControlButtonStyle(controlSize: controlSize, prominence: .primary))

            Button {
                Task { await playbackController.next(settings: settings, context: modelContext) }
            } label: {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("Next track")
            .disabled(!playbackController.canControlPlayback)
            .buttonStyle(PlaybackControlButtonStyle(controlSize: controlSize, prominence: .secondary))
        }
    }

    private var canUsePrimaryPlaybackAction: Bool {
        playbackController.canControlPlayback || defaultPlaybackPlaylist != nil
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

        guard let playlist = defaultPlaybackPlaylist else { return }
        await playbackController.playPlaylist(playlist, settings: settings, context: modelContext)
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: iconSize, weight: iconWeight))
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .opacity(backgroundOpacity(isPressed: configuration.isPressed))
            }
            .overlay {
                Circle()
                    .stroke(.white.opacity(configuration.isPressed ? 0.24 : 0.12), lineWidth: 1)
            }
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

    private func backgroundOpacity(isPressed: Bool) -> Double {
        switch prominence {
        case .primary:
            isPressed ? 0.78 : 1
        case .secondary:
            isPressed ? 0.42 : 0.18
        }
    }
}

#Preview {
    PlaybackControlsView(settings: OverplaySettings())
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
