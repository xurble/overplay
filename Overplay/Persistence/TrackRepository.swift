import Foundation
import SwiftData

enum TrackRepository {
    static func allTracks(in context: ModelContext) throws -> [TrackedTrack] {
        let descriptor = FetchDescriptor<TrackedTrack>(
            sortBy: [SortDescriptor(\.title), SortDescriptor(\.artistName)]
        )
        return try context.fetch(descriptor)
    }

    static func track(id: String, in context: ModelContext) throws -> TrackedTrack? {
        try allTracks(in: context).first { $0.id == id }
    }

    static func tracks(forPlaylistID playlistID: String, in context: ModelContext) throws -> [TrackedTrack] {
        try allTracks(in: context).filter { $0.playlistID == playlistID }
    }

    static func playableTracks(forPlaylistID playlistID: String, in context: ModelContext) throws -> [TrackedTrack] {
        try tracks(forPlaylistID: playlistID, in: context).filter { !$0.isEvicted }
    }

    @discardableResult
    static func upsert(_ snapshot: TrackSnapshot, in context: ModelContext) throws -> TrackedTrack {
        let track = try track(id: snapshot.id, in: context) ?? TrackedTrack(
            id: snapshot.id,
            title: snapshot.title,
            artistName: snapshot.artistName
        )

        if track.modelContext == nil {
            context.insert(track)
        }

        track.catalogID = snapshot.catalogID
        track.libraryID = snapshot.libraryID
        track.playlistEntryID = snapshot.playlistEntryID
        track.playlistID = snapshot.playlistID
        track.title = snapshot.title
        track.artistName = snapshot.artistName
        track.albumTitle = snapshot.albumTitle
        track.artworkURLTemplate = snapshot.artworkURLTemplate
        track.durationSeconds = snapshot.durationSeconds
        track.lastSeenInPlaylistAt = .now
        track.updatedAt = .now
        return track
    }

    static func resetStats(in context: ModelContext) throws {
        let tracks = try allTracks(in: context)
        for track in tracks {
            track.skipCount = 0
            track.playthroughCount = 0
            track.lastPlayedAt = nil
            track.lastSkippedAt = nil
            track.evictedAt = nil
            track.evictionReason = nil
            track.protected = false
            track.updatedAt = .now
        }

        let events = try context.fetch(FetchDescriptor<PlaybackEvent>())
        for event in events {
            context.delete(event)
        }

        try context.save()
    }
}
