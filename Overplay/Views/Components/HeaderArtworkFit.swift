import SwiftUI

/// Sizes the dashboard's lead artwork from the list's height and where the
/// artwork starts, before anything is drawn: as large as leaves what must
/// show under it on screen above the mini player (or the screen's bottom),
/// between 120 and 420 points. Worked out while the list settles, hidden,
/// and shown and kept once it has: so it never comes in small and grows
/// (owner request, 2026-10-30).
@MainActor
@Observable
final class HeaderArtworkFit {
    static let maxSide: CGFloat = 420
    static let minSide: CGFloat = 120


    /// The list moves while a screen opens (its first frames put its top
    /// lower than it ends); the size waits this long without a change.
    private static let settleDelay: Duration = .milliseconds(250)

    /// Nil until the list first has a size.
    private(set) var side: CGFloat?
    /// Set once the list has settled: the artwork shows, and its size is kept.
    private(set) var isSettled = false
    @ObservationIgnored private var settling: Task<Void, Never>?

    /// Where the artwork starts, which its size does not move.
    @ObservationIgnored var artworkTop: CGFloat?
    @ObservationIgnored var bottom: CGFloat = 0
    @ObservationIgnored var width: CGFloat = 0
    /// What sits below the artwork and must show, in points.
    @ObservationIgnored var below: CGFloat = 0

    func fit() {
        guard !isSettled, let artworkTop, width > 0, bottom > artworkTop else { return }
        let widest = min(Self.maxSide, width - 32)
        side = min(max(bottom - artworkTop - below, Self.minSide), widest).rounded(.down)
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.isSettled = true
        }
    }
}

extension View {
    /// On the list: works out the artwork's size from its frame once.
    func headerArtworkFit(_ fit: HeaderArtworkFit, below: CGFloat) -> some View {
        modifier(HeaderArtworkFitListModifier(fit: fit, below: below))
    }

    /// Reports where the artwork starts.
    func headerArtworkFitTop(_ fit: HeaderArtworkFit) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
            fit.artworkTop = $0
            fit.fit()
        }
    }
}

private struct HeaderArtworkFitListModifier: ViewModifier {
    @Environment(\.miniPlayerTop) private var miniPlayerTop
    var fit: HeaderArtworkFit
    var below: CGFloat

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: [CGFloat].self) { proxy in
                let frame = proxy.frame(in: .global)
                return [frame.maxY - proxy.safeAreaInsets.bottom, frame.width]
            } action: { values in
                fit.bottom = min(values[0], miniPlayerTop ?? .infinity)
                fit.width = values[1]
                fit.below = below
                fit.fit()
            }
    }
}
