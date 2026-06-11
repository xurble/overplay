import SwiftUI

struct NowPlayingPaneView: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var artworkTheme: AlbumArtworkTheme?
    var onArtworkThemeUpdated: (AlbumArtworkTheme) -> Void = { _ in }

    @State private var isShowingThemeDiagnostics = false
    @State private var isThemeDiagnosticsLoading = false
    @State private var themeDebugReport: AlbumArtworkThemeDebugReport?
    @State private var themeDebugErrorMessage: String?

    var body: some View {
        GeometryReader { proxy in
            let compactLayout = proxy.size.height < 620
            let artworkSize = min(
                proxy.size.width - 56,
                compactLayout ? 170 : 260,
                max(proxy.size.height * (compactLayout ? 0.26 : 0.34), 112)
            )
            let presentation = NowPlayingPresentationFactory.presentation(
                playbackController: playbackController,
                settings: settings
            )
            let activeArtworkTheme = artworkTheme?.isFallback == false ? artworkTheme : nil

            VStack(spacing: compactLayout ? 12 : 18) {
                NowPlayingArtworkView(
                    urlString: playbackController.currentTrack?.artworkURLTemplate,
                    playlistID: playbackController.currentPlaylistID
                )
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 16)

                NowPlayingTrackTextView(
                    presentation: presentation,
                    titleLineLimit: 2,
                    detailLineLimit: 1,
                    artworkTheme: activeArtworkTheme
                )
                NowPlayingProgressView(
                    presentation: presentation,
                    foreground: activeArtworkTheme?.artistName
                )
                TrackHealthStatusView(presentation: presentation, artworkTheme: activeArtworkTheme)
                PlaybackModeControlsView(artworkTheme: activeArtworkTheme)
                TrackActionControlsView(settings: settings, artworkTheme: activeArtworkTheme)
                AlbumArtworkThemeDebugButton(
                    artworkTheme: activeArtworkTheme,
                    isLoading: isThemeDiagnosticsLoading
                ) {
                    isShowingThemeDiagnostics = true
                    Task {
                        await rerunThemeDiagnostics()
                    }
                }
                .disabled(playbackController.currentTrack?.artworkURLTemplate == nil)

                if let statusMessage = playbackController.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(activeArtworkTheme?.albumName ?? .secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, compactLayout ? 16 : 24)
            .padding(.bottom, compactLayout ? 12 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .sheet(isPresented: $isShowingThemeDiagnostics) {
            AlbumArtworkThemeDebugSheet(
                report: themeDebugReport,
                isLoading: isThemeDiagnosticsLoading,
                errorMessage: themeDebugErrorMessage
            ) {
                Task {
                    await rerunThemeDiagnostics()
                }
            }
        }
    }

    @MainActor
    private func rerunThemeDiagnostics() async {
        let track = playbackController.currentTrack
        guard let artworkURLTemplate = track?.artworkURLTemplate else {
            themeDebugReport = nil
            themeDebugErrorMessage = "Current track has no artwork URL."
            return
        }

        isThemeDiagnosticsLoading = true
        themeDebugErrorMessage = nil
        let report = await AlbumArtworkThemeProvider.shared.debugReport(
            forArtworkURLTemplate: artworkURLTemplate,
            playlistID: playbackController.currentPlaylistID,
            trackTitle: track?.title,
            artistName: track?.artistName,
            albumTitle: track?.albumTitle,
            requiresIncreasedContrast: colorSchemeContrast == .increased,
            persistGeneratedTheme: true
        )
        themeDebugReport = report
        themeDebugErrorMessage = report.errorMessage
        if report.errorMessage == nil {
            onArtworkThemeUpdated(report.theme)
        }
        isThemeDiagnosticsLoading = false
    }
}

#Preview {
    NowPlayingPaneView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"),
        artworkTheme: nil
    )
    .environment(PlaybackController())
}
