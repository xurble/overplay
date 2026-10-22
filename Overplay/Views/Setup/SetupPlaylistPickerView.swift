import SwiftUI

/// Chooses the Apple Music playlist whose songs start the One True Playlist.
struct SetupPlaylistPickerView: View {
    let playlists: [AppleMusicPlaylist]
    let isLoading: Bool
    let onChoose: (AppleMusicPlaylist) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(filtered) { playlist in
                Button {
                    dismiss()
                    onChoose(playlist)
                } label: {
                    SetupPlaylistRowView(playlist: playlist)
                }
                .tint(.primary)
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading playlists")
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: "Filter playlists")
            .navigationTitle("Copy a Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private var filtered: [AppleMusicPlaylist] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

/// A library playlist's name and song count.
struct SetupPlaylistRowView: View {
    let playlist: AppleMusicPlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.name)
            if let count = playlist.trackCount {
                Text(count == 1 ? "1 song" : "\(count) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    SetupPlaylistPickerView(
        playlists: [
            AppleMusicPlaylist(id: "1", name: "Favourites", trackCount: 120),
            AppleMusicPlaylist(id: "2", name: "TikTok Songs", trackCount: 48),
        ],
        isLoading: false
    ) { _ in }
}
