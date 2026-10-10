import SwiftData
import SwiftUI

/// Now Playing over the whole screen in compact width, opened from the mini
/// player. It is the regular-width column's player. A swipe down anywhere
/// moves it with the finger and, past the threshold, closes it; the drag
/// handle under the status bar or Dynamic Island says so, and tapping it
/// closes it too.
///
/// The swipe is Overplay's own: the zoom transition's swipe down missed
/// about half of first attempts and lost to the controls.
struct FullScreenPlayerView: View {
    @Environment(\.dismiss) private var dismiss

    var settings: OverplaySettings

    @State private var artworkTop: CGFloat?
    @State private var safeAreaTop: CGFloat = 0
    @State private var screenHeight: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    /// Set once a drag has moved: down closes, sideways (the volume pill)
    /// is left alone.
    @State private var dragIsDismissal: Bool?

    var body: some View {
        NowPlayingColumnView(
            settings: settings,
            bottomPadding: 4,
            transportPillGap: 36,
            onArtworkTopChange: { artworkTop = $0 }
        )
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeAreaTop = $0 }
        .modifier(UnderVerticalBar())
        .overlay {
            // Laid out against the whole screen, centred across it.
            GeometryReader { proxy in
                dragHandle
                    .position(
                        x: proxy.size.width / 2,
                        y: Self.handleCentreY(artworkTop: artworkTop ?? 96, safeAreaTop: safeAreaTop)
                    )
            }
            .ignoresSafeArea()
        }
        // The margins take the swipe as well as the controls.
        .contentShape(.rect)
        .simultaneousGesture(dismissDrag)
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: {
            screenHeight = $0
        }
        .offset(y: dragOffset)
        .accessibilityAction(.escape) { close() }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                if dragIsDismissal == nil {
                    dragIsDismissal = value.translation.height > abs(value.translation.width)
                }
                guard dragIsDismissal == true else { return }
                dragOffset = max(value.translation.height, 0)
            }
            .onEnded { value in
                defer { dragIsDismissal = nil }
                guard dragIsDismissal == true else { return }
                if Self.closesPlayer(translation: value.translation, predictedEnd: value.predictedEndTranslation) {
                    close()
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    /// Slides the rest of the way down from wherever the drag left it, then
    /// dismisses without a second animation.
    private func close() {
        withAnimation(.smooth(duration: 0.25)) {
            dragOffset = max(screenHeight, 1000)
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }

    /// Down by 80 points, or flicked down past 160, and more down than across.
    static func closesPlayer(translation: CGSize, predictedEnd: CGSize) -> Bool {
        let down = max(translation.height, predictedEnd.height)
        return down > (translation.height > 80 ? 0 : 160) && translation.height > abs(translation.width) * 1.5
    }

    /// Halfway between the top of the screen and the art. Under a Dynamic
    /// Island (a tall top safe area) that would hug the island and sit in the
    /// status bar's touch area, so the handle drops to 16 points below the
    /// safe area instead.
    static func handleCentreY(artworkTop: CGFloat, safeAreaTop: CGFloat) -> CGFloat {
        let halfway = artworkTop / 2
        return safeAreaTop > 40 ? max(halfway, safeAreaTop + 16) : halfway
    }

    private var dragHandle: some View {
        Button {
            close()
        } label: {
            Capsule()
                .fill(.secondary)
                .frame(width: 36, height: 5)
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Now Playing")
    }
}

#Preview {
    FullScreenPlayerView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay")
    )
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
