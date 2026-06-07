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
            return trackLabel
        case .triage:
            return trackLabel
        }
    }
}

struct CarPlayTrackSummary: Equatable, Identifiable {
    let id: UUID
    let playlistID: UUID
    let trackID: UUID
    let title: String
    let artistName: String
    let skipCount: Int
    let healthStatus: TrackHealthStatus

    var detailText: String {
        guard skipCount > 0 else {
            return artistName
        }

        let skipLabel = skipCount == 1 ? "1 skip" : "\(skipCount) skips"
        return "\(artistName) - \(skipLabel)"
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

    static func trackSummaries(
        forPlaylistID playlistID: UUID,
        evictAfterSkips: Int,
        in context: ModelContext
    ) throws -> [CarPlayTrackSummary] {
        let items = try PlaylistItemRepository.playableItems(forPlaylistID: playlistID, in: context)
        let tracksByID = Dictionary(uniqueKeysWithValues: try TrackRecordRepository.allTracks(in: context).map { ($0.id, $0) })

        return items.compactMap { item in
            guard let track = tracksByID[item.trackID] else { return nil }

            return CarPlayTrackSummary(
                id: item.id,
                playlistID: item.playlistID,
                trackID: track.id,
                title: track.title,
                artistName: track.artistName,
                skipCount: item.skipCount,
                healthStatus: TrackHealthStatus.resolve(
                    skipCount: item.skipCount,
                    evictAfterSkips: evictAfterSkips,
                    isEvicted: item.evictedAt != nil,
                    isProtected: item.protected
                )
            )
        }
    }
}
