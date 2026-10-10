import SwiftUI

/// The regular-width layout's rules, from the window's width alone (never
/// the device type or orientation).
enum SplitLayoutPolicy {
    /// Below this width (portrait on any iPad, a narrower window, likely an
    /// unfolded phone) three side-by-side columns are too narrow to use.
    static let narrowWidth: CGFloat = 1100

    static func isNarrow(_ width: CGFloat) -> Bool {
        width > 0 && width < narrowWidth
    }

    /// Narrow: 40% of the width, the list taking the other 60%. Wide: a
    /// fixed 380 beside the sidebar and list, narrowed only when they would
    /// have less than 640, never below 280. A vertical fold across a narrow
    /// layout (iPhone Duo open as a book) puts the list on one half and the
    /// player on the other, while each keeps at least 280.
    static func playerWidth(for width: CGFloat, foldX: CGFloat? = nil) -> CGFloat {
        guard isNarrow(width) else { return min(380, max(280, width - 640)) }
        if let foldX, foldX >= 280, width - foldX >= 280 { return (width - foldX).rounded() }
        return (width * 0.4).rounded()
    }

    /// Narrow: the sidebar shows only while slid over the list. Wide: the
    /// split view's own choice. Derived on every read, so a rotation never
    /// leaves a stale value behind.
    static func visibility(
        isNarrow: Bool,
        narrowSidebarShown: Bool,
        wideVisibility: NavigationSplitViewVisibility
    ) -> NavigationSplitViewVisibility {
        isNarrow ? (narrowSidebarShown ? .all : .detailOnly) : wideVisibility
    }
}
