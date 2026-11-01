import SwiftUI

extension EnvironmentValues {
    /// The mini player's top edge, in global coordinates, while it shows.
    @Entry var miniPlayerTop: CGFloat? = nil
    /// Room a Mac's mini player takes at the bottom of the window while it
    /// shows (`SplitAppShell`).
    @Entry var macMiniPlayerInset: CGFloat = 0
}

enum MiniPlayerLayout {
    static let collapsedHeight: CGFloat = 96
    static let scrollContentBottomPadding: CGFloat = collapsedHeight + 24
}

/// Room under scrolling content for the mini player: compact width's, or a
/// Mac's while Now Playing is hidden.
private struct MiniPlayerScrollContentInset: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.macMiniPlayerInset) private var macMiniPlayerInset

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: PlayerPlacement(horizontalSizeClass, verticalSizeClass) == .sheet ? MiniPlayerLayout.scrollContentBottomPadding : macMiniPlayerInset)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func miniPlayerScrollContentInset() -> some View {
        modifier(MiniPlayerScrollContentInset())
    }
}
