import Foundation
import SwiftData

/// Collapses duplicate `TrackRecord`s that describe the same song.
///
/// Duplicates arise when the same song entered the store under different
/// MusicKit ID domains (catalog vs. library) before identities were captured
/// distinctly, or from CloudKit sync races, which cannot enforce unique
/// constraints. The merge keeps the oldest record as canonical, repoints
/// playlist items and history events, sums per-playlist stats, and rekeys the
/// device-local stores that reference local track IDs.
enum TrackIdentityMergeService {
    struct MergeSummary: Equatable {
        var mergedTrackCount = 0
        var mergedItemCount = 0
        var migratedItemCount = 0
        var deletedItemCount = 0
        var localTrackIDMapping: [String: String] = [:]

        var didChange: Bool {
            mergedTrackCount > 0 || mergedItemCount > 0 || migratedItemCount > 0 || deletedItemCount > 0
        }
    }

    /// Bound main-actor work while grouping typed references. Playback objects
    /// never participate in durable identity reconciliation.
    private static let yieldStride = 50

    @discardableResult
    static func mergeDuplicates(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) async throws -> MergeSummary {
        var summary = MergeSummary()
        let tracks = try TrackRecordRepository.allTracks(in: context)

        for group in await duplicateGroups(tracks: tracks) {
            let ordered = group.sorted(by: canonicalPrecedes)
            let canonical = ordered[0]

            for track in ordered {
                try PlaylistItemRepository.preserveAppleCountIdentity(for: track, in: context)
            }

            for duplicate in ordered.dropFirst() {
                absorb(duplicate, into: canonical)
                try repointItems(from: duplicate, to: canonical, in: context)
                try repointHistoryEvents(from: duplicate, to: canonical, in: context)
                summary.localTrackIDMapping[duplicate.id.uuidString] = canonical.id.uuidString
                context.delete(duplicate)
                summary.mergedTrackCount += 1
            }
            canonical.updatedAt = .now
        }

        if !summary.localTrackIDMapping.isEmpty {
            for playlist in try PlaylistRepository.allPlaylists(in: context) {
                playlist.triageExcludedTrackIDs = playlist.triageExcludedTrackIDs.map {
                    summary.localTrackIDMapping[$0] ?? $0
                }
            }
            TrackRetentionPolicy.rekeyPlaybackTracks(summary.localTrackIDMapping)
        }
        let ownership = try TrackOwnershipMigrationService.migrate(in: context)
        summary.mergedItemCount = ownership.mergedCount
        summary.migratedItemCount = ownership.migratedCount
        summary.deletedItemCount = ownership.deletedCount

        if summary.didChange {
            try context.save()
        }
        if !summary.localTrackIDMapping.isEmpty {
            PlaybackOrderStore.rekeyLocalTrackIDs(summary.localTrackIDMapping, from: defaults, flushImmediately: true)
            PlaybackIdentityStore.rekeyLocalTrackIDs(summary.localTrackIDMapping, from: defaults, flushImmediately: true)
            LocalPlaybackStateStore.rekeyLocalTrackIDs(summary.localTrackIDMapping, from: defaults, flushImmediately: true)
        }
        if summary.didChange {
            TrackMetadataDiagnostics.log(
                "track identity merge mergedTracks=\(summary.mergedTrackCount) mergedItems=\(summary.mergedItemCount)"
            )
        }
        return summary
    }

    private static func duplicateGroups(tracks: [TrackRecord]) async -> [[TrackRecord]] {
        var unionFind = UnionFind(count: tracks.count)
        var firstIndexByReference: [MusicResourceReference: Int] = [:]
        var documentedCatalogs: [MusicResourceReference: Set<String>] = [:]
        for track in tracks where track.hasDocumentedIdentity {
            if let id = track.libraryID {
                documentedCatalogs[.library(id, scope: track.libraryScope), default: []].insert(track.catalogID ?? "")
            }
        }
        for (index, track) in tracks.enumerated() {
            if let id = track.libraryID,
               let documented = documentedCatalogs[.library(id, scope: track.libraryScope)],
               documented.count > 1 || (!track.hasDocumentedIdentity && !documented.contains(track.catalogID ?? "")) {
                continue
            }
            if index > 0, index.isMultiple(of: yieldStride) { await Task.yield() }
            for reference in track.identityReferences {
                if let first = firstIndexByReference[reference] {
                    unionFind.union(first, index)
                } else { firstIndexByReference[reference] = index }
            }
        }

        var groupsByRoot: [Int: [TrackRecord]] = [:]
        for index in tracks.indices {
            groupsByRoot[unionFind.find(index), default: []].append(tracks[index])
        }
        return groupsByRoot.values.filter { $0.count > 1 }
    }

