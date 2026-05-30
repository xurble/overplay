import SwiftUI

enum MiniPlayerLayout {
    static let collapsedHeight: CGFloat = 96
    static let scrollContentBottomPadding: CGFloat = collapsedHeight + 24
}

extension View {
    func miniPlayerScrollContentInset() -> some View {
        safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: MiniPlayerLayout.scrollContentBottomPadding)
                .allowsHitTesting(false)
        }
    }
}
