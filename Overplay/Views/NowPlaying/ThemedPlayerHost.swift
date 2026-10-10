import SwiftUI

/// Loads the artwork theme for the playing track and supplies it, with the
/// glass backdrop and art for readable text, to a player surface: the sheet
/// in compact width, the column in regular width.
struct ThemedPlayerHost<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(PlaybackController.self) private var playbackController

    /// The theme, and a way to apply one the diagnostics view rebuilt.
    @ViewBuilder var content: (AlbumArtworkTheme, @escaping (AlbumArtworkTheme) -> Void) -> Content

    @State private var artworkTheme = AlbumArtworkTheme.fallback
    @State private var glassBackdrop = PlayerGlassBackdrop()

    var body: some View {
        let artworkTheme = displayedTheme
        content(artworkTheme) { applyArtworkTheme($0, source: "debug-refresh") }
            .coordinateSpace(.named(PlayerGlassBackdrop.coordinateSpace))
            .environment(\.playerGlassArtwork, glassArtwork)
            .environment(\.playerGlassBackdrop, artworkTheme.isFallback ? nil : glassBackdrop)
            .animation(.easeInOut(duration: 0.35), value: artworkTheme)
            .task(id: artworkThemeIdentity) {
                await loadArtworkTheme()
            }
            .task(id: glassArtwork) {
                await glassBackdrop.load(glassArtwork)
            }
            .onChange(of: artworkTheme, initial: true) {
                glassBackdrop.tint = artworkTheme.backgroundRGB
            }
    }

    /// A player that appears (a folding phone switching screens, the
    /// regular-width column) starts with the theme the last one showed for
    /// this track, rather than the fallback and then easing into it, which
    /// resized the controls and moved the art after the screen activated.
    private var displayedTheme: AlbumArtworkTheme {
        guard artworkTheme.isFallback, let last = LastPlayerTheme.value, last.identity == artworkThemeIdentity else {
            return artworkTheme
        }
        return last.theme
    }

    private var glassArtwork: PlayerGlassArtwork? {
        playbackController.nowPlayingDisplayTrack?.artworkURLTemplate.map {
            PlayerGlassArtwork(urlString: $0, playlistID: playbackController.currentPlaylistContext?.musicPlaylistID)
        }
    }

    private var artworkThemeIdentity: String {
        [
            playbackController.nowPlayingDisplayTrack?.id ?? "",
            playbackController.nowPlayingDisplayTrack?.artworkURLTemplate ?? "",
            playbackController.currentPlaylistContext?.musicPlaylistID ?? "",
            colorSchemeContrast == .increased ? "increased" : "standard"
        ].joined(separator: "|")
    }

    @MainActor
    private func loadArtworkTheme() async {
        let requestIdentity = artworkThemeIdentity
        let track = playbackController.nowPlayingDisplayTrack
        let playlistID = playbackController.currentPlaylistContext?.musicPlaylistID
        let trackTitle = track?.title
        let artistName = track?.artistName
        let albumTitle = track?.albumTitle
        let requiresIncreasedContrast = colorSchemeContrast == .increased
        guard let artworkURLTemplate = track?.artworkURLTemplate else {
            AlbumArtworkThemeDiagnostics.log(
                "player fallback: missing artwork for trackID=\(track?.id ?? "nil") title=\(trackTitle ?? "nil")"
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
            "player prepare: no cached theme for trackID=\(track?.id ?? "nil") title=\(trackTitle ?? "nil")"
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
            "player apply \(source): trackID=\(playbackController.nowPlayingDisplayTrack?.id ?? "nil") title=\(playbackController.nowPlayingDisplayTrack?.title ?? "nil") fallback=\(theme.isFallback) themeSource=\(theme.source.rawValue) background=\(AlbumArtworkThemeDiagnostics.describe(theme.backgroundRGB)) titleColor=\(AlbumArtworkThemeDiagnostics.describe(theme.trackTitleRGB))"
        )
        LastPlayerTheme.value = (artworkThemeIdentity, theme)
        withAnimation(.easeInOut(duration: 0.35)) {
            artworkTheme = theme
        }
    }
}

/// The theme a player surface last applied, shared by every surface.
@MainActor
private enum LastPlayerTheme {
    static var value: (identity: String, theme: AlbumArtworkTheme)?
}
