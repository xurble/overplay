import SwiftData
import SwiftUI

struct AppRouter: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MusicAuthorizationService.self) private var authorizationService
    @Environment(PlaybackController.self) private var playbackController

    @Query private var settingsRecords: [OverplaySettings]
    @State private var remoteCommandService = RemoteCommandService()
    @State private var playerSheetDetent: PresentationDetent = .height(96)

    private let playerSheetCollapsedHeight: CGFloat = 96

    var body: some View {
        NavigationStack {
            Group {
                if !authorizationService.readiness.isReady {
                    PermissionView()
                } else if let settings {
                    DashboardView(settings: settings)
                } else {
                    ProgressView("Preparing Overplay")
                }
            }
        }
        .sheet(isPresented: playerSheetPresentation) {
            if let settings {
                PlayerSheetView(settings: settings, collapsedHeight: playerSheetCollapsedHeight)
                    .presentationDetents([.height(playerSheetCollapsedHeight), .large], selection: $playerSheetDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(playerSheetCollapsedHeight)))
                    .presentationContentInteraction(.resizes)
                    .interactiveDismissDisabled()
            } else {
                EmptyView()
            }
        }
        .task {
            _ = try? SettingsRepository.settings(in: modelContext)
            await authorizationService.refresh()
            playbackController.startMonitoring(context: modelContext)
            remoteCommandService.install(playbackController: playbackController, context: modelContext)
        }
    }

    private var settings: OverplaySettings? {
        settingsRecords.first
    }

    private var playerSheetPresentation: Binding<Bool> {
        Binding {
            authorizationService.readiness.isReady && settings != nil
        } set: { _ in
            playerSheetDetent = .height(playerSheetCollapsedHeight)
        }
    }
}

private struct PlayerSheetView: View {
    var settings: OverplaySettings
    var collapsedHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let contentOpacity = expandedContentOpacity(for: proxy.size.height)

            ZStack(alignment: .bottom) {
                NowPlayingPaneView(settings: settings)
                    .padding(.bottom, collapsedHeight + proxy.safeAreaInsets.bottom)
                    .opacity(contentOpacity)
                    .allowsHitTesting(contentOpacity > 0.5)

                MiniPlayerLozengeView(settings: settings)
                    .frame(height: collapsedHeight)
                    .background(.regularMaterial)
                    .padding(.bottom, proxy.safeAreaInsets.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func expandedContentOpacity(for sheetHeight: CGFloat) -> Double {
        let fadeStart = collapsedHeight + 56
        let fadeDistance: CGFloat = 180
        let progress = min(max((sheetHeight - fadeStart) / fadeDistance, 0), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        return Double(easedProgress)
    }
}

private struct MiniPlayerLozengeView: View {
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(urlString: playbackController.currentTrack?.artworkURLTemplate, cornerRadius: 10)
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
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

private struct NowPlayingPaneView: View {
    @Environment(\.modelContext) private var modelContext
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

            VStack(spacing: compactLayout ? 12 : 18) {
                ArtworkView(urlString: playbackController.currentTrack?.artworkURLTemplate)
                    .frame(width: artworkSize, height: artworkSize)
                    .shadow(color: .black.opacity(0.28), radius: 22, y: 16)

                trackText
                progressBlock
                skipStatus
                triageControls

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

    private var trackText: some View {
        VStack(spacing: 8) {
            Text(playbackController.currentTrack?.title ?? "Nothing playing")
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
            Text(playbackController.currentTrack?.artistName ?? "Choose a playlist to start playback.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            if let albumTitle = playbackController.currentTrack?.albumTitle {
                Text(albumTitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 6) {
            ProgressView(value: playbackController.progress)
            HStack {
                Text(formatTime(playbackController.elapsedSeconds))
                Spacer()
                Text(formatTime(playbackController.durationSeconds ?? 0))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var skipStatus: some View {
        HStack(spacing: 14) {
            Label(
                "Skips: \(playbackController.currentTrack?.skipCount ?? 0) / \(settings.evictAfterSkips)",
                systemImage: "forward.end.fill"
            )
            if playbackController.currentTrack?.isEvicted == true {
                Label("Evicted", systemImage: "trash.fill")
                    .foregroundStyle(.red)
            }
            if playbackController.currentTrack?.protected == true {
                Label("Protected", systemImage: "shield.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
    }

    private var triageControls: some View {
        HStack(spacing: 12) {
            Button {
                playbackController.keepCurrent(settings: settings, context: modelContext)
            } label: {
                Label("Keep", systemImage: "heart.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(playbackController.currentTrack == nil)

            Button(role: .destructive) {
                Task { await playbackController.evictCurrent(settings: settings, context: modelContext) }
            } label: {
                Label("Evict Now", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(playbackController.currentTrack == nil)
        }
        .buttonStyle(.bordered)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let totalSeconds = max(Int(seconds), 0)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

#Preview {
    AppRouter()
        .environment(MusicAuthorizationService())
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
