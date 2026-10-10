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
    /// The mini player, in screen coordinates: closing shrinks into it.
    var miniPlayerFrame: CGRect = .zero

    @State private var artworkTop: CGFloat?
    /// The screen's safe area, read where the player never moves.
    @State private var screenInsets = EdgeInsets()
    @State private var screenSize: CGSize = .zero
    /// 0 open (moved by the drag), 1 shrunk into the mini player.
    @State private var closeProgress: CGFloat = 0
    /// Set once a drag has moved: down closes, sideways (the volume pill)
    /// is left alone.
    @State private var dragIsDismissal: Bool?

    static let coordinateSpace = "full-screen-player"

    var body: some View {
        // Laid out full screen with the safe area as fixed padding: a view
        // drawn moved loses whatever it extended into the safe area, which
        // made the swipe jump and kept the top corners square.
        // Its own view with inputs a drag never changes, so a frame of the
        // drag redraws the card's transform without rebuilding the player.
        FullScreenPlayerContent(settings: settings, screenInsets: screenInsets, artworkTop: $artworkTop)
        .overlay {
            // Centred across the whole screen.
            GeometryReader { proxy in
                dragHandle
                    .position(
                        x: proxy.size.width / 2,
                        y: Self.handleCentreY(artworkTop: artworkTop ?? 96, safeAreaTop: screenInsets.top)
                    )
            }
        }
        // The margins take the swipe as well as the controls.
        .contentShape(.rect)
        .simultaneousGesture(dismissDrag)
        // Measured inside the full-screen layout: outside it, the size
        // leaves out the status bar and home indicator.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screenSize = $0 }
        .modifier(PlayerCardTransform(
            closeProgress: closeProgress,
            screenSize: screenSize,
            miniPlayerFrame: miniPlayerFrame
        ))
        .ignoresSafeArea()
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { screenInsets = $0 }
        .accessibilityAction(.escape) { close() }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                if dragIsDismissal == nil {
                    dragIsDismissal = value.translation.height > abs(value.translation.width)
                }
                guard dragIsDismissal == true else { return }
                // The drag drives the shrink: the card's top follows the
                // finger and reaches the mini player as it becomes it.
                closeProgress = min(max(value.translation.height, 0) / max(miniPlayerTop, 1), 1)
            }
            .onEnded { value in
                defer { dragIsDismissal = nil }
                guard dragIsDismissal == true else { return }
                if Self.closesPlayer(translation: value.translation, predictedEnd: value.predictedEndTranslation) {
                    close()
                } else {
                    withAnimation(.spring(duration: 0.3)) { closeProgress = 0 }
                }
            }
    }

    /// Slides the rest of the way down from wherever the drag left it, then
    /// dismisses without a second animation.
    /// Where the mini player's top is; without a measurement, where it sits.
    private var miniPlayerTop: CGFloat {
        miniPlayerFrame.width > 0 ? miniPlayerFrame.minY : screenSize.height - 100
    }

    /// Shrinks into the mini player from wherever the drag left it, then
    /// dismisses without a second animation.
    private func close() {
        withAnimation(.smooth(duration: 0.35)) {
            closeProgress = 1
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

/// The player inside the card, laid out full screen with the screen's safe
/// area as fixed padding.
private struct FullScreenPlayerContent: View {
    var settings: OverplaySettings
    var screenInsets: EdgeInsets
    @Binding var artworkTop: CGFloat?

    var body: some View {
        NowPlayingColumnView(
            settings: settings,
            bottomPadding: 4,
            transportPillGap: 36,
            onArtworkTopChange: { artworkTop = $0 }
        )
        .modifier(UnderVerticalBar())
        .safeAreaPadding(screenInsets)
        .coordinateSpace(.named(FullScreenPlayerView.coordinateSpace))
    }
}

/// Draws the player as a card shrinking from the full screen into the mini
/// player's frame as `closeProgress` goes from 0 to 1. Its content scales evenly and the
/// card's outline, rounding into the capsule, clips it. It is opaque until it
/// is nearly there, then fades out as it reaches the mini player. Rendering only: layout and the safe area never change.
private struct PlayerCardTransform: ViewModifier, Animatable {
    var closeProgress: CGFloat
    var screenSize: CGSize
    var miniPlayerFrame: CGRect

    var animatableData: CGFloat {
        get { closeProgress }
        set { closeProgress = newValue }
    }

    private static let movingCornerRadius: CGFloat = 50
    /// Opaque for most of the shrink; fades out over the last stretch, just
    /// before it reaches the mini player.
    private static let fadeStart: CGFloat = 0.85

    func body(content: Content) -> some View {
        let width = max(screenSize.width, 1)
        let height = max(screenSize.height, 1)
        let start = CGRect(x: 0, y: 0, width: width, height: height)
        // Without a measured mini player, shrink into where it sits.
        let target = miniPlayerFrame.width > 0
            ? miniPlayerFrame
            : CGRect(x: 12, y: height - 100, width: width - 24, height: MiniPlayerLozengeView.height)
        let t = min(max(closeProgress, 0), 1)
        let card = CGRect(
            x: start.minX + (target.minX - start.minX) * t,
            y: start.minY + (target.minY - start.minY) * t,
            width: start.width + (target.width - start.width) * t,
            height: start.height + (target.height - start.height) * t
        )
        let scale = card.width / width
        let startRadius = t > 0 ? Self.movingCornerRadius : 0
        let radius = startRadius + (target.height / 2 - startRadius) * t
        let opacity = t < Self.fadeStart ? 1 : max(0, (1 - t) / (1 - Self.fadeStart))

        content
            .mask(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius / scale, style: .continuous)
                    .frame(width: card.width / scale, height: card.height / scale)
            }
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: card.minX, y: card.minY)
            .opacity(opacity)
    }
}

#Preview {
    FullScreenPlayerView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay")
    )
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
