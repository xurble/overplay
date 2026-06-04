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
            Text(playbackController.currentTrack?.title ?? "Nothing playing")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(playbackController.currentTrack?.artistName ?? "Choose Play Overplay from the dashboard.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let albumTitle = playbackController.currentTrack?.albumTitle {
                Text(albumTitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 6) {
            ProgressView(value: playbackController.progress)
                .tint(.white)
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
                "Skips: \(playbackController.currentPlaylistItem?.skipCount ?? playbackController.currentTrack?.skipCount ?? 0) / \(settings.evictAfterSkips)",
                systemImage: "forward.end.fill"
            )
            if playbackController.currentPlaylistItem?.evictedAt != nil || playbackController.currentTrack?.isEvicted == true {
                Label("Evicted", systemImage: "trash.fill")
                    .foregroundStyle(.red)
            }
            if playbackController.currentPlaylistItem?.protected == true || playbackController.currentTrack?.protected == true {
                Label("Protected", systemImage: "shield.fill")
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
                    Label("Shuffle", systemImage: playbackController.shuffleEnabled ? "shuffle.circle.fill" : "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(playbackController.shuffleEnabled ? .accentColor : .secondary.opacity(0.24))

                Button {
                    playbackController.toggleRepeat()
                    runtime.remoteCommandService.syncPlaybackModes(from: playbackController)
                } label: {
                    Label("Repeat \(playbackController.repeatModeTitle)", systemImage: repeatIconName)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(playbackController.repeatEnabled ? .accentColor : .secondary.opacity(0.24))
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

    private var repeatIconName: String {
        "repeat"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let totalSeconds = max(Int(seconds), 0)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
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
