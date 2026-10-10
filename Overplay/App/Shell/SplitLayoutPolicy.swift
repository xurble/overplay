import SwiftUI

/// The regular-width layout's rules. A Mac keeps sidebar, list and player
/// columns, chosen by the window's width. Elsewhere (iPad, an open folding
/// phone) the list and player take a half each, divided by the fold or,
/// without one, the middle of the window.
enum SplitLayoutPolicy {
    /// A Mac (Catalyst, or the iPad app on a Mac) keeps the columns. UI tests
    /// on the iPad simulator ask for them with `macLayoutArgument`.
    static var keepsColumns: Bool {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains(macLayoutArgument) { return true }
#endif
        return ProcessInfo.processInfo.isMacCatalystApp
    }

    static let macLayoutArgument = "-OverplayMacLayout"

    /// Where the list and player divide side by side: a vertical fold or,
    /// without a fold, the middle of a window wider than tall. Nil with
    /// columns, or where they stack instead.
    static func dividingX(width: CGFloat, height: CGFloat, foldX: CGFloat?, foldY: CGFloat?, keepsColumns: Bool) -> CGFloat? {
        if let foldX { return foldX }
        guard !keepsColumns, foldY == nil, width > 0, width >= height else { return nil }
        return (width / 2).rounded()
    }

    /// Where the player (above) and list (below) divide: a horizontal fold
    /// or, without a fold, the middle of a window taller than wide.
    static func dividingY(width: CGFloat, height: CGFloat, foldX: CGFloat?, foldY: CGFloat?, keepsColumns: Bool) -> CGFloat? {
        if let foldY { return foldY }
        guard !keepsColumns, foldX == nil, height > width else { return nil }
        return (height / 2).rounded()
    }

    /// Below this width (portrait on any iPad, a narrower window, likely an
    /// unfolded phone) three side-by-side columns are too narrow to use.
    static let narrowWidth: CGFloat = 1100

    static func isNarrow(_ width: CGFloat) -> Bool {
        width > 0 && width < narrowWidth
    }

    /// A dividing line (iPhone Duo open as a book, an iPad) puts the list on
    /// one side and the player on the other, while each keeps at least 280.
    /// Columns: narrow, 40% of the width, the list taking the other 60%;
    /// wide, a fixed 380 beside the sidebar and list, narrowed only when they
    /// would have less than 640, never below 280.
    static func playerWidth(for width: CGFloat, foldX: CGFloat? = nil) -> CGFloat {
        if let foldX, splitsAtFold(width, foldX: foldX) { return (width - foldX).rounded() }
        guard isNarrow(width) else { return min(380, max(280, width - 640)) }
        return (width * 0.4).rounded()
    }

    /// Whether the list and player sit on either side of a dividing line
    /// (iPhone Duo open as a book, an iPad wider than tall). The player then
    /// always keeps its half.
    static func splitsAtFold(_ width: CGFloat, foldX: CGFloat?) -> Bool {
        guard let foldX else { return false }
        return foldX >= 280 && width - foldX >= 280
    }

    /// Whether the player sits above a dividing line and the list below it
    /// (iPhone Duo open in portrait, an iPad taller than wide). The player
    /// then always keeps its half.
    static func stacksAtFold(_ height: CGFloat, foldY: CGFloat?) -> Bool {
        guard let foldY else { return false }
        return foldY >= 280 && height - foldY >= 280
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
