import SwiftData
import SwiftUI

struct SplitAppShell: View {
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings

    @SceneStorage("overplay.splitSelection") private var storedSelection = AppShellDestination.dashboard.storageValue

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    Label("Dashboard", systemImage: "rectangle.grid.2x2")
                        .tag(AppShellDestination.dashboard)
                    Label("Search", systemImage: "magnifyingglass")
                        .tag(AppShellDestination.search)
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(AppShellDestination.history)
                    Label("Settings", systemImage: "gearshape")
                        .tag(AppShellDestination.settings)
                }

                Section("Playlists") {
                    ForEach(activePlaylists) { playlist in
                        Label(playlist.name, systemImage: playlistIcon(for: playlist))
                            .tag(AppShellDestination.playlist(playlist.id))
                    }

                    Label("Manage Links", systemImage: "music.note.list")
                        .tag(AppShellDestination.linkedPlaylists)
                }
            }
            .miniPlayerScrollContentInset()
            .listStyle(.sidebar)
            .navigationTitle("Overplay")
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedDestination {
        case .dashboard:
            DashboardView(settings: settings)
        case let .playlist(playlistID):
            if let playlist = activePlaylists.first(where: { $0.id == playlistID }) {
                PlaylistManagementView(settings: settings, playlist: playlist)
            } else {
                ContentUnavailableView(
                    "Playlist Unavailable",
                    systemImage: "music.note.list",
                    description: Text("Choose another linked playlist from the sidebar.")
                )
            }
        case .search:
            SearchMusicView(settings: settings)
        case .history:
            HistoryView()
        case .settings:
            SettingsView(settings: settings)
        case .linkedPlaylists:
            PlaylistSelectionView()
        }
    }

    private var activePlaylists: [PlaylistRecord] {
        playlists
            .filter(\.isActive)
            .sorted { left, right in
                if left.role != right.role {
                    return left.role == .oneTruePlaylist
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func playlistIcon(for playlist: PlaylistRecord) -> String {
        switch playlist.role {
        case .oneTruePlaylist:
            "star.fill"
        case .triage:
            "tray.fill"
        }
    }

    private var selectedDestination: AppShellDestination {
        AppShellDestination(storageValue: storedSelection) ?? .dashboard
    }

    private var selection: Binding<AppShellDestination?> {
        Binding {
            selectedDestination
        } set: { newSelection in
            storedSelection = (newSelection ?? .dashboard).storageValue
        }
    }
}
