import SwiftUI
import Testing
@testable import Overplay

/// The regular-width layout rules (`SplitLayoutPolicy`), at the sizes of
/// real windows: these hold whether or not a simulator rotates. The column
/// widths apply on a Mac; iPad and an open folding phone divide in halves.
@Suite("Split layout policy")
struct SplitLayoutPolicyTests {
    @Test("Portrait on every iPad, and narrower windows, are narrow; landscape is wide", arguments: [
        (CGFloat(744), true), (820, true), (1024, true), (1032, true),   // portrait: mini, Air 11, Pro/Air 13
        (1133, false), (1180, false), (1366, false), (1376, false)      // landscape
    ])
    func narrowThreshold(width: CGFloat, narrow: Bool) {
        #expect(SplitLayoutPolicy.isNarrow(width) == narrow)
    }

    @Test("An unmeasured width is not treated as narrow")
    func unmeasuredWidthIsWide() {
        #expect(!SplitLayoutPolicy.isNarrow(0))
    }

    @Test("Narrow: the player takes 40% and the list 60%")
    func narrowSplit() {
        #expect(SplitLayoutPolicy.playerWidth(for: 1024) == 410)
        #expect(SplitLayoutPolicy.playerWidth(for: 820) == 328)
    }

    @Test("Wide: the player is 380, narrowed to leave the sidebar and list 640, never below 280")
    func wideWidth() {
        #expect(SplitLayoutPolicy.playerWidth(for: 1366) == 380)
        #expect(SplitLayoutPolicy.playerWidth(for: 1100) == 380)
        #expect(SplitLayoutPolicy.playerWidth(for: 0) == 280)
    }

    @Test("Narrow hides the sidebar unless it was slid over the list; wide follows the split view")
    func visibility() {
        #expect(SplitLayoutPolicy.visibility(isNarrow: true, narrowSidebarShown: false, wideVisibility: .all) == .detailOnly)
        #expect(SplitLayoutPolicy.visibility(isNarrow: true, narrowSidebarShown: true, wideVisibility: .detailOnly) == .all)
        #expect(SplitLayoutPolicy.visibility(isNarrow: false, narrowSidebarShown: true, wideVisibility: .all) == .all)
        #expect(SplitLayoutPolicy.visibility(isNarrow: false, narrowSidebarShown: false, wideVisibility: .detailOnly) == .detailOnly)
    }

    @Test("Open as a book, a vertical fold with room on both sides splits list and player")
    func splitsAtVerticalFold() {
        #expect(SplitLayoutPolicy.splitsAtFold(951, foldX: 475))
        #expect(SplitLayoutPolicy.playerWidth(for: 951, foldX: 475) == 476)
        #expect(!SplitLayoutPolicy.splitsAtFold(951, foldX: nil))
        #expect(!SplitLayoutPolicy.splitsAtFold(951, foldX: 200))
        #expect(SplitLayoutPolicy.splitsAtFold(1376, foldX: 688))
        #expect(SplitLayoutPolicy.playerWidth(for: 1376, foldX: 688) == 688)
    }

    @Test("An iPad divides like an open folding phone: side by side when wider than tall, stacked when taller", arguments: [
        (CGSize(width: 1376, height: 1032), CGFloat?(688), CGFloat?.none),   // Pro/Air 13 landscape
        (CGSize(width: 1180, height: 820), 590, nil),                        // Air 11 landscape
        (CGSize(width: 1032, height: 1376), nil, 688),                       // Pro/Air 13 portrait
        (CGSize(width: 744, height: 1133), nil, 567)                         // mini portrait
    ])
    func iPadDividesInHalves(size: CGSize, x: CGFloat?, y: CGFloat?) {
        #expect(SplitLayoutPolicy.dividingX(width: size.width, height: size.height, foldX: nil, foldY: nil, keepsColumns: false) == x)
        #expect(SplitLayoutPolicy.dividingY(width: size.width, height: size.height, foldX: nil, foldY: nil, keepsColumns: false) == y)
    }

