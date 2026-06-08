import SwiftUI

struct PlayerSheetView: View {
    var settings: OverplaySettings
    var collapsedHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let contentOpacity = expandedContentOpacity(for: proxy.size.height)
            let backgroundOpacity = expandedBackgroundOpacity(for: proxy.size.height)

            ZStack(alignment: .bottom) {
                PlayerSheetBackground(opaqueProgress: backgroundOpacity)

                NowPlayingPaneView(settings: settings)
                    .padding(.bottom, collapsedHeight + proxy.safeAreaInsets.bottom)
                    .opacity(contentOpacity)
                    .allowsHitTesting(contentOpacity > 0.5)

                MiniPlayerLozengeView(settings: settings, expandedProgress: backgroundOpacity)
                    .frame(height: collapsedHeight)
                    .padding(.bottom, proxy.safeAreaInsets.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
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

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.42 + (0.58 * opaqueProgress))

            LinearGradient(
                colors: [
                    .white.opacity(0.12),
                    .white.opacity(0.04),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(1 - opaqueProgress)

            Rectangle()
                .fill(.background)
                .opacity(opaqueProgress)
        }
    }
}

struct MiniPlayerLozengeView: View {
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var expandedProgress: Double

    var body: some View {
        ZStack {
            compactContent
                .opacity(1 - expandedProgress)
                .allowsHitTesting(expandedProgress < 0.5)

            expandedContent
                .opacity(expandedProgress)
                .allowsHitTesting(expandedProgress >= 0.5)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(.smooth(duration: 0.22), value: expandedProgress)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(height: 1)
                .opacity(1 - expandedProgress)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 12) {
            NowPlayingArtworkView(
                urlString: playbackController.currentTrack?.artworkURLTemplate,
                playlistID: playbackController.currentPlaylistID,
                cornerRadius: 10
            )
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(playbackController.currentTrack?.title ?? "Nothing playing")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(playbackController.currentTrack?.artistName ?? "Choose a playlist to start playback")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            PlaybackControlsView(settings: settings, controlSize: .compact)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var expandedContent: some View {
        PlaybackControlsView(settings: settings, controlSize: .regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct NowPlayingPaneView: View {
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings

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
                    detailLineLimit: 1
                )
                NowPlayingProgressView(presentation: presentation, tint: nil)
                TrackHealthStatusView(presentation: presentation)
                PlaybackModeControlsView()
                TrackActionControlsView(settings: settings)

                if let statusMessage = playbackController.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, compactLayout ? 16 : 24)
            .padding(.bottom, compactLayout ? 12 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
