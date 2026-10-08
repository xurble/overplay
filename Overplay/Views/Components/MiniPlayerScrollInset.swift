import SwiftUI

enum MiniPlayerLayout {
    static let collapsedHeight: CGFloat = 96
    static let scrollContentBottomPadding: CGFloat = collapsedHeight + 24
}

/// Room under scrolling content for the mini player, which only exists where
/// the player is a sheet (compact width).
private struct MiniPlayerScrollContentInset: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: PlayerPlacement(horizontalSizeClass) == .sheet ? MiniPlayerLayout.scrollContentBottomPadding : 0)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func miniPlayerScrollContentInset() -> some View {
        modifier(MiniPlayerScrollContentInset())
    }
}
