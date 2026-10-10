import SwiftData
import SwiftUI

/// Now Playing over the whole screen in compact width, opened from the mini
/// player. It is the regular-width column's player; swiping down closes it,
/// and a drag handle under the status bar or Dynamic Island says so.
struct FullScreenPlayerView: View {
    @Environment(\.dismiss) private var dismiss

    var settings: OverplaySettings

    @State private var artworkTop: CGFloat?

    var body: some View {
        NowPlayingColumnView(
            settings: settings,
            bottomPadding: 4,
            transportPillGap: 36,
            onArtworkTopChange: { artworkTop = $0 }
        )
        .modifier(UnderVerticalBar())
        // The zoom transition's own swipe down loses to the controls' and the
        // volume pill's touch handling. This one runs alongside them: a
        // clearly downward swipe closes the player from anywhere.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global).onEnded { value in
                if Self.closesPlayer(translation: value.translation, predictedEnd: value.predictedEndTranslation) {
                    dismiss()
                }
            }
        )
        .overlay {
            // Laid out against the whole screen: centred across it, and
            // halfway between its top edge and the top of the art.
            GeometryReader { proxy in
                dragHandle
                    .position(x: proxy.size.width / 2, y: (artworkTop ?? 48) / 2)
            }
            .ignoresSafeArea()
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    /// Down by 80 points, or flicked down past 160, and more down than across.
    static func closesPlayer(translation: CGSize, predictedEnd: CGSize) -> Bool {
        let down = max(translation.height, predictedEnd.height)
        return down > (translation.height > 80 ? 0 : 160) && translation.height > abs(translation.width) * 1.5
    }

    private var dragHandle: some View {
        Capsule()
            .fill(.secondary)
            .frame(width: 36, height: 5)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .contentShape(.rect)
            .onTapGesture { dismiss() }
            .accessibilityElement()
            .accessibilityLabel("Close Now Playing")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { dismiss() }
    }
}

#Preview {
    FullScreenPlayerView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay")
    )
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
