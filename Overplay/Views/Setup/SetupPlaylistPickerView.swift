import SwiftUI

/// Chooses the Apple Music playlist whose songs start the One True Playlist.
struct SetupPlaylistPickerView: View {
    let playlists: [AppleMusicPlaylist]
    var details: [String: LibraryBrowser.Item] = [:]
    let isLoading: Bool
    let onChoose: (AppleMusicPlaylist) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered) { playlist in
                        Button {
                            dismiss()
                            onChoose(playlist)
                        } label: {
                            SetupPlaylistRowView(playlist: playlist, details: details[playlist.id])
                                .contentShape(.rect)
                        }
                        .tint(.primary)
                    }
                } footer: {
                    Text("Overplay copies its songs into a new playlist. The one you choose is left as it is.")
                }
            }
            .listStyle(.insetGrouped)
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
                        .untinted()
                }
            }
        }
    }

    private var filtered: [AppleMusicPlaylist] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

/// A library playlist in setup: its artwork, name, and curator or song
/// count, with a checkmark where it can be chosen.
struct SetupPlaylistRowView: View {
    let playlist: AppleMusicPlaylist
    var details: LibraryBrowser.Item?
    /// Nil where the row is not a toggle.
    var isSelected: Bool?
    /// Artwork for a playlist that is not in the library, such as a Made For
    /// You mix.
    var artworkURL: String? = nil

    private static let artworkSide: CGFloat = 52

    var body: some View {
        HStack(spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var artwork: some View {
        if let artwork = details?.artwork {
            LibraryArtworkView(artwork: artwork, side: Self.artworkSide, cornerRadius: 10)
        } else if let artworkURL {
            ArtworkView(urlString: artworkURL, pixelSize: 128, cornerRadius: 10)
                .frame(width: Self.artworkSide, height: Self.artworkSide)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .frame(width: Self.artworkSide, height: Self.artworkSide)
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let curator = details?.subtitle, !curator.isEmpty { parts.append(curator) }
        if let count = playlist.trackCount { parts.append(count == 1 ? "1 song" : "\(count) songs") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
