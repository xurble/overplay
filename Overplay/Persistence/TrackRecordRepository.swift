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
        if let libraryID {
            var library = FetchDescriptor<TrackRecord>(predicate: #Predicate { $0.libraryID == libraryID })
            library.fetchLimit = 1
            library.includePendingChanges = true
            if let exact = try context.fetch(library).first { return exact }
        }
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
        if let exact = try context.fetch(limitedDescriptor).first { return exact }
        let identifiers = Set([catalogID, libraryID].compactMap { $0 })
        return try allTracks(in: context).first { !identifiers.isDisjoint(with: $0.identityAliases) }
    }

    static func track(musicItemID: String, in context: ModelContext) throws -> TrackRecord? {
        try track(catalogID: musicItemID, libraryID: musicItemID, in: context)
    }

    @discardableResult
    static func upsert(_ snapshot: TrackSnapshot, in context: ModelContext) throws -> TrackRecord {
        try upsertWithResult(snapshot, in: context).record
    }

    @discardableResult
    static func upsertWithResult(_ snapshot: TrackSnapshot, in context: ModelContext) throws -> TrackRecordUpsertResult {
        var identity = snapshot.resolvedIdentity
        if !snapshot.hasDocumentedIdentity,
           let existing = try track(catalogID: identity.catalogID, libraryID: identity.libraryID, in: context),
           existing.hasDocumentedIdentity {
            identity.catalogID = existing.catalogID
            identity.libraryID = existing.libraryID
        }
        let result = try upsertWithResult(
            catalogID: identity.catalogID, libraryID: identity.libraryID,
            title: snapshot.title, artistName: snapshot.artistName, albumTitle: snapshot.albumTitle,
            artworkURLTemplate: snapshot.artworkURLTemplate, durationSeconds: snapshot.durationSeconds,
            musicKitPlaybackData: snapshot.musicKitPlaybackData, in: context
        )
        let changed = applyIdentity(snapshot, to: result.record)
        if changed { result.record.updatedAt = .now }
        return TrackRecordUpsertResult(record: result.record,
            mutation: result.mutation == .unchanged && changed ? .updated : result.mutation,
            shouldWarmUpArtworkTheme: result.shouldWarmUpArtworkTheme)
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

        assignIdentifier(catalogID, to: \.catalogID, on: track, didChange: &didChange)
        assignIdentifier(libraryID, to: \.libraryID, on: track, didChange: &didChange)
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

    @discardableResult
    static func applyIdentity(_ snapshot: TrackSnapshot, to track: TrackRecord) -> Bool {
        let old: [String?] = [track.catalogID, track.isrc, String(track.hasDocumentedIdentity), track.identityAliases.joined(separator: ","), track.equivalentCatalogIDs.joined(separator: ",")]
        if let isrc = snapshot.isrc { track.isrc = isrc }
        if snapshot.hasDocumentedIdentity {
            track.hasDocumentedIdentity = true
            // A documented empty library relationship overrides an opaque hint.
            if snapshot.libraryID != nil { track.catalogID = snapshot.catalogID }
            track.equivalentCatalogIDs = snapshot.equivalentCatalogIDs
        }
        track.identityAliases = Array(Set(track.identityAliases + snapshot.identityAliases)).sorted()
        return old != [track.catalogID, track.isrc, String(track.hasDocumentedIdentity), track.identityAliases.joined(separator: ","), track.equivalentCatalogIDs.joined(separator: ",")]
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

    /// Catalog/library IDs are fill-and-heal only: an incoming nil must never
    /// erase a known identifier, because most sources see only one ID domain.
    private static func assignIdentifier(
        _ value: String?,
        to keyPath: ReferenceWritableKeyPath<TrackRecord, String?>,
        on track: TrackRecord,
        didChange: inout Bool
    ) {
        guard let value, track[keyPath: keyPath] != value else { return }
        track[keyPath: keyPath] = value
        didChange = true
    }
}