    @Test("A folding phone's fold wins over the middle of the window")
    func foldWinsOverMiddle() {
        #expect(SplitLayoutPolicy.dividingX(width: 951, height: 669, foldX: 475, foldY: nil, keepsColumns: false) == 475)
        #expect(SplitLayoutPolicy.dividingY(width: 951, height: 669, foldX: 475, foldY: nil, keepsColumns: false) == nil)
        #expect(SplitLayoutPolicy.dividingY(width: 669, height: 951, foldX: nil, foldY: 476, keepsColumns: false) == 476)
        #expect(SplitLayoutPolicy.dividingX(width: 669, height: 951, foldX: nil, foldY: 476, keepsColumns: false) == nil)
    }

    @Test("A Mac keeps the columns: no dividing line in any window shape")
    func macKeepsColumns() {
        #expect(SplitLayoutPolicy.dividingX(width: 1376, height: 1032, foldX: nil, foldY: nil, keepsColumns: true) == nil)
        #expect(SplitLayoutPolicy.dividingY(width: 1032, height: 1376, foldX: nil, foldY: nil, keepsColumns: true) == nil)
        #expect(SplitLayoutPolicy.playerWidth(for: 1376) == 380)
    }

    @Test("Open in portrait, a horizontal fold with room above and below stacks player over list")
    func stacksAtHorizontalFold() {
        #expect(SplitLayoutPolicy.stacksAtFold(951, foldY: 475))
        #expect(!SplitLayoutPolicy.stacksAtFold(951, foldY: nil))
        #expect(!SplitLayoutPolicy.stacksAtFold(951, foldY: 700))
    }
}

/// Where the player lives, from the size classes.
@Suite("Player placement")
struct PlayerPlacementTests {
    @Test("Compact width or compact height (a phone in landscape) keeps the mini and full-screen player")
    func placement() {
        #expect(PlayerPlacement(.compact, .regular) == .sheet)
        #expect(PlayerPlacement(.regular, .compact) == .sheet)
        #expect(PlayerPlacement(.compact, .compact) == .sheet)
        #expect(PlayerPlacement(.regular, .regular) == .column)
    }

    @Test("Landscape centres the full-screen player: the home indicator's space is matched above")
    func landscapeInsetsAreVerticallyCentred() {
        let insets = FullScreenPlayerView.verticallyCentred(EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59))
        #expect(insets == EdgeInsets(top: 21, leading: 59, bottom: 21, trailing: 59))
    }
}

@Suite("Player card corners")
struct PlayerCardCornerTests {
    @Test("Rounded corners stay rounded through the whole transition")
    func roundedCorners() {
        let radius = { (progress: CGFloat, scale: CGFloat) in
            PlayerCardTransform.minimumCornerRadius(progress: progress, targetHeight: 68, scale: scale, startsSquare: false) * scale
        }

        #expect(radius(0, 1) == 50)
        #expect(radius(0.0001, 1) > 49)
        #expect(radius(0.5, 0.75) == 42)
        #expect(radius(1, 0.5) == 34)
    }

    @Test("The Duo's physical left corners start square for either toolbar side", arguments: [HorizontalEdge.leading, .trailing])
    func duoMask(toolbarEdge: HorizontalEdge) {
        let corners = PlayerCardTransform.maskCorners(progress: 0, targetHeight: 68, scale: 1, verticalBarEdge: toolbarEdge, hasSeenVerticalBar: false, windowCorners: nil, isLandscape: false, isClockwise: true, layoutDirection: .leftToRight)
        #expect(corners == .init(topLeading: .fixed(0), topTrailing: .fixed(50), bottomLeading: .fixed(0), bottomTrailing: .fixed(50)))
    }

