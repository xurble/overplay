import Foundation
import SwiftData

struct CarPlayPlaylistSummary: Equatable, Identifiable {
    let id: UUID
    let musicPlaylistID: String
    let title: String
    let role: PlaylistRole
    let playableTrackCount: Int

    var isOneTruePlaylist: Bool {
        role == .oneTruePlaylist
    }

    var detailText: String {
        let trackLabel = playableTrackCount == 1 ? "1 playable track" : "\(playableTrackCount) playable tracks"
        switch role {
        case .oneTruePlaylist:
            return "One True Playlist - \(trackLabel)"
        case .triage:
            return "Linked playlist - \(trackLabel)"
        }
    }
}

enum CarPlayLibrarySnapshot {
    static func playlistSummaries(in context: ModelContext) throws -> [CarPlayPlaylistSummary] {
        let playlists = try PlaylistRepository.activePlaylists(in: context)
        let items = try PlaylistItemRepository.allItems(in: context)

        let playableCounts = Dictionary(grouping: items.filter(\.isPlayable), by: \.playlistID)
            .mapValues(\.count)

        return playlists
            .map { playlist in
                CarPlayPlaylistSummary(
                    id: playlist.id,
                    musicPlaylistID: playlist.musicPlaylistID,
                    title: playlist.name,
                    role: playlist.role,
                    playableTrackCount: playableCounts[playlist.id, default: 0]
                )
            }
            .sorted { left, right in
                if left.role != right.role {
                    return left.role == .oneTruePlaylist
                }
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
    }
}
