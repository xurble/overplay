import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]

    var settings: OverplaySettings
    @State private var isSyncing = false
    @State private var message: String?
    @State private var showNowPlaying = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(settings.selectedPlaylistName ?? "No playlist selected")
                        .font(.title2.bold())
                    Text("Overplay tracks skips locally and keeps Apple Music playlist removal as a safe follow-up spike.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCardView(title: "Known", value: "\(dashboardSummary.knownCount)", systemImage: "music.note.list", tint: .pink)
                    StatCardView(title: "Playable", value: "\(dashboardSummary.playableCount)", systemImage: "play.circle.fill", tint: .green)
                    StatCardView(title: "Evicted", value: "\(dashboardSummary.evictedCount)", systemImage: "trash.fill", tint: .red)
                    StatCardView(title: "At risk", value: "\(dashboardSummary.atRiskCount)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                Button {
                    Task {
                        await playbackController.playPlaylist(settings: settings, context: modelContext)
                        showNowPlaying = true
                    }
                } label: {
                    Label("Play Overplay", systemImage: "play.fill")
                }
                .disabled(settings.selectedPlaylistID == nil)

                Button {
                    Task { await syncPlaylist() }
                } label: {
                    Label(isSyncing ? "Syncing Playlist" : "Sync Playlist", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(settings.selectedPlaylistID == nil || isSyncing)

                NavigationLink {
                    SearchMusicView(settings: settings)
                } label: {
                    Label("Search Apple Music", systemImage: "magnifyingglass")
                }
                .disabled(settings.selectedPlaylistID == nil)

                NavigationLink {
                    SettingsView(settings: settings)
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }

                NavigationLink {
                    EvictionHistoryView()
                } label: {
                    Label("Eviction History", systemImage: "clock.arrow.circlepath")
                }
            }

            if let message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Overplay")
        .toolbar {
            NavigationLink {
                PlaylistSelectionView()
            } label: {
                Image(systemName: "music.note.list")
            }
            .accessibilityLabel("Change playlist")
        }
        .navigationDestination(isPresented: $showNowPlaying) {
            NowPlayingView(settings: settings)
        }
    }

    private var selectedPlaylist: PlaylistRecord? {
        guard let playlistID = settings.selectedPlaylistID else { return nil }
        return playlists.first { $0.musicPlaylistID == playlistID && $0.role == .oneTruePlaylist }
    }

    private var selectedPlaylistItems: [PlaylistItemRecord] {
        guard let selectedPlaylist else { return [] }
        return playlistItems.filter { $0.playlistID == selectedPlaylist.id }
    }

    private var dashboardSummary: DashboardSummary {
        DashboardSummary(items: selectedPlaylistItems, evictAfterSkips: settings.evictAfterSkips)
    }

    private func syncPlaylist() async {
        guard let playlistID = settings.selectedPlaylistID else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let count = try await PlaylistSyncService().syncPlaylist(id: playlistID, in: modelContext)
            try? LegacyModelMigration.migrate(in: modelContext)
            message = "Synced \(count) tracks."
        } catch {
            message = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        DashboardView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
