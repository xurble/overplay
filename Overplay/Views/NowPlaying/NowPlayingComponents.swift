import SwiftData
import SwiftUI

struct NowPlayingArtworkView: View {
    var urlString: String?
    var playlistID: String?
    var healthStatus: TrackHealthStatus?
    var cornerRadius: CGFloat = 18

    var body: some View {
        ArtworkView(
            urlString: urlString,
            playlistID: playlistID,
            cornerRadius: cornerRadius,
            healthStatus: healthStatus
        )
    }
}

struct NowPlayingTrackTextView: View {
    var presentation: NowPlayingPresentation
    var titleFont: Font = .title.bold()
    var artistFont: Font = .title3
    var titleLineLimit: Int? = nil
    var detailLineLimit: Int? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(presentation.title)
                .font(titleFont)
                .multilineTextAlignment(.center)
                .lineLimit(titleLineLimit)
                .minimumScaleFactor(0.78)

            Text(presentation.artistName)
                .font(artistFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(detailLineLimit)
                .minimumScaleFactor(0.82)

            if let albumTitle = presentation.albumTitle {
                Text(albumTitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(detailLineLimit)
                    .minimumScaleFactor(0.82)
            }
        }
    }
}

struct NowPlayingProgressView: View {
    var presentation: NowPlayingPresentation
    var tint: Color?

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: presentation.progress)
                .tint(tint)

            HStack {
                Text(presentation.elapsedText)
                Spacer()
                Text(presentation.durationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

struct TrackHealthStatusView: View {
    var presentation: NowPlayingPresentation

    var body: some View {
        HStack(spacing: 14) {
            Label(presentation.skipCountText, systemImage: "forward.end.fill")

            if presentation.isEvicted {
                let healthPresentation = TrackHealthPresentation(status: .critical, isEvicted: true, isProtected: false)
                Label(healthPresentation.title, systemImage: healthPresentation.systemImage)
                    .foregroundStyle(.red)
            }

            if presentation.isProtected {
                let healthPresentation = TrackHealthPresentation(status: .healthy, isEvicted: false, isProtected: true)
                Label(healthPresentation.title, systemImage: healthPresentation.systemImage)
                    .foregroundStyle(.green)
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
    }
}

struct PlaybackModeControlsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRuntime.self) private var runtime
    @Environment(PlaybackController.self) private var playbackController

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await playbackController.toggleShuffle(context: modelContext)
                    runtime.remoteCommandService.syncPlaybackModes(from: playbackController)
                }
            } label: {
                Label(controlsPresentation.shuffleTitle, systemImage: controlsPresentation.shuffleSystemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(controlsPresentation.shuffleEnabled ? .accentColor : .secondary.opacity(0.24))

            Button {
                playbackController.toggleRepeat()
                runtime.remoteCommandService.syncPlaybackModes(from: playbackController)
            } label: {
                Label(controlsPresentation.repeatTitle, systemImage: controlsPresentation.repeatSystemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(controlsPresentation.repeatEnabled ? .accentColor : .secondary.opacity(0.24))
        }
    }

    private var controlsPresentation: PlaybackControlsPresentation {
        PlaybackControlsPresentation(
            isPlaying: playbackController.isPlaying,
            shuffleEnabled: playbackController.shuffleEnabled,
            repeatEnabled: playbackController.repeatEnabled
        )
    }
}

struct TrackActionControlsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings

    var body: some View {
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
}

enum NowPlayingPresentationFactory {
    static func presentation(
        playbackController: PlaybackController,
        settings: OverplaySettings
    ) -> NowPlayingPresentation {
        NowPlayingPresentation(
            title: playbackController.currentTrack?.title,
            artistName: playbackController.currentTrack?.artistName,
            albumTitle: playbackController.currentTrack?.albumTitle,
            progress: playbackController.progress,
            elapsedSeconds: playbackController.elapsedSeconds,
            durationSeconds: playbackController.durationSeconds,
            skipCount: playbackController.displayedSkipCount,
            evictAfterSkips: settings.evictAfterSkips,
            isEvicted: playbackController.displayedIsEvicted,
            isProtected: playbackController.displayedIsProtected
        )
    }

    static func healthStatus(
        playbackController: PlaybackController,
        settings: OverplaySettings
    ) -> TrackHealthStatus? {
        guard playbackController.currentTrack != nil else { return nil }
        return TrackHealthStatus.resolve(
            skipCount: playbackController.displayedSkipCount,
            evictAfterSkips: settings.evictAfterSkips,
            isEvicted: playbackController.displayedIsEvicted,
            isProtected: playbackController.displayedIsProtected
        )
    }
}
