import SwiftUI

struct PlayerSheetView: View {
    var settings: OverplaySettings
    var collapsedHeight: CGFloat

    var body: some View {
        ThemedPlayerHost { artworkTheme, applyRefreshedTheme in
            GeometryReader { proxy in
                let contentOpacity = expandedContentOpacity(for: proxy.size.height)
                let backgroundOpacity = expandedBackgroundOpacity(for: proxy.size.height)

                ZStack(alignment: .bottom) {
                    PlayerSheetBackground(
                        opaqueProgress: backgroundOpacity,
                        artworkTheme: artworkTheme
                    )

                    NowPlayingPaneView(
                        settings: settings,
                        artworkTheme: artworkTheme,
                        onArtworkThemeUpdated: applyRefreshedTheme
                    )
                        .padding(.bottom, collapsedHeight + proxy.safeAreaInsets.bottom)
                        .modifier(PlayerGlassFade(opacity: contentOpacity))
                        .allowsHitTesting(contentOpacity > 0.5)

                    MiniPlayerLozengeView(
                        settings: settings,
                        expandedProgress: backgroundOpacity,
                        artworkTheme: artworkTheme
                    )
                        .frame(height: collapsedHeight)
                        .padding(.bottom, proxy.safeAreaInsets.bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private func expandedBackgroundOpacity(for sheetHeight: CGFloat) -> Double {
        let fadeStart = collapsedHeight + 96
        let fadeDistance: CGFloat = 320
        let progress = min(max((sheetHeight - fadeStart) / fadeDistance, 0), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        return Double(easedProgress)
    }

    private func expandedContentOpacity(for sheetHeight: CGFloat) -> Double {
        let fadeStart = collapsedHeight + 56
        let fadeDistance: CGFloat = 180
        let progress = min(max((sheetHeight - fadeStart) / fadeDistance, 0), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        return Double(easedProgress)
    }
}

private struct PlayerSheetBackground: View {
    var opaqueProgress: Double
    var artworkTheme: AlbumArtworkTheme

    var body: some View {
        ZStack {
            if artworkTheme.isFallback {
                Rectangle()
                    .fill(.background)
            } else {
                Rectangle()
                    .fill(.background)
                    .opacity(1 - opaqueProgress)

                PlayerGlassArtBackground(tint: artworkTheme.background)
                    .opacity(opaqueProgress)
            }
        }
    }
}

#Preview {
    PlayerSheetView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"),
        collapsedHeight: 96
    )
    .environment(PlaybackController())
}
