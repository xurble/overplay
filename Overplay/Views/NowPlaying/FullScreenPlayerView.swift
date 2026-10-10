import SwiftData
import SwiftUI

/// Now Playing over the whole screen in compact width, opened from the mini
/// player. It is the regular-width column's player; swiping down closes it,
/// and a drag handle under the status bar or Dynamic Island says so.
struct FullScreenPlayerView: View {
    @Environment(\.dismiss) private var dismiss

    var settings: OverplaySettings

    var body: some View {
        NowPlayingColumnView(settings: settings, bottomPadding: 4, transportPillGap: 36)
            .modifier(UnderVerticalBar())
            .overlay(alignment: .top) {
                Capsule()
                    .fill(.secondary)
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .contentShape(.rect)
                    .onTapGesture { dismiss() }
                    .accessibilityElement()
                    .accessibilityLabel("Close Now Playing")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { dismiss() }
            }
            .accessibilityAction(.escape) { dismiss() }
    }
}

#Preview {
    FullScreenPlayerView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay")
    )
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
