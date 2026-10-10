import SwiftData
import SwiftUI

struct NowPlayingPaneView: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var artworkTheme: AlbumArtworkTheme?
    var onArtworkThemeUpdated: (AlbumArtworkTheme) -> Void = { _ in }
    /// The top of the artwork, in global coordinates.
    var onArtworkTopChange: ((CGFloat) -> Void)? = nil

    @State private var isShowingThemeDiagnostics = false
    @State private var isThemeDiagnosticsLoading = false
    @State private var themeDebugReport: AlbumArtworkThemeDebugReport?
    @State private var themeDebugErrorMessage: String?

    var body: some View {
        GeometryReader { proxy in
            // Blend from the compact layout to the regular one as the sheet
            // grows, so nothing steps while it is dragged (0 = compact).
            let roominess = Self.roominess(forHeight: proxy.size.height)
            let artworkSize = min(
                proxy.size.width - 56,
                Self.blend(170, 260, roominess),
                max(proxy.size.height * Self.blend(0.26, 0.34, roominess), 112)
            )
            let presentation = NowPlayingPresentationFactory.presentation(
                playbackController: playbackController,
                settings: settings,
                context: modelContext
            )
            let displayTrack = playbackController.nowPlayingDisplayTrack
            let activeArtworkTheme = artworkTheme?.isFallback == false ? artworkTheme : nil

            VStack(spacing: Self.blend(12, 18, roominess)) {
                NowPlayingArtworkView(
                    urlString: displayTrack?.artworkURLTemplate,
                    playlistID: playbackController.currentPlaylistContext?.musicPlaylistID
                )
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 16)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                    onArtworkTopChange?(top)
                }

                PlaybackCollectionContextView(foreground: activeArtworkTheme?.albumName ?? .secondary)
                NowPlayingTrackTextView(
                    presentation: presentation,
                    titleLineLimit: 2,
                    detailLineLimit: 1,
                    artworkTheme: activeArtworkTheme,
                    offersCollectionMenu: true
                )
                NowPlayingProgressView(
                    presentation: presentation,
                    foreground: activeArtworkTheme?.artistName,
                    foregroundRGB: activeArtworkTheme?.artistNameRGB
                )
                TrackPlaybackFactsView(presentation: presentation, artworkTheme: activeArtworkTheme)
                PlaybackModeControlsView(artworkTheme: activeArtworkTheme)
                TrackActionControlsView(settings: settings, artworkTheme: activeArtworkTheme)
                if showsArtworkThemeDebugButton {
                    AlbumArtworkThemeDebugButton(
                        artworkTheme: activeArtworkTheme,
                        isLoading: isThemeDiagnosticsLoading
                    ) {
                        isShowingThemeDiagnostics = true
                        Task {
                            await rerunThemeDiagnostics()
                        }
                    }
                    .disabled(playbackController.nowPlayingDisplayTrack?.artworkURLTemplate == nil)
                }

                if let statusMessage = playbackController.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(activeArtworkTheme?.albumName ?? .secondary)
                        .multilineTextAlignment(.center)
                }
                PlaybackFailureRetryView()
                SysdiagnoseReminderButtonView()
            }
            .padding(.horizontal, 24)
            .padding(.top, Self.blend(16, 24, roominess))
            .padding(.bottom, Self.blend(12, 20, roominess))
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

    private var showsArtworkThemeDebugButton: Bool {
        false
    }

    @MainActor
    private func rerunThemeDiagnostics() async {
        let track = playbackController.nowPlayingDisplayTrack
        guard let artworkURLTemplate = track?.artworkURLTemplate else {
            themeDebugReport = nil
            themeDebugErrorMessage = "Current track has no artwork URL."
            return
        }

        isThemeDiagnosticsLoading = true
        themeDebugErrorMessage = nil
        let report = await AlbumArtworkThemeProvider.shared.debugReport(
            forArtworkURLTemplate: artworkURLTemplate,
            playlistID: playbackController.currentPlaylistContext?.musicPlaylistID,
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

    /// 0 at 560 points tall or less, 1 at 680 or more, eased between.
    private static func roominess(forHeight height: CGFloat) -> CGFloat {
        let progress = min(max((height - 560) / 120, 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    private static func blend(_ compact: CGFloat, _ regular: CGFloat, _ roominess: CGFloat) -> CGFloat {
        compact + (regular - compact) * roominess
    }
}

#Preview {
    NowPlayingPaneView(
        settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"),
        artworkTheme: nil
    )
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
