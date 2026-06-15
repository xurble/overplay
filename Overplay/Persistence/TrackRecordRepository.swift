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
        try upsertWithResult(
            catalogID: snapshot.catalogID ?? snapshot.id,
            libraryID: snapshot.libraryID ?? snapshot.id,
            title: snapshot.title,
            artistName: snapshot.artistName,
            albumTitle: snapshot.albumTitle,
            artworkURLTemplate: snapshot.artworkURLTemplate,
            durationSeconds: snapshot.durationSeconds,
            musicKitPlaybackData: snapshot.musicKitPlaybackData,
            in: context
        ).record
    }

    @discardableResult
    static func upsertWithResult(_ snapshot: TrackSnapshot, in context: ModelContext) throws -> TrackRecordUpsertResult {
        try upsertWithResult(
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
        try upsertWithResult(
            catalogID: catalogID,
            libraryID: libraryID,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            artworkURLTemplate: artworkURLTemplate,
            durationSeconds: durationSeconds,
            musicKitPlaybackData: musicKitPlaybackData,
            createdAt: createdAt,
            updatedAt: updatedAt,
            in: context
        ).record
    }

    @discardableResult
    static func upsertWithResult(
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
    ) throws -> TrackRecordUpsertResult {
        guard let track = try track(catalogID: catalogID, libraryID: libraryID, in: context) else {
            let insertedTrack = TrackRecord(
                catalogID: catalogID,
                libraryID: libraryID,
                title: title,
                artistName: artistName,
                albumTitle: albumTitle,
                artworkURLTemplate: artworkURLTemplate,
                durationSeconds: durationSeconds,
                musicKitPlaybackData: musicKitPlaybackData,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            context.insert(insertedTrack)
            return TrackRecordUpsertResult(
                record: insertedTrack,
                mutation: .inserted,
                shouldWarmUpArtworkTheme: true
            )
        }

        var didChange = false
        var artworkThemeInputsChanged = false

        assign(catalogID, to: \.catalogID, on: track, didChange: &didChange)
        assign(libraryID, to: \.libraryID, on: track, didChange: &didChange)
        assign(title, to: \.title, on: track, didChange: &didChange, artworkThemeInputsChanged: &artworkThemeInputsChanged)
        assign(artistName, to: \.artistName, on: track, didChange: &didChange, artworkThemeInputsChanged: &artworkThemeInputsChanged)
        assign(albumTitle, to: \.albumTitle, on: track, didChange: &didChange, artworkThemeInputsChanged: &artworkThemeInputsChanged)

        if track.artworkURLTemplate == nil, let artworkURLTemplate {
            assign(artworkURLTemplate, to: \.artworkURLTemplate, on: track, didChange: &didChange, artworkThemeInputsChanged: &artworkThemeInputsChanged)
        }

        assign(durationSeconds, to: \.durationSeconds, on: track, didChange: &didChange)
        if let musicKitPlaybackData {
            assign(musicKitPlaybackData, to: \.musicKitPlaybackData, on: track, didChange: &didChange)
        }

        if didChange {
            track.updatedAt = updatedAt
        }

        return TrackRecordUpsertResult(
            record: track,
            mutation: didChange ? .updated : .unchanged,
            shouldWarmUpArtworkTheme: artworkThemeInputsChanged
        )
    }

    private static func assign<Value: Equatable>(
        _ value: Value,
        to keyPath: ReferenceWritableKeyPath<TrackRecord, Value>,
        on track: TrackRecord,
        didChange: inout Bool,
        artworkThemeInputsChanged: inout Bool
    ) {
        guard track[keyPath: keyPath] != value else { return }
        track[keyPath: keyPath] = value
        didChange = true
        artworkThemeInputsChanged = true
    }

    private static func assign<Value: Equatable>(
        _ value: Value,
        to keyPath: ReferenceWritableKeyPath<TrackRecord, Value>,
        on track: TrackRecord,
        didChange: inout Bool
    ) {
        guard track[keyPath: keyPath] != value else { return }
        track[keyPath: keyPath] = value
        didChange = true
    }
}
