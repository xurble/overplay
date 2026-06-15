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
        var descriptor = FetchDescriptor<TrackRecord>(
            predicate: #Predicate { $0.id == id },
            sortBy: [SortDescriptor(\.title), SortDescriptor(\.artistName)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    static func tracks(ids: [UUID], in context: ModelContext) throws -> [TrackRecord] {
        guard !ids.isEmpty else { return [] }
        let uniqueIDs = Array(Set(ids))
        var descriptor = FetchDescriptor<TrackRecord>(
            predicate: #Predicate { uniqueIDs.contains($0.id) },
            sortBy: [SortDescriptor(\.title), SortDescriptor(\.artistName)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    static func track(catalogID: String?, libraryID: String?, in context: ModelContext) throws -> TrackRecord? {
        let descriptor: FetchDescriptor<TrackRecord>
        if let catalogID, let libraryID {
            descriptor = FetchDescriptor<TrackRecord>(
                predicate: #Predicate {
                    $0.catalogID == catalogID || $0.libraryID == libraryID
                },
                sortBy: [SortDescriptor(\.title), SortDescriptor(\.artistName)]
            )
        } else if let catalogID {
            descriptor = FetchDescriptor<TrackRecord>(
                predicate: #Predicate { $0.catalogID == catalogID },
                sortBy: [SortDescriptor(\.title), SortDescriptor(\.artistName)]
            )
        } else if let libraryID {
            descriptor = FetchDescriptor<TrackRecord>(
                predicate: #Predicate { $0.libraryID == libraryID },
                sortBy: [SortDescriptor(\.title), SortDescriptor(\.artistName)]
            )
        } else {
            return nil
        }
        var limitedDescriptor = descriptor
        limitedDescriptor.fetchLimit = 1
        limitedDescriptor.includePendingChanges = true
        return try context.fetch(limitedDescriptor).first
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
        if track.artworkURLTemplate == nil {
            track.artworkURLTemplate = artworkURLTemplate
        }
        track.durationSeconds = durationSeconds
        if let musicKitPlaybackData {
            track.musicKitPlaybackData = musicKitPlaybackData
        }
        track.updatedAt = updatedAt
        return track
    }
}
