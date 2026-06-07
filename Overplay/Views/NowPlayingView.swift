import SwiftData
import SwiftUI

struct NowPlayingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRuntime.self) private var runtime
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: 24) {
                    ArtworkView(
                        urlString: playbackController.currentTrack?.artworkURLTemplate,
                        playlistID: playbackController.currentPlaylistID
                    )
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 18)

                    trackText
                    progressBlock
                    skipStatus
                    PlaybackControlsView(settings: settings)
                    secondaryControls

                    if let statusMessage = playbackController.statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .miniPlayerScrollContentInset()
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var background: some View {
        LinearGradient(
            colors: [.black, .indigo.opacity(0.75), .teal.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(.ultraThinMaterial)
    }

    private var trackText: some View {
        VStack(spacing: 8) {
            Text(nowPlayingPresentation.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(nowPlayingPresentation.artistName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let albumTitle = nowPlayingPresentation.albumTitle {
                Text(albumTitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 6) {
            ProgressView(value: nowPlayingPresentation.progress)
                .tint(.white)
            HStack {
                Text(nowPlayingPresentation.elapsedText)
                Spacer()
                Text(nowPlayingPresentation.durationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var skipStatus: some View {
        HStack(spacing: 14) {
            Label(
                nowPlayingPresentation.skipCountText,
                systemImage: "forward.end.fill"
            )
            if nowPlayingPresentation.isEvicted {
                let healthPresentation = TrackHealthPresentation(status: .critical, isEvicted: true, isProtected: false)
                Label(healthPresentation.title, systemImage: healthPresentation.systemImage)
                    .foregroundStyle(.red)
            }
            if nowPlayingPresentation.isProtected {
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

    private var secondaryControls: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
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

            GridRow {
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
        }
        .buttonStyle(.bordered)
    }

    private var nowPlayingPresentation: NowPlayingPresentation {
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

    private var controlsPresentation: PlaybackControlsPresentation {
        PlaybackControlsPresentation(
            isPlaying: playbackController.isPlaying,
            shuffleEnabled: playbackController.shuffleEnabled,
            repeatEnabled: playbackController.repeatEnabled
        )
    }
}

#Preview {
    NavigationStack {
        NowPlayingView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .environment(AppRuntime.shared)
    .modelContainer(PreviewContainer.make())
}
