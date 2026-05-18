import SwiftData
import SwiftUI

struct PlaybackControlsView: View {
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext

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

            Button {
                Task { await playbackController.togglePlayPause() }
            } label: {
                Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: controlSize.primaryIconSize, weight: .bold))
                    .frame(width: controlSize.primaryButtonSize, height: controlSize.primaryButtonSize)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(playbackController.isPlaying ? "Pause" : "Play")
            .disabled(!playbackController.canControlPlayback)

            Button {
                Task { await playbackController.next(settings: settings, context: modelContext) }
            } label: {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("Next track")
            .disabled(!playbackController.canControlPlayback)
        }
        .font(.system(size: controlSize.secondaryIconSize, weight: .semibold))
        .buttonStyle(.plain)
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
}

#Preview {
    PlaybackControlsView(settings: OverplaySettings())
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
