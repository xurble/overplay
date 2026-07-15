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
        var localTrackIDMapping: [String: String] = [:]

        var didChange: Bool {
            mergedTrackCount > 0 || mergedItemCount > 0
        }
    }

    /// How many per-track decodes run between yields; the grouping pass
    /// JSON-decodes every track's playback data, so it must not occupy the
    /// main actor in one contiguous slice.
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

        summary.mergedItemCount = try PlaylistItemRepository.mergeDuplicateItems(in: context, save: false)

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
        var firstIndexByMusicItemID: [String: Int] = [:]

        for (index, track) in tracks.enumerated() {
            if index > 0, index.isMultiple(of: yieldStride) {
                await Task.yield()
            }
            for musicItemID in PlaybackQueueBuilder.musicItemIDs(for: track) {
                if let firstIndex = firstIndexByMusicItemID[musicItemID] {
                    unionFind.union(firstIndex, index)
                } else {
                    firstIndexByMusicItemID[musicItemID] = index
                }
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

    private static func absorb(_ duplicate: TrackRecord, into canonical: TrackRecord) {
        canonical.catalogID = preferredIdentifier(canonical.catalogID, duplicate.catalogID) {
            !MusicTrackIdentity.isLibraryID($0)
        }
        canonical.libraryID = preferredIdentifier(canonical.libraryID, duplicate.libraryID) {
            MusicTrackIdentity.isLibraryID($0)
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

    /// Prefers a value that belongs to the field's ID domain, so a genuine
    /// catalog ID can heal a legacy record whose catalog field mirrors a
    /// library ID.
    private static func preferredIdentifier(
        _ current: String?,
        _ incoming: String?,
        isWellFormed: (String) -> Bool
    ) -> String? {
        if let current, isWellFormed(current) {
            return current
        }
        if let incoming, isWellFormed(incoming) {
            return incoming
        }
        return current ?? incoming
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

    private static func repointHistoryEvents(
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
