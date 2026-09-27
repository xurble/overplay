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

    static func track(catalogID: String?, libraryID: String?, libraryScope: String = MusicResourceReference.currentLibraryScope, in context: ModelContext) throws -> TrackRecord? {
        if let libraryID {
            var library = FetchDescriptor<TrackRecord>(predicate: #Predicate { $0.libraryID == libraryID && $0.libraryScope == libraryScope })
            library.fetchLimit = 1
            library.includePendingChanges = true
            if let exact = try context.fetch(library).first { return exact }
        }
        let descriptor: FetchDescriptor<TrackRecord>
        if let catalogID, let libraryID {
            descriptor = FetchDescriptor<TrackRecord>(
                predicate: #Predicate {
                    $0.catalogID == catalogID || $0.libraryID == libraryID && $0.libraryScope == libraryScope
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
                predicate: #Predicate { $0.libraryID == libraryID && $0.libraryScope == libraryScope },
                sortBy: [SortDescriptor(\.title), SortDescriptor(\.artistName)]
            )
        } else {
            return nil
        }
        var limitedDescriptor = descriptor
        limitedDescriptor.fetchLimit = 1
        limitedDescriptor.includePendingChanges = true
        if let exact = try context.fetch(limitedDescriptor).first { return exact }
        let references = Set([catalogID.map { MusicResourceReference.catalog($0) },
                              libraryID.map { MusicResourceReference.library($0, scope: libraryScope) }].compactMap { $0 })
        return try allTracks(in: context).first { !references.isDisjoint(with: $0.confirmedAliases) }
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
        var identity = MusicTrackIdentity.IDs(catalogID: snapshot.catalogID, libraryID: snapshot.libraryID)
        guard identity.catalogID != nil || identity.libraryID != nil else {
            throw MusicLibrarySongResolver.ResolutionError.unresolved(snapshot.id)
        }
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
        guard !VideoTrackPolicy.isVideo(playbackData: musicKitPlaybackData) else {
            throw TrackImportError.videoNotSupported
        }
        guard let track = try track(catalogID: catalogID, libraryID: libraryID, in: context) else {
            let insertedTrack = TrackRecord(
                catalogID: catalogID,
                libraryID: libraryID,
                title: title,
                artistName: artistName,
                albumTitle: albumTitle,
                artworkURLTemplate: PortableArtworkReference.validated(artworkURLTemplate),
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

        var preferredLibraryID = libraryID
        var acceptsMetadata = true
        if let oldLibraryID = track.libraryID, let libraryID, oldLibraryID != libraryID,
           let catalogID, track.catalogID == catalogID {
            // Two library resources may prove the same catalog recording.
            // Pick a stable representative, not whichever source fetched last.
            preferredLibraryID = min(oldLibraryID, libraryID)
            acceptsMetadata = libraryID == preferredLibraryID
            let alias = max(oldLibraryID, libraryID)
            let reference = MusicResourceReference.library(alias, scope: track.libraryScope)
            if !track.confirmedAliases.contains(reference) {
                track.confirmedAliases.append(reference)
                didChange = true
            }
        }
        assignIdentifier(catalogID, to: \.catalogID, on: track, didChange: &didChange)
        assignIdentifier(preferredLibraryID, to: \.libraryID, on: track, didChange: &didChange)
        if acceptsMetadata {
            assign(title, to: \.title, on: track, didChange: &didChange, artworkThemeInputsChanged: &artworkThemeInputsChanged)
            assign(artistName, to: \.artistName, on: track, didChange: &didChange, artworkThemeInputsChanged: &artworkThemeInputsChanged)
            assign(albumTitle, to: \.albumTitle, on: track, didChange: &didChange, artworkThemeInputsChanged: &artworkThemeInputsChanged)
            if let artworkURLTemplate = PortableArtworkReference.validated(artworkURLTemplate) {
                assign(artworkURLTemplate, to: \.artworkURLTemplate, on: track, didChange: &didChange, artworkThemeInputsChanged: &artworkThemeInputsChanged)
            }
            assign(durationSeconds, to: \.durationSeconds, on: track, didChange: &didChange)
            if let musicKitPlaybackData { track.musicKitPlaybackData = musicKitPlaybackData }
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
        var changed = false
        if let isrc = snapshot.isrc { assign(isrc, to: \.isrc, on: track, didChange: &changed) }
        if snapshot.hasDocumentedIdentity {
            assign(true, to: \.hasDocumentedIdentity, on: track, didChange: &changed)
            // A documented empty library relationship overrides an opaque hint.
            if snapshot.libraryID != nil {
                assign(snapshot.catalogID, to: \.catalogID, on: track, didChange: &changed)
            }
            if snapshot.hasResolvedIdentityCandidates {
                assign(snapshot.equivalentCatalogIDs, to: \.equivalentCatalogIDs, on: track, didChange: &changed)
            }
        }
        return changed
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
