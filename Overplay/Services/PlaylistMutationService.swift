import Foundation
@preconcurrency import MusicKit
import SwiftData

enum PlaylistMutationError: LocalizedError {
    case oneTruePlaylistMissing
    case sourcePlaylistMissing
    case sourcePlaylistNotTriage
    case trackMissing
    case musicItemMissing
    case playlistIncomingOnly

    var errorDescription: String? {
        switch self {
        case .oneTruePlaylistMissing:
            "Choose a One True Playlist before promoting tracks."
        case .sourcePlaylistMissing:
            "The source playlist is no longer linked."
        case .sourcePlaylistNotTriage:
            "Only tracks from triage playlists can be promoted."
        case .trackMissing:
            "The track is no longer available locally."
        case .musicItemMissing:
            "This track does not have an Apple Music identifier Overplay can add."
        case .playlistIncomingOnly:
            "This playlist is incoming only, so Overplay will not write changes back to Apple Music."
        }
    }
}

@MainActor
struct PlaylistMutationService {
    @discardableResult
    func promote(item sourceItem: PlaylistItemRecord, in context: ModelContext) async throws -> PlaylistItemRecord {
        guard let oneTruePlaylist = try PlaylistRepository.oneTruePlaylist(in: context) else {
            throw PlaylistMutationError.oneTruePlaylistMissing
        }
        guard let sourcePlaylist = try PlaylistRepository.playlist(id: sourceItem.playlistID, in: context) else {
            throw PlaylistMutationError.sourcePlaylistMissing
        }
        guard sourcePlaylist.role == .triage else {
            throw PlaylistMutationError.sourcePlaylistNotTriage
        }
        guard let track = try TrackRecordRepository.track(id: sourceItem.trackID, in: context) else {
            throw PlaylistMutationError.trackMissing
        }
        guard oneTruePlaylist.allowsRemoteWrites else {
            throw PlaylistMutationError.playlistIncomingOnly
        }

        do {
            try await add(track: track, to: oneTruePlaylist, in: context)
            let promotedItem = try recordSuccessfulPromotion(
                sourceItem: sourceItem,
                sourcePlaylist: sourcePlaylist,
                oneTruePlaylist: oneTruePlaylist,
                track: track,
                in: context
            )
            try context.save()
            return promotedItem
        } catch {
            EventRepository.logHistory(
                playlistID: sourcePlaylist.id,
                trackID: sourceItem.trackID,
                eventType: .remoteMutation,
                source: .user,
                skipCountAtEvent: sourceItem.skipCount,
                remoteMutationStatus: .failed,
                message: "Promotion failed: \(error.localizedDescription)",
                in: context
            )
            try? context.save()
            throw error
        }
    }

    @discardableResult
    func recordSuccessfulPromotion(
        sourceItem: PlaylistItemRecord,
        sourcePlaylist: PlaylistRecord,
        oneTruePlaylist: PlaylistRecord,
        track: TrackRecord,
        promotedAt: Date = .now,
        in context: ModelContext
    ) throws -> PlaylistItemRecord {
        guard sourcePlaylist.role == .triage else {
            throw PlaylistMutationError.sourcePlaylistNotTriage
        }

        let promotedItem = try PlaylistItemRepository.upsert(
            playlistID: oneTruePlaylist.id,
            trackID: track.id,
            in: context
        )
        promotedItem.evictedAt = nil
        promotedItem.evictionReason = nil
        promotedItem.evictionSource = nil
        promotedItem.lastSeenInPlaylistAt = promotedAt
        promotedItem.updatedAt = promotedAt
        try appendToLocalOrder(item: promotedItem, playlist: oneTruePlaylist, in: context)

        EventRepository.logHistory(
            playlistID: sourcePlaylist.id,
            trackID: track.id,
            eventType: .promoted,
            source: .user,
            skipCountAtEvent: sourceItem.skipCount,
            remoteMutationStatus: .succeeded,
            message: "Promoted to \(oneTruePlaylist.name)",
            in: context
        )

        if sourceItem.evictedAt == nil {
            EvictionEngine.evict(
                sourceItem,
                playlist: sourcePlaylist,
                reason: .manual,
                source: .user,
                message: "Promoted to \(oneTruePlaylist.name)",
                context: context
            )
        }

        return promotedItem
    }

    @discardableResult
    func recordSuccessfulManualAdd(
        _ result: SearchSongResult,
        to playlist: PlaylistRecord,
        addedAt: Date = .now,
        in context: ModelContext
    ) throws -> PlaylistItemRecord {
        let track = try TrackRecordRepository.upsert(
            catalogID: result.id,
            libraryID: result.id,
            title: result.title,
            artistName: result.artistName,
            albumTitle: result.albumTitle,
            artworkURLTemplate: result.artworkURL,
            updatedAt: addedAt,
            in: context
        )
        let item = try PlaylistItemRepository.upsert(
            playlistID: playlist.id,
            trackID: track.id,
            in: context
        )
        item.evictedAt = nil
        item.evictionReason = nil
        item.evictionSource = nil
        item.lastSeenInPlaylistAt = addedAt
        item.updatedAt = addedAt
        try appendToLocalOrder(item: item, playlist: playlist, in: context)

        EventRepository.logHistory(
            playlistID: playlist.id,
            trackID: track.id,
            eventType: .trackAdded,
            source: .user,
            remoteMutationStatus: .succeeded,
            message: "Added to \(playlist.name)",
            in: context
        )

        try context.save()
        return item
    }

    func recordFailedManualAdd(
        _ result: SearchSongResult,
        to playlist: PlaylistRecord?,
        message: String,
        in context: ModelContext
    ) {
        EventRepository.logHistory(
            playlistID: playlist?.id,
            eventType: .remoteMutation,
            source: .user,
            remoteMutationStatus: .failed,
            message: "Add failed for \(result.title): \(message)",
            in: context
        )
        try? context.save()
    }

    private func add(track: TrackRecord, to playlistRecord: PlaylistRecord, in context: ModelContext) async throws {
        guard let musicItemID = track.catalogID ?? track.libraryID else {
            throw PlaylistMutationError.musicItemMissing
        }

        let playlist = try await PlaylistSyncService().loadPlaylist(
            id: playlistRecord.musicPlaylistID,
            name: playlistRecord.name,
            playlistRecord: playlistRecord,
            in: context
        )
        let song = try await song(id: musicItemID)
        try await MusicLibrary.shared.add(song, to: playlist)
    }

    private func song(id: String) async throws -> Song {
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        request.limit = 1
        guard let song = try await request.response().items.first else {
            throw PlaylistMutationError.musicItemMissing
        }
        return song
    }

    private func appendToLocalOrder(
        item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        in context: ModelContext
    ) throws {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        PlaybackOrderCoordinator.appendTrackIDs(
            [item.trackID.uuidString],
            playerID: "main",
            playlistID: playlist.musicPlaylistID,
            orderTracks: PlaybackQueueBuilder.playbackOrderTracks(items: items)
        )
    }
}
