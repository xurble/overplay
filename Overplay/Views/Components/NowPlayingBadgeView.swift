import SwiftUI

/// Marks the playing song or collection on its artwork: a white arrow on a
/// green glass circle. CarPlay draws its own copy into the art
/// (`CarPlayPlayingBadge`).
struct NowPlayingBadgeView: View {
    var diameter: CGFloat = 22

    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: diameter * 0.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .glassEffect(.regular.tint(.green.opacity(0.85)), in: .circle)
            .accessibilityLabel("Now playing")
    }
}

#Preview {
    HStack(spacing: 20) {
        NowPlayingBadgeView()
        NowPlayingBadgeView(diameter: 28)
    }
    .padding()
    .background(.indigo)
}
