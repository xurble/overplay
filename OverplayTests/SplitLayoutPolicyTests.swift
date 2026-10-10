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
