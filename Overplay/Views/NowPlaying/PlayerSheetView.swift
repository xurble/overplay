import SwiftUI

struct PlayerSheetView: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var collapsedHeight: CGFloat

    @State private var artworkTheme = AlbumArtworkTheme.fallback

    var body: some View {
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
                    artworkTheme: artworkTheme
                ) { refreshedTheme in
                    applyArtworkTheme(refreshedTheme, source: "debug-refresh")
                }
                    .padding(.bottom, collapsedHeight + proxy.safeAreaInsets.bottom)
                    .opacity(contentOpacity)
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
            .animation(.easeInOut(duration: 0.35), value: artworkTheme)
        }
        .task(id: artworkThemeIdentity) {
            await loadArtworkTheme()
        }
    }

    private var artworkThemeIdentity: String {
        [
            playbackController.currentTrack?.id ?? "",
            playbackController.currentTrack?.artworkURLTemplate ?? "",
            playbackController.currentPlaylistID ?? "",
            colorSchemeContrast == .increased ? "increased" : "standard"
        ].joined(separator: "|")
    }

    @MainActor
    private func loadArtworkTheme() async {
        let requestIdentity = artworkThemeIdentity
        let track = playbackController.currentTrack
        let playlistID = playbackController.currentPlaylistID
        let trackTitle = track?.title
        let artistName = track?.artistName
        let albumTitle = track?.albumTitle
        let requiresIncreasedContrast = colorSchemeContrast == .increased
        guard let artworkURLTemplate = track?.artworkURLTemplate else {
            AlbumArtworkThemeDiagnostics.log(
                "sheet fallback: missing artwork for trackID=\(track?.id ?? "nil") title=\(trackTitle ?? "nil")"
            )
            withAnimation(.easeInOut(duration: 0.35)) {
                artworkTheme = .fallback
            }
            return
        }

        if let cachedTheme = await AlbumArtworkThemeProvider.shared.cachedTheme(
            forArtworkURLTemplate: artworkURLTemplate,
            requiresIncreasedContrast: requiresIncreasedContrast
        ) {
            guard !Task.isCancelled, requestIdentity == artworkThemeIdentity else { return }
            applyArtworkTheme(cachedTheme, source: "cached")
            return
        }

        AlbumArtworkThemeDiagnostics.log(
            "sheet prepare: no cached theme for trackID=\(track?.id ?? "nil") title=\(trackTitle ?? "nil")"
        )
        let theme = await AlbumArtworkThemeProvider.shared.prepareTheme(
            forArtworkURLTemplate: artworkURLTemplate,
            playlistID: playlistID,
            trackTitle: trackTitle,
            artistName: artistName,
            albumTitle: albumTitle,
            requiresIncreasedContrast: requiresIncreasedContrast
        )
        guard !Task.isCancelled, requestIdentity == artworkThemeIdentity else { return }
        applyArtworkTheme(theme, source: "prepared")
    }

    @MainActor
    private func applyArtworkTheme(_ theme: AlbumArtworkTheme, source: String) {
        AlbumArtworkThemeDiagnostics.log(
            "sheet apply \(source): trackID=\(playbackController.currentTrack?.id ?? "nil") title=\(playbackController.currentTrack?.title ?? "nil") fallback=\(theme.isFallback) themeSource=\(theme.source.rawValue) background=\(AlbumArtworkThemeDiagnostics.describe(theme.backgroundRGB)) titleColor=\(AlbumArtworkThemeDiagnostics.describe(theme.trackTitleRGB))"
        )
        withAnimation(.easeInOut(duration: 0.35)) {
            artworkTheme = theme
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

                artworkTheme.background
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
