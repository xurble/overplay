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
    var settings: OverplaySettings
    /// The mini player, in screen coordinates: closing shrinks into it.
    var miniPlayerFrame: CGRect = .zero
    /// A swipe up on the mini player that opened this player, if any.
    var openDrag: PlayerOpenDrag?
    /// Removes the player once it has shrunk into the mini player.
    var onClose: () -> Void

    @Environment(\.shellNavigator) private var shellNavigator
    @State private var artworkTop: CGFloat?
    @State private var screenSize: CGSize = .zero
    /// 0 open, 1 shrunk into the mini player. It starts there: opening
    /// grows the player out of the mini player, the close in reverse.
    @State private var closeProgress: CGFloat
    @State private var hasOpened: Bool

    static let coordinateSpace = "full-screen-player"
    /// The spacing under and above the volume pill, shared with an unfolded
    /// phone's column so the player looks the same open and closed.
    static let bottomPadding: CGFloat = 4
    static let transportPillGap: CGFloat = 36

    /// `opensInPlace`: already open, without growing out of the mini player,
    /// as when folding a phone brings back the player it was showing.
    init(
        settings: OverplaySettings,
        miniPlayerFrame: CGRect = .zero,
        openDrag: PlayerOpenDrag? = nil,
        opensInPlace: Bool = false,
        onClose: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.miniPlayerFrame = miniPlayerFrame
        self.openDrag = openDrag
        self.onClose = onClose
        _closeProgress = State(initialValue: opensInPlace ? 0 : 1)
        _hasOpened = State(initialValue: opensInPlace)
    }

    var body: some View {
        // The screen's size and safe area, read where the player never moves
        // and in the same layout pass: measured a frame later, the player
        // laid out without them first and then jumped up as a screen
        // activated.
        // The reader stays inside the safe area, so it reports the insets;
        // the card extends past them to the whole screen.
        GeometryReader { screen in
            let insets = screen.safeAreaInsets
            card(
                screenInsets: insets,
                screenSize: CGSize(
                    width: screen.size.width + insets.leading + insets.trailing,
                    height: screen.size.height + insets.top + insets.bottom
                )
            )
            .ignoresSafeArea()
        }
        .accessibilityAction(.escape) { close() }
        // Something was opened from here: shrink back into the mini player.
        .onChange(of: shellNavigator?.request) { close() }
    }

    private func card(screenInsets: EdgeInsets, screenSize: CGSize) -> some View {
        // Laid out full screen with the safe area as fixed padding: a view
        // drawn moved loses whatever it extended into the safe area, which
        // made the swipe jump and kept the top corners square.
        // Its own view with inputs a drag never changes, so a frame of the
        // drag redraws the card's transform without rebuilding the player.
        FullScreenPlayerContent(
            settings: settings,
            screenInsets: screenInsets,
            isLandscape: screenSize.width > screenSize.height,
            artworkTop: $artworkTop
        )
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
        .gesture(dismissPan)
        // Measured inside the full-screen layout: outside it, the size
        // leaves out the status bar and home indicator.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            self.screenSize = size
            // Grow once the screen is measured, so the first frame is right;
            // a swipe up opens it with the finger instead.
            guard !hasOpened, size.width > 0 else { return }
            hasOpened = true
            if let progress = openDrag?.progress {
                closeProgress = progress
            } else {
                withAnimation(.smooth(duration: 0.385)) { closeProgress = 0 }
            }
        }
        .onChange(of: openDrag?.progress) { _, progress in
            guard let progress, hasOpened else { return }
            closeProgress = progress
        }
        .onChange(of: openDrag?.outcome) { _, outcome in
            guard let outcome else { return }
            openDrag?.outcome = nil
            switch outcome {
            case .open: withAnimation(.smooth(duration: 0.33)) { closeProgress = 0 }
            case .cancel: close()
            }
        }
        .modifier(PlayerCardTransform(
            closeProgress: closeProgress,
            screenSize: screenSize,
            miniPlayerFrame: miniPlayerFrame
        ))
        .modifier(UnderVerticalBar(adjustsSafeArea: false))
    }

    /// The card follows the finger down and, past the threshold, closes;
    /// otherwise, or if the system takes the touch, it springs back open.
    private var dismissPan: PlayerDismissPan {
        PlayerDismissPan { translation in
            // The drag drives the shrink: the card's top follows the finger
            // and reaches the mini player as it becomes it.
            closeProgress = min(max(translation.height, 0) / max(miniPlayerTop, 1), 1)
        } onEnded: { translation, predictedEnd in
            if Self.closesPlayer(translation: translation, predictedEnd: predictedEnd) {
                close()
            } else {
                withAnimation(.spring(duration: 0.33)) { closeProgress = 0 }
            }
        } onCancelled: {
            withAnimation(.spring(duration: 0.33)) { closeProgress = 0 }
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
        withAnimation(.smooth(duration: 0.385)) {
            closeProgress = 1
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { onClose() }
        }
    }

    /// Landscape has a home indicator below and nothing above: the same
    /// space at the top centres the player on the screen.
    static func verticallyCentred(_ insets: EdgeInsets) -> EdgeInsets {
        let vertical = max(insets.top, insets.bottom)
        return EdgeInsets(top: vertical, leading: insets.leading, bottom: vertical, trailing: insets.trailing)
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
/// area as fixed padding. In landscape the art and the controls sit side by
/// side, the art on the edge that was the phone's top in portrait, so the
/// two halves turn in place with the phone.
private struct FullScreenPlayerContent: View {
    var settings: OverplaySettings
    var screenInsets: EdgeInsets
    var isLandscape: Bool
    @Binding var artworkTop: CGFloat?

    var body: some View {
        NowPlayingColumnView(
            settings: settings,
            bottomPadding: FullScreenPlayerView.bottomPadding,
            transportPillGap: FullScreenPlayerView.transportPillGap,
            onArtworkTopChange: { artworkTop = $0 },
            isSideBySide: isLandscape,
            artworkOnTrailing: isLandscape && PhoneTurn.shared.isClockwise
        )
        .modifier(UnderVerticalBar())
        .safeAreaPadding(isLandscape ? FullScreenPlayerView.verticallyCentred(screenInsets) : screenInsets)
        .coordinateSpace(.named(FullScreenPlayerView.coordinateSpace))
    }
}

/// Draws the player as a card shrinking from the full screen into the mini
/// player's frame as `closeProgress` goes from 0 to 1. Its content scales evenly and the
/// card's outline, rounding into the capsule, clips it. It is opaque until it
/// is nearly there, then fades out as it reaches the mini player. Rendering only: layout and the safe area never change.
struct PlayerCardTransform: ViewModifier, Animatable {
    var closeProgress: CGFloat
    var screenSize: CGSize
    var miniPlayerFrame: CGRect

    var animatableData: CGFloat {
        get { closeProgress }
        set { closeProgress = newValue }
    }

    /// Opaque for most of the shrink; fades out over the last stretch, just
    /// before it reaches the mini player.
    private static let fadeStart: CGFloat = 0.7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerVerticalBarEdge) private var verticalBarEdge
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var hasSeenVerticalBar = false
    /// Nil while the window fills its screen.
    @State private var windowCorners: WindowCorners?

    /// A split window on a Duo's inner screen has a vertical bar too, but
    /// none of the front screen's square edge.
    static func fillsScreen(_ size: CGSize) -> Bool {
        let window = [size.width, size.height].sorted()
        return UIApplication.shared.connectedScenes.contains { scene in
            guard let bounds = (scene as? UIWindowScene)?.screen.bounds.size else { return false }
            let screen = [bounds.width, bounds.height].sorted()
            return abs(screen[0] - window[0]) < 1 && abs(screen[1] - window[1]) < 1
        }
    }

    static func minimumCornerRadius(progress: CGFloat, targetHeight: CGFloat, scale: CGFloat, startsSquare: Bool) -> CGFloat {
        cornerRadius(progress: progress, targetHeight: targetHeight, scale: scale, startingRadius: startsSquare ? 0 : 50)
    }

    static func cornerRadius(progress: CGFloat, targetHeight: CGFloat, scale: CGFloat, startingRadius: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return (startingRadius * (1 - t) + targetHeight / 2 * t) / scale
    }

    /// A corner of the card's mask: a fixed radius, or concentric with the
    /// screen's corner and no tighter than the radius.
    enum Corner: Equatable {
        case fixed(CGFloat)
        case concentric(minimum: CGFloat)

        var style: Edge.Corner.Style {
            switch self {
            case .fixed(let radius): .fixed(radius)
            case .concentric(let minimum): .concentric(minimum: .fixed(minimum))
            }
        }
    }

    struct Corners: Equatable {
        var topLeading: Corner
        var topTrailing: Corner
        var bottomLeading: Corner
        var bottomTrailing: Corner
    }

    static func maskShape(progress: CGFloat, targetHeight: CGFloat, scale: CGFloat, verticalBarEdge: HorizontalEdge?, hasSeenVerticalBar: Bool, windowCorners: WindowCorners?, isLandscape: Bool, isClockwise: Bool, layoutDirection: LayoutDirection) -> ConcentricRectangle {
        let corners = maskCorners(progress: progress, targetHeight: targetHeight, scale: scale, verticalBarEdge: verticalBarEdge, hasSeenVerticalBar: hasSeenVerticalBar, windowCorners: windowCorners, isLandscape: isLandscape, isClockwise: isClockwise, layoutDirection: layoutDirection)
        return ConcentricRectangle(
            topLeadingCorner: corners.topLeading.style,
            topTrailingCorner: corners.topTrailing.style,
            bottomLeadingCorner: corners.bottomLeading.style,
            bottomTrailingCorner: corners.bottomTrailing.style
        )
    }

    /// The Duo's square portrait-left edge moves to the top on a clockwise
    /// turn and to the bottom on a counterclockwise turn.
    static func maskCorners(progress: CGFloat, targetHeight: CGFloat, scale: CGFloat, verticalBarEdge: HorizontalEdge?, hasSeenVerticalBar: Bool, windowCorners: WindowCorners?, isLandscape: Bool, isClockwise: Bool, layoutDirection: LayoutDirection) -> Corners {
        if let windowCorners {
            // Each corner starts as the window's own: tighter at the hinge.
            func corner(_ radius: CGFloat) -> Corner {
                .fixed(cornerRadius(progress: progress, targetHeight: targetHeight, scale: scale, startingRadius: radius))
            }
            return corners(
                topLeft: corner(windowCorners.topLeft),
                topRight: corner(windowCorners.topRight),
                bottomLeft: corner(windowCorners.bottomLeft),
                bottomRight: corner(windowCorners.bottomRight),
                layoutDirection: layoutDirection
            )
        }
        let isDuoFront = verticalBarEdge != nil || hasSeenVerticalBar
        let roundedRadius = minimumCornerRadius(progress: progress, targetHeight: targetHeight, scale: scale, startsSquare: false)
        let rounded: Corner = isDuoFront ? .fixed(roundedRadius) : .concentric(minimum: roundedRadius)
        let squared: Corner = .fixed(minimumCornerRadius(progress: progress, targetHeight: targetHeight, scale: scale, startsSquare: true))
        return corners(
            topLeft: isDuoFront && (!isLandscape || isClockwise) ? squared : rounded,
            topRight: isDuoFront && isLandscape && isClockwise ? squared : rounded,
            bottomLeft: isDuoFront && (!isLandscape || !isClockwise) ? squared : rounded,
            bottomRight: isDuoFront && isLandscape && !isClockwise ? squared : rounded,
            layoutDirection: layoutDirection
        )
    }

    private static func corners(topLeft: Corner, topRight: Corner, bottomLeft: Corner, bottomRight: Corner, layoutDirection: LayoutDirection) -> Corners {
        let isLeftToRight = layoutDirection == .leftToRight
        return Corners(
            topLeading: isLeftToRight ? topLeft : topRight,
            topTrailing: isLeftToRight ? topRight : topLeft,
            bottomLeading: isLeftToRight ? bottomLeft : bottomRight,
            bottomTrailing: isLeftToRight ? bottomRight : bottomLeft
        )
    }

    func body(content: Content) -> some View {
        Group {
            if reduceMotion {
                // No zoom: the player fades, and a swipe down fades it with the finger.
                content.opacity(1 - min(max(closeProgress, 0), 1))
            } else {
                moving(content)
            }
        }
        .onChange(of: verticalBarEdge, initial: true) { _, edge in
            if edge != nil { hasSeenVerticalBar = true }
        }
        .onChange(of: screenSize, initial: true) { _, size in
            windowCorners = Self.fillsScreen(size) ? nil : WindowCorners.measure()
        }
    }

    @ViewBuilder
    private func moving(_ content: Content) -> some View {
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
        let opacity = t < Self.fadeStart ? 1 : max(0, (1 - t) / (1 - Self.fadeStart))

        content
            .mask(alignment: .topLeading) {
                Self.maskShape(
                    progress: t,
                    targetHeight: target.height,
                    scale: scale,
                    verticalBarEdge: verticalBarEdge,
                    hasSeenVerticalBar: hasSeenVerticalBar,
                    windowCorners: windowCorners,
                    isLandscape: screenSize.width > screenSize.height,
                    isClockwise: PhoneTurn.shared.isClockwise,
                    layoutDirection: layoutDirection
                )
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
