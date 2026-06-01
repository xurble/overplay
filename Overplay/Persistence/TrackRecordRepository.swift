import Foundation
import SwiftData

enum TrackRecordRepository {
    static func allTracks(in context: ModelContext) throws -> [TrackRecord] {
        let descriptor = FetchDescriptor<TrackRecord>(
            sortBy: [SortDescriptor(\.title), SortDescriptor(\.artistName)]
        )
        return try context.fetch(descriptor)
    }

    static func track(id: UUID, in context: ModelContext) throws -> TrackRecord? {
        try allTracks(in: context).first { $0.id == id }
    }

    static func track(catalogID: String?, libraryID: String?, in context: ModelContext) throws -> TrackRecord? {
        try allTracks(in: context).first { track in
            if let catalogID, track.catalogID == catalogID {
                return true
            }
            if let libraryID, track.libraryID == libraryID {
                return true
            }
            return false
        }
    }

    static func track(musicItemID: String, in context: ModelContext) throws -> TrackRecord? {
        try track(catalogID: musicItemID, libraryID: musicItemID, in: context)
    }

    @discardableResult
    static func upsert(_ snapshot: TrackSnapshot, in context: ModelContext) throws -> TrackRecord {
        try upsert(
            catalogID: snapshot.catalogID ?? snapshot.id,
            libraryID: snapshot.libraryID ?? snapshot.id,
            title: snapshot.title,
            artistName: snapshot.artistName,
            albumTitle: snapshot.albumTitle,
            artworkURLTemplate: snapshot.artworkURLTemplate,
            durationSeconds: snapshot.durationSeconds,
            musicKitPlaybackData: snapshot.musicKitPlaybackData,
            in: context
        )
    }

    @discardableResult
    static func upsert(
        catalogID: String?,
        libraryID: String?,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURLTemplate: String? = nil,
        durationSeconds: Double? = nil,
        musicKitPlaybackData: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        in context: ModelContext
    ) throws -> TrackRecord {
        let track = try track(catalogID: catalogID, libraryID: libraryID, in: context) ?? TrackRecord(
            catalogID: catalogID,
            libraryID: libraryID,
            title: title,
            artistName: artistName,
            musicKitPlaybackData: musicKitPlaybackData,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        if track.modelContext == nil {
            context.insert(track)
        }

        track.catalogID = catalogID
        track.libraryID = libraryID
        track.title = title
        track.artistName = artistName
        track.albumTitle = albumTitle
        track.artworkURLTemplate = artworkURLTemplate
        track.durationSeconds = durationSeconds
        if let musicKitPlaybackData {
            track.musicKitPlaybackData = musicKitPlaybackData
        }
        track.updatedAt = updatedAt
        return track
    }

    static func resetPlaylistStats(in context: ModelContext) throws {
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        for item in items {
            item.skipCount = 0
            item.playthroughCount = 0
            item.lastPlayedAt = nil
            item.lastSkippedAt = nil
            item.evictedAt = nil
            item.evictionReason = nil
            item.evictionSource = nil
            item.protected = false
            item.updatedAt = .now
        }

        try context.save()
    }
}
