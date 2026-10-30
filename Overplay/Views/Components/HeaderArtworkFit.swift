import SwiftUI

/// Fits a list's header artwork as the dashboard fits its lead artwork: as
/// large as leaves the header, Shuffle and Play and the first two songs on
/// screen above the mini player (or the screen's bottom), up to a
/// collection's artwork size (owner request, 2026-10-30). Measured only at
/// rest at the top, and only while the header shows.
@MainActor
@Observable
final class HeaderArtworkFit {
    static let maxSide: CGFloat = 420
    static let minSide: CGFloat = 120
    /// The gap between the second song and the mini player.
    static let margin: CGFloat = 8

    /// The fitted side; nil until measured, when the artwork takes the most.
    private(set) var side: CGFloat?

    @ObservationIgnored var artworkSide: CGFloat = 0
    @ObservationIgnored var headerBottom: CGFloat?
    /// From the header's bottom to the second song's: a section heading and
    /// two rows, learned from the first row once it is drawn.
    @ObservationIgnored var songsAllowance: CGFloat = 36 + 2 * 64
    @ObservationIgnored var listWidth: CGFloat = 0
    @ObservationIgnored var listSafeBottom: CGFloat = 0
    @ObservationIgnored var miniPlayerTop: CGFloat?
    @ObservationIgnored var isAtTop = true

    var maxSide: CGFloat { side ?? Self.maxSide }

    /// Everything under the artwork moves with it point for point, so one
    /// measurement finds the side that puts the second song at the limit.
    func fit() {
        guard isAtTop, let headerBottom, artworkSide > 0, listWidth > 0 else { return }
        let bottom = (miniPlayerTop ?? listSafeBottom) - Self.margin
        let widest = min(Self.maxSide, listWidth - 32)
        let fitted = min(max(artworkSide + bottom - (headerBottom + songsAllowance), Self.minSide), widest).rounded(.down)
        guard abs(fitted - artworkSide) >= 1 else { return }
        side = fitted
    }
}

extension View {
    /// On the list: its frame, the mini player, and whether it rests at the top.
    func headerArtworkFit(_ fit: HeaderArtworkFit) -> some View {
        modifier(HeaderArtworkFitListModifier(fit: fit))
    }

    /// On the artwork, already square: capped at the fitted side.
    func headerArtworkFitArtwork(_ fit: HeaderArtworkFit) -> some View {
        frame(maxWidth: fit.maxSide)
            .headerArtworkFitSide(fit)
    }

    /// Reports the artwork's side as drawn.
    func headerArtworkFitSide(_ fit: HeaderArtworkFit) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            fit.artworkSide = $0
            fit.fit()
        }
    }

    /// On the header holding the artwork, title and Shuffle and Play.
    func headerArtworkFitHeader(_ fit: HeaderArtworkFit) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
            fit.headerBottom = $0
            fit.fit()
        }
    }

    /// On the first song's row: where the songs start and how tall a row is.
    func headerArtworkFitFirstRow(_ fit: HeaderArtworkFit, isFirst: Bool) -> some View {
        onGeometryChange(for: CGRect?.self) { isFirst ? $0.frame(in: .global) : nil } action: { frame in
            guard let frame, let headerBottom = fit.headerBottom, fit.isAtTop else { return }
            fit.songsAllowance = max(frame.minY - headerBottom, 0) + 2 * frame.height
            fit.fit()
        }
    }
}

private struct HeaderArtworkFitListModifier: ViewModifier {
    @Environment(\.miniPlayerTop) private var miniPlayerTop
    var fit: HeaderArtworkFit

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: [CGFloat].self) { proxy in
                let frame = proxy.frame(in: .global)
                return [frame.width, frame.maxY - proxy.safeAreaInsets.bottom]
            } action: { values in
                fit.listWidth = values[0]
                fit.listSafeBottom = values[1]
                fit.fit()
            }
            .onScrollGeometryChange(for: Bool.self) { abs($0.contentOffset.y + $0.contentInsets.top) < 1 } action: { _, atTop in
                fit.isAtTop = atTop
                fit.fit()
            }
            .onChange(of: miniPlayerTop, initial: true) {
                fit.miniPlayerTop = miniPlayerTop
                fit.fit()
            }
    }
}
