import SwiftData
import SwiftUI

struct PlaylistSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [AppleMusicPlaylist] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading playlists")
            }

            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            ForEach(filteredPlaylists) { playlist in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name)
                                .font(.headline)
                            if let trackCount = playlist.trackCount {
                                Text("\(trackCount) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if playlist.isPreferredOverplayPlaylist {
                            Label("Pinned", systemImage: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.pink)
                        }
                    }

                    Button {
                        select(playlist)
                    } label: {
                        Label("Use This Playlist", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("Choose Playlist")
        .searchable(text: $searchText, prompt: "Filter playlists")
        .refreshable {
            await loadPlaylists()
        }
        .task {
            await loadPlaylists()
        }
    }

    private var filteredPlaylists: [AppleMusicPlaylist] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func loadPlaylists() async {
        isLoading = true
        defer { isLoading = false }

        do {
            playlists = try await PlaylistSyncService().fetchLibraryPlaylists()
            message = playlists.isEmpty ? "No Apple Music library playlists were found." : nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func select(_ playlist: AppleMusicPlaylist) {
        do {
            try SettingsRepository.selectPlaylist(playlist, in: modelContext)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        PlaylistSelectionView()
    }
    .modelContainer(PreviewContainer.make())
}
