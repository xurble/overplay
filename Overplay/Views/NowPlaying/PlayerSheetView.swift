import SwiftUI

struct PlayerSheetView: View {
    var settings: OverplaySettings
    var collapsedHeight: CGFloat

    @State private var paneContentBottom: CGFloat?
    @State private var audioOutputTop: CGFloat?

    var body: some View {
        ThemedPlayerHost { artworkTheme, applyRefreshedTheme in
            GeometryReader { proxy in
                let contentOpacity = expandedContentOpacity(for: proxy.size.height)
                let backgroundOpacity = expandedBackgroundOpacity(for: proxy.size.height)
                // Room below the transport for the audio output pill, opening
                // as the sheet expands so nothing steps while it is dragged.
                let audioOutputSpace = AudioOutputPillView.isAvailable
                    ? AudioOutputPillView.rowHeight * backgroundOpacity
                    : 0

                ZStack(alignment: .bottom) {
                    PlayerSheetBackground(
                        opaqueProgress: backgroundOpacity,
                        artworkTheme: artworkTheme
                    )

                    NowPlayingPaneView(
                        settings: settings,
                        artworkTheme: artworkTheme,
                        onArtworkThemeUpdated: applyRefreshedTheme,
                        onContentBottomChange: { paneContentBottom = $0 }
                    )
                        .padding(.bottom, collapsedHeight + audioOutputSpace + proxy.safeAreaInsets.bottom)
                        .modifier(PlayerGlassFade(opacity: contentOpacity))
                        .allowsHitTesting(contentOpacity > 0.5)

                    MiniPlayerLozengeView(
                        settings: settings,
                        expandedProgress: backgroundOpacity,
                        artworkTheme: artworkTheme
                    )
                        .frame(height: collapsedHeight)
                        .padding(.bottom, audioOutputSpace + proxy.safeAreaInsets.bottom)
                        .offset(y: -transportLift * backgroundOpacity)

                    if AudioOutputPillView.isAvailable {
                        AudioOutputPillView(artworkTheme: artworkTheme, isExpanded: contentOpacity > 0.5)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                                audioOutputTop = top
                            }
                            .frame(height: AudioOutputPillView.rowHeight, alignment: .top)
                            .padding(.bottom, proxy.safeAreaInsets.bottom)
                            .modifier(PlayerGlassFade(opacity: contentOpacity))
                            .allowsHitTesting(contentOpacity > 0.5)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    /// How far to lift the expanded transport, centred in the lozenge
    /// directly above the pill, so it sits halfway between the player's
    /// controls and the pill.
    private var transportLift: CGFloat {
        guard AudioOutputPillView.isAvailable, let paneContentBottom, let audioOutputTop else { return 0 }
        return (audioOutputTop - paneContentBottom) / 2 - collapsedHeight / 2
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
