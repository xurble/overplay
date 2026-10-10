import SwiftData
import SwiftUI

struct NowPlayingPaneView: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var artworkTheme: AlbumArtworkTheme?
    var onArtworkThemeUpdated: (AlbumArtworkTheme) -> Void = { _ in }
    /// The top of the artwork, in the full-screen player's coordinates.
    var onArtworkTopChange: ((CGFloat) -> Void)? = nil
    /// Art and track beside the controls, which then include the transport.
    var isSideBySide = false

    @State private var isShowingThemeDiagnostics = false
    @State private var isThemeDiagnosticsLoading = false
    @State private var themeDebugReport: AlbumArtworkThemeDebugReport?
    @State private var themeDebugErrorMessage: String?

    var body: some View {
        GeometryReader { proxy in
            let presentation = NowPlayingPresentationFactory.presentation(
                playbackController: playbackController,
                settings: settings,
                context: modelContext
            )
            let activeArtworkTheme = artworkTheme?.isFallback == false ? artworkTheme : nil

            if isSideBySide {
                sideBySide(in: proxy.size, presentation: presentation, artworkTheme: activeArtworkTheme)
            } else {
                column(in: proxy.size, presentation: presentation, artworkTheme: activeArtworkTheme)
            }
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

    private func column(in size: CGSize, presentation: NowPlayingPresentation, artworkTheme: AlbumArtworkTheme?) -> some View {
        // Blend from the compact layout to the regular one as the sheet
        // grows, so nothing steps while it is dragged (0 = compact).
        let roominess = Self.roominess(forHeight: size.height)
        let artworkSize = min(
            size.width - 56,
            Self.blend(170, 260, roominess),
            max(size.height * Self.blend(0.26, 0.34, roominess), 112)
        )
        return VStack(spacing: Self.blend(12, 18, roominess)) {
            identity(artworkSize: artworkSize, presentation: presentation, artworkTheme: artworkTheme)
            trackControls(presentation: presentation, artworkTheme: artworkTheme)
        }
        .padding(.horizontal, 24)
        .padding(.top, Self.blend(16, 24, roominess))
        .padding(.bottom, Self.blend(12, 20, roominess))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// Wide and short (iPhone Duo open in portrait, above the fold): the art
    /// and track on the left, every control including the transport on the
    /// right.
    private func sideBySide(in size: CGSize, presentation: NowPlayingPresentation, artworkTheme: AlbumArtworkTheme?) -> some View {
        let identityWidth = ((size.width - 72) * 0.45).rounded()
        let artworkSize = max(min(identityWidth, size.height - 150), 112)
        return HStack(spacing: 24) {
            VStack(spacing: 12) {
                identity(artworkSize: artworkSize, presentation: presentation, artworkTheme: artworkTheme)
            }
            .frame(width: identityWidth)
            VStack(spacing: 12) {
                trackControls(presentation: presentation, artworkTheme: artworkTheme)
                PlaybackControlsView(settings: settings, controlSize: .regular, artworkTheme: artworkTheme)
                if AudioOutputPillView.isAvailable {
                    AudioOutputPillView(artworkTheme: artworkTheme)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// The art, the collection playing and the track.
    @ViewBuilder
    private func identity(artworkSize: CGFloat, presentation: NowPlayingPresentation, artworkTheme: AlbumArtworkTheme?) -> some View {
        NowPlayingArtworkView(
            urlString: playbackController.nowPlayingDisplayTrack?.artworkURLTemplate,
            playlistID: playbackController.currentPlaylistContext?.musicPlaylistID
        )
        .frame(width: artworkSize, height: artworkSize)
        .shadow(color: .black.opacity(0.28), radius: 22, y: 16)
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named(FullScreenPlayerView.coordinateSpace)).minY
        } action: { top in
            onArtworkTopChange?(top)
        }

        PlaybackCollectionContextView(foreground: artworkTheme?.albumName ?? .secondary)
        NowPlayingTrackTextView(
            presentation: presentation,
            titleLineLimit: 2,
            detailLineLimit: 1,
            artworkTheme: artworkTheme,
            offersCollectionMenu: true
        )
    }

    /// Progress, facts, modes, track actions and status, above the transport.
    @ViewBuilder
    private func trackControls(presentation: NowPlayingPresentation, artworkTheme: AlbumArtworkTheme?) -> some View {
        NowPlayingProgressView(
            presentation: presentation,
            foreground: artworkTheme?.artistName,
            foregroundRGB: artworkTheme?.artistNameRGB
        )
        TrackPlaybackFactsView(presentation: presentation, artworkTheme: artworkTheme)
        PlaybackModeControlsView(artworkTheme: artworkTheme)
        TrackActionControlsView(settings: settings, artworkTheme: artworkTheme)
        if showsArtworkThemeDebugButton {
            AlbumArtworkThemeDebugButton(
                artworkTheme: artworkTheme,
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
                .foregroundStyle(artworkTheme?.albumName ?? .secondary)
                .multilineTextAlignment(.center)
        }
        PlaybackFailureRetryView()
        SysdiagnoseReminderButtonView()
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