    @Test("The physical left stays square in right-to-left layout")
    func duoMaskRightToLeft() {
        let corners = PlayerCardTransform.maskCorners(progress: 0, targetHeight: 68, scale: 1, verticalBarEdge: .trailing, hasSeenVerticalBar: false, windowCorners: nil, isLandscape: false, isClockwise: true, layoutDirection: .rightToLeft)
        // Right-to-left rendering swaps leading and trailing, so the physical
        // left is the trailing edge.
        #expect(corners == .init(topLeading: .fixed(50), topTrailing: .fixed(0), bottomLeading: .fixed(50), bottomTrailing: .fixed(0)))
    }

    @Test("In landscape the square edge rotates to the top or bottom", arguments: [
        (true, true),
        (false, false)
    ])
    func rotatedDuoMask(clockwise: Bool, squareTop: Bool) {
        let contexts: [(HorizontalEdge?, Bool)] = [(nil, true), (.leading, false), (.trailing, false)]
        let top: PlayerCardTransform.Corner = squareTop ? .fixed(0) : .fixed(50)
        let bottom: PlayerCardTransform.Corner = squareTop ? .fixed(50) : .fixed(0)
        for (toolbarEdge, hasSeenBar) in contexts {
            let corners = PlayerCardTransform.maskCorners(progress: 0, targetHeight: 68, scale: 1, verticalBarEdge: toolbarEdge, hasSeenVerticalBar: hasSeenBar, windowCorners: nil, isLandscape: true, isClockwise: clockwise, layoutDirection: .leftToRight)
            #expect(corners == .init(topLeading: top, topTrailing: top, bottomLeading: bottom, bottomTrailing: bottom))
        }
    }

    @Test("The left corners grow continuously into the mini-player capsule")
    func squareCornersGrow() {
        #expect(PlayerCardTransform.minimumCornerRadius(progress: 0, targetHeight: 68, scale: 1, startsSquare: true) == 0)
        #expect(PlayerCardTransform.minimumCornerRadius(progress: 0.5, targetHeight: 68, scale: 0.5, startsSquare: true) == 34)
        #expect(PlayerCardTransform.minimumCornerRadius(progress: 1, targetHeight: 68, scale: 0.5, startsSquare: true) == 68)
        let middle = PlayerCardTransform.maskCorners(progress: 0.5, targetHeight: 68, scale: 1, verticalBarEdge: .leading, hasSeenVerticalBar: false, windowCorners: nil, isLandscape: false, isClockwise: true, layoutDirection: .leftToRight)
        #expect(middle.topLeading == .fixed(17))
    }

    @Test("A split window's corners start at its own radii, not the front screen's square edge")
    func splitWindowMask() {
        // Left of the hinge: tight on the right, the screen's radius on the left.
        let corners = WindowCorners(topLeft: 60, topRight: 4, bottomLeft: 60, bottomRight: 4)
        let mask = PlayerCardTransform.maskCorners(progress: 0, targetHeight: 68, scale: 1, verticalBarEdge: .leading, hasSeenVerticalBar: true, windowCorners: corners, isLandscape: false, isClockwise: true, layoutDirection: .leftToRight)
        #expect(mask == .init(topLeading: .fixed(60), topTrailing: .fixed(4), bottomLeading: .fixed(60), bottomTrailing: .fixed(4)))
        #expect(PlayerCardTransform.cornerRadius(progress: 1, targetHeight: 68, scale: 0.5, startingRadius: 4) == 68)
    }

    @Test("Without a vertical bar, corners stay rounded and progress is clamped")
    func ordinaryMaskAndClamp() {
        let corners = PlayerCardTransform.maskCorners(progress: 0, targetHeight: 68, scale: 1, verticalBarEdge: nil, hasSeenVerticalBar: false, windowCorners: nil, isLandscape: false, isClockwise: true, layoutDirection: .leftToRight)
        #expect(corners.topLeading == .concentric(minimum: 50))
        #expect(corners.bottomTrailing == .concentric(minimum: 50))
        #expect(PlayerCardTransform.minimumCornerRadius(progress: -0.2, targetHeight: 68, scale: 1, startsSquare: false) == 50)
        #expect(PlayerCardTransform.minimumCornerRadius(progress: 2, targetHeight: 68, scale: 0.5, startsSquare: false) == 68)
    }
}
