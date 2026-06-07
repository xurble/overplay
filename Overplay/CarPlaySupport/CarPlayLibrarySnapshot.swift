import Foundation
import SwiftData

struct CarPlayPlaylistSummary: Equatable, Identifiable {
    let id: UUID
    let musicPlaylistID: String
    let title: String
    let role: PlaylistRole
    let displayPriority: Int
    let playableTrackCount: Int

    var isOneTruePlaylist: Bool {
        role == .oneTruePlaylist
    }

    var detailText: String {
        PlaylistSummaryPresentation(
            id: id,
            title: title,
            role: role,
            writePolicy: .managed,
            activeTrackCount: playableTrackCount,
            playableTrackCount: playableTrackCount,
            lastSyncedAt: nil,
            isCurrentPlaybackPlaylist: false
        )
        .playableTrackCountLabel
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
        TrackSummaryPresentation(
            id: id,
            title: title,
            artistName: artistName,
            albumTitle: nil,
            skipCount: skipCount
        )
        .detailText
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
                let presentation = PlaylistSummaryPresentation(
                    id: playlist.id,
                    title: playlist.name,
                    role: playlist.role,
                    writePolicy: playlist.writePolicy,
                    activeTrackCount: playableCounts[playlist.id, default: 0],
                    playableTrackCount: playableCounts[playlist.id, default: 0],
                    lastSyncedAt: playlist.lastSyncedAt,
                    isCurrentPlaybackPlaylist: false
                )
                return CarPlayPlaylistSummary(
                    id: playlist.id,
                    musicPlaylistID: playlist.musicPlaylistID,
                    title: presentation.title,
                    role: playlist.role,
                    displayPriority: presentation.displayPriority,
                    playableTrackCount: presentation.playableTrackCount
                )
            }
            .sorted { left, right in
                if left.displayPriority != right.displayPriority {
                    return left.displayPriority < right.displayPriority
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
