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
        let tracks = try TrackRecordRepository.allTracks(in: context)
        let builder = PlaylistPresentationBuilder(
            playlists: playlists,
            items: items,
            tracks: tracks,
            evictAfterSkips: 0
        )

        return builder.activePlaylistSummaries().map { summary in
            CarPlayPlaylistSummary(
                id: summary.id,
                musicPlaylistID: summary.musicPlaylistID ?? "",
                title: summary.title,
                role: summary.role,
                displayPriority: summary.displayPriority,
                playableTrackCount: summary.playableTrackCount
            )
        }
    }

    static func trackSummaries(
        forPlaylistID playlistID: UUID,
        evictAfterSkips: Int,
        in context: ModelContext
    ) throws -> [CarPlayTrackSummary] {
        let items = try PlaylistItemRepository.playableItems(forPlaylistID: playlistID, in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)
        let builder = PlaylistPresentationBuilder(
            playlists: [],
            items: items,
            tracks: tracks,
            evictAfterSkips: evictAfterSkips
        )

        return builder.trackSummaries(forPlaylistID: playlistID).map { summary in
            CarPlayTrackSummary(
                id: summary.id,
                playlistID: summary.playlistID ?? playlistID,
                trackID: summary.trackID ?? summary.id,
                title: summary.title,
                artistName: summary.artistName,
                skipCount: summary.skipCount,
                healthStatus: summary.healthStatus ?? .healthy
            )
        }
    }
}
