import SwiftUI
import Testing
@testable import Overplay

/// The regular-width layout rules (`SplitLayoutPolicy`), at the widths of
/// real windows: these hold whether or not a simulator rotates.
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
}
