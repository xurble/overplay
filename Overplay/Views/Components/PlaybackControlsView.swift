import SwiftData
import SwiftUI

struct PlaybackControlsView: View {
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext

    var settings: OverplaySettings

    var body: some View {
        HStack(spacing: 22) {
            Button {
                Task { await playbackController.previous(context: modelContext) }
            } label: {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("Previous track")

            Button {
                Task { await playbackController.togglePlayPause() }
            } label: {
                Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .frame(width: 68, height: 68)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(playbackController.isPlaying ? "Pause" : "Play")

            Button {
                Task { await playbackController.next(settings: settings, context: modelContext) }
            } label: {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("Next track")
        }
        .font(.system(size: 24, weight: .semibold))
        .buttonStyle(.plain)
    }
}

#Preview {
    PlaybackControlsView(settings: OverplaySettings())
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
