import SwiftData
import SwiftUI

/// The shared playback failure's Try Again action (`PLAY-014`). It runs the
/// same user-initiated recovery as Play on every other surface.
struct PlaybackFailureRetryView: View {
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if playbackController.playbackFailure != nil {
            Button {
                Task { await playbackController.play(context: modelContext) }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
        }
    }
}

#Preview {
    PlaybackFailureRetryView()
        .modelContainer(PreviewContainer.make())
        .environment(PlaybackController())
}