    private static func canonicalPrecedes(_ left: TrackRecord, _ right: TrackRecord) -> Bool {
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id.uuidString < right.id.uuidString
    }

    static func absorb(_ duplicate: TrackRecord, into canonical: TrackRecord, confirmed: Bool = false) {
        let documented = canonical.hasDocumentedIdentity ? canonical : duplicate.hasDocumentedIdentity ? duplicate : nil
        let documentedCatalog = documented?.catalogID
        let sameLibrary = canonical.libraryID != nil && canonical.libraryID == duplicate.libraryID
        let authoritativeLibrary = !confirmed && sameLibrary && documented != nil
        let acceptedDonorCatalog = authoritativeLibrary ? documentedCatalog : duplicate.catalogID
        let sameCatalog = canonical.catalogID != nil && canonical.catalogID == duplicate.catalogID
        let adoptsRepresentative = !confirmed && sameCatalog && canonical.libraryScope == duplicate.libraryScope
            && duplicate.libraryID.map { incoming in canonical.libraryID.map { incoming < $0 } ?? true } == true
        var aliases = Set(canonical.confirmedAliases + duplicate.confirmedAliases)
        if adoptsRepresentative, let id = canonical.libraryID { aliases.insert(.library(id, scope: canonical.libraryScope)) }
        if let id = acceptedDonorCatalog { aliases.insert(.catalog(id)) }
        if let id = duplicate.libraryID { aliases.insert(.library(id, scope: duplicate.libraryScope)) }
        canonical.confirmedAliases = aliases.sorted { ($0.domain.rawValue, $0.scope, $0.value) < ($1.domain.rawValue, $1.scope, $1.value) }
        canonical.isrc = canonical.isrc ?? duplicate.isrc
        canonical.equivalentCatalogIDs = Array(Set(canonical.equivalentCatalogIDs + duplicate.equivalentCatalogIDs)).sorted()
        canonical.hasDocumentedIdentity = canonical.hasDocumentedIdentity || duplicate.hasDocumentedIdentity
        canonical.catalogID = canonical.catalogID ?? duplicate.catalogID
        if authoritativeLibrary { canonical.catalogID = documentedCatalog }
        if adoptsRepresentative {
            canonical.title = duplicate.title
            canonical.artistName = duplicate.artistName
            canonical.albumTitle = duplicate.albumTitle
            canonical.artworkURLTemplate = duplicate.artworkURLTemplate
            canonical.durationSeconds = duplicate.durationSeconds
            canonical.musicKitPlaybackData = duplicate.musicKitPlaybackData
        }
        if canonical.libraryID == nil || adoptsRepresentative {
            canonical.libraryID = duplicate.libraryID
            canonical.libraryScope = duplicate.libraryScope
        }
        if canonical.musicKitPlaybackData == nil {
            canonical.musicKitPlaybackData = duplicate.musicKitPlaybackData
        }
        if canonical.albumTitle == nil {
            canonical.albumTitle = duplicate.albumTitle
        }
        if canonical.artworkURLTemplate == nil {
            canonical.artworkURLTemplate = duplicate.artworkURLTemplate
        }
        if canonical.durationSeconds == nil {
            canonical.durationSeconds = duplicate.durationSeconds
        }
    }

    private static func repointItems(
        from duplicate: TrackRecord,
        to canonical: TrackRecord,
        in context: ModelContext
    ) throws {
        let duplicateTrackID = duplicate.id
        var descriptor = FetchDescriptor<PlaylistItemRecord>(
            predicate: #Predicate { $0.trackID == duplicateTrackID }
        )
        descriptor.includePendingChanges = true

        for item in try context.fetch(descriptor) {
            item.trackID = canonical.id
        }
    }

    static func repointHistoryEvents(
        from duplicate: TrackRecord,
        to canonical: TrackRecord,
        in context: ModelContext
    ) throws {
        let duplicateTrackID: UUID? = duplicate.id
        var descriptor = FetchDescriptor<HistoryEvent>(
            predicate: #Predicate { $0.trackID == duplicateTrackID }
        )
        descriptor.includePendingChanges = true

        for event in try context.fetch(descriptor) {
            event.trackID = canonical.id
        }
    }
}

private struct UnionFind {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root {
            root = parent[root]
        }

        var current = index
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ first: Int, _ second: Int) {
        let firstRoot = find(first)
        let secondRoot = find(second)
        guard firstRoot != secondRoot else { return }
        parent[max(firstRoot, secondRoot)] = min(firstRoot, secondRoot)
    }
}
