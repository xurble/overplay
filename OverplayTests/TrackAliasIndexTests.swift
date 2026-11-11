import Foundation
import SwiftData
import Testing
@testable import Overplay

/// PF-1: a sync pass looks songs up through one alias index instead of
/// scanning every track per song. The match must be the one the scan finds.
@MainActor
struct TrackAliasIndexTests {
    private func snapshot(catalogID: String?, libraryID: String?, title: String = "Song") -> TrackSnapshot {
        TrackSnapshot(id: catalogID ?? libraryID ?? title, catalogID: catalogID, libraryID: libraryID,
            playlistEntryID: nil, playlistID: nil, title: title, artistName: "Artist",
            albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 200)
    }

    @Test("The index finds a track by a confirmed alias, and misses only what no track holds")
    func findsConfirmedAlias() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let keeper = TrackRecord(catalogID: "c.keeper", libraryID: "i.keeper", title: "Keeper", artistName: "Artist")
        keeper.confirmedAliases = [.catalog("c.donor"), .library("i.donor")]
        context.insert(keeper)
        try context.save()
        let index = TrackAliasIndex(in: context)

        #expect(try TrackRecordRepository.track(catalogID: "c.donor", libraryID: nil, aliasIndex: index, in: context)?.id == keeper.id)
        #expect(try TrackRecordRepository.track(catalogID: nil, libraryID: "i.donor", aliasIndex: index, in: context)?.id == keeper.id)
        // An alias belongs to its domain and scope.
        #expect(try TrackRecordRepository.track(catalogID: nil, libraryID: "c.donor", aliasIndex: index, in: context) == nil)
        #expect(try TrackRecordRepository.track(catalogID: nil, libraryID: "i.donor", libraryScope: "other",
                                                aliasIndex: index, in: context) == nil)
        #expect(try TrackRecordRepository.track(catalogID: "c.new", libraryID: "i.new", aliasIndex: index, in: context) == nil)
        // An upsert through the index lands on the keeper, not a new track.
        let result = try TrackRecordRepository.upsertWithResult(snapshot(catalogID: "c.donor", libraryID: nil),
                                                                aliasIndex: index, in: context)
        #expect(result.record.id == keeper.id)
        #expect(try TrackRecordRepository.allTracks(in: context).count == 1)
    }

    @Test("Within one pass, a song stored earlier and an alias recorded earlier are both found")
    func seesEarlierWritesOfTheSamePass() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let index = TrackAliasIndex(in: context)
        let first = try TrackRecordRepository.upsert(snapshot(catalogID: "c.1", libraryID: "i.b"), aliasIndex: index, in: context)
        // The same song again, unsaved, is the same track.
        #expect(try TrackRecordRepository.upsert(snapshot(catalogID: "c.1", libraryID: "i.b"), aliasIndex: index, in: context).id == first.id)
        // A second library copy of the recording takes the smaller ID and
        // keeps "i.b" only as an alias, recorded during this pass.
        #expect(try TrackRecordRepository.upsert(snapshot(catalogID: "c.1", libraryID: "i.a"), aliasIndex: index, in: context).id == first.id)
        #expect(first.libraryID == "i.a")
        #expect(first.confirmedAliases == [.library("i.b")])
        // Seen only by its library ID, the copy still finds that track.
        #expect(try TrackRecordRepository.upsert(snapshot(catalogID: nil, libraryID: "i.b"), aliasIndex: index, in: context).id == first.id)
        #expect(try TrackRecordRepository.allTracks(in: context).count == 1)
    }

    @Test("A mixed batch matches the same tracks with or without the index")
    func mixedBatchParity() throws {
        let seedIDs = (0..<4).map { _ in UUID() }
        func seed(_ context: ModelContext) throws {
            let tracks = [
                TrackRecord(id: seedIDs[0], catalogID: "c.plain", libraryID: "i.plain", title: "Plain", artistName: "A"),
                TrackRecord(id: seedIDs[1], catalogID: "c.keeper", title: "Keeper", artistName: "A"),
                TrackRecord(id: seedIDs[2], libraryID: "i.upload", title: "Upload", artistName: "A"),
                // Two tracks claim one alias: the scan's sort order decides.
                TrackRecord(id: seedIDs[3], catalogID: "c.other", title: "Another", artistName: "A")
            ]
            tracks[1].confirmedAliases = [.catalog("c.merged"), .library("i.merged"), .catalog("c.shared")]
            tracks[3].confirmedAliases = [.catalog("c.shared")]
            for track in tracks { context.insert(track) }
            try context.save()
        }
        let batch: [TrackSnapshot] = [
            snapshot(catalogID: "c.new1", libraryID: "i.new1"),
            snapshot(catalogID: "c.plain", libraryID: nil),
            snapshot(catalogID: "c.merged", libraryID: nil),
            snapshot(catalogID: nil, libraryID: "i.merged"),
            snapshot(catalogID: "c.shared", libraryID: nil),
            snapshot(catalogID: "c.new1", libraryID: "i.new0"),
            snapshot(catalogID: nil, libraryID: "i.new1"),
            snapshot(catalogID: nil, libraryID: "i.upload"),
            snapshot(catalogID: "c.upload", libraryID: "i.upload"),
            snapshot(catalogID: "c.new2", libraryID: nil),
            snapshot(catalogID: "c.new2", libraryID: "i.new2"),
            snapshot(catalogID: "c.new1", libraryID: "i.new1"),
            snapshot(catalogID: "c.keeper", libraryID: "i.keeper"),
            snapshot(catalogID: nil, libraryID: "i.merged")
        ]
        func run(indexed: Bool) throws -> (matches: [String], tracks: [String]) {
            let container = try OverplayTestSupport.makeModelContainer()
            let context = container.mainContext
            try seed(context)
            let index = indexed ? TrackAliasIndex(in: context) : nil
            var labels: [UUID: String] = Dictionary(uniqueKeysWithValues: seedIDs.enumerated().map { ($1, "seed\($0)") })
            let matches = try batch.enumerated().map { position, value in
                let record = try TrackRecordRepository.upsertWithResult(value, aliasIndex: index, in: context).record
                if labels[record.id] == nil { labels[record.id] = "new@\(position)" }
                return labels[record.id]!
            }
            let tracks = try TrackRecordRepository.allTracks(in: context).map { track in
                "\(labels[track.id] ?? "?") \(track.catalogID ?? "-") \(track.libraryID ?? "-") "
                    + track.confirmedAliases.map { "\($0.domain.rawValue):\($0.value)" }.sorted().joined(separator: ",")
            }.sorted()
            return (matches, tracks)
        }
        let old = try run(indexed: false)
        let new = try run(indexed: true)
        #expect(new.matches == old.matches)
        #expect(new.tracks == old.tracks)
        #expect(old.matches[2] == "seed1" && old.matches[3] == "seed1" && old.matches[13] == "seed1")
        #expect(old.matches[6] == old.matches[0])
    }

    @Test("Reconcile sees an alias another task confirms while the pass yields")
    func reconcileRebuildsTheIndexAfterYielding() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "otp", name: "Overplay", role: .oneTruePlaylist)
        context.insert(playlist)
        let keeper = TrackRecord(catalogID: "c.keeper", title: "Keeper", artistName: "Artist")
        context.insert(keeper)
        try context.save()
        let count = PlaylistSyncService.syncYieldStride + 5
        let lateAlias = "c.\(PlaylistSyncService.syncYieldStride + 2)"
        var yields = 0
        let service = PlaylistSyncService(yieldDuringReconciliation: {
            yields += 1
            // As a merge would: the keeper absorbs a song still to come.
            keeper.confirmedAliases.append(.catalog(lateAlias))
        })
        let snapshots = (0..<count).map { snapshot(catalogID: "c.\($0)", libraryID: nil, title: "Song \($0)") }
        _ = try await service.reconcile(snapshots: snapshots, playlistRecord: playlist, syncedAt: .now, in: context)
        #expect(yields == 1)
        #expect(try TrackRecordRepository.allTracks(in: context).count == count)
        #expect(try TrackRecordRepository.track(catalogID: lateAlias, libraryID: nil, in: context)?.id == keeper.id)
        #expect(try PlaylistItemRepository.item(trackID: keeper.id, in: context) != nil)
    }

    @Test("A reconcile whose songs are all stored builds no index")
    func storedSongsBuildNoIndex() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "otp", name: "Overplay", role: .oneTruePlaylist)
        context.insert(playlist)
        let count = PlaylistSyncService.syncYieldStride * 2 + 5
        let snapshots = (0..<count).map { snapshot(catalogID: "c.\($0)", libraryID: "i.\($0)", title: "Song \($0)") }
        let stored = try snapshots.map { try TrackRecordRepository.upsert($0, in: context).id }
        try context.save()
        let builds = BuildCount()
        var yields = 0
        let service = PlaylistSyncService(yieldDuringReconciliation: { yields += 1 })
        _ = try await TrackAliasIndex.$didBuild.withValue({ builds.value += 1 }) {
            try await service.reconcile(snapshots: snapshots, playlistRecord: playlist, syncedAt: .now, in: context)
        }
        #expect(yields == 2)
        #expect(builds.value == 0)
        #expect(try TrackRecordRepository.allTracks(in: context).map(\.id).sorted { $0.uuidString < $1.uuidString }
            == stored.sorted { $0.uuidString < $1.uuidString })
    }

    @Test("A pass builds the index once for its first miss, and again only for a miss after a yield")
    func buildsOnlyForMisses() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "otp", name: "Overplay", role: .oneTruePlaylist)
        context.insert(playlist)
        let stride = PlaylistSyncService.syncYieldStride
        // Songs 0..<stride*2+5 are new except the whole second chunk.
        let count = stride * 2 + 5
        let snapshots = (0..<count).map { snapshot(catalogID: "c.\($0)", libraryID: nil, title: "Song \($0)") }
        for position in stride..<(stride * 2) { try TrackRecordRepository.upsert(snapshots[position], in: context) }
        try context.save()
        let builds = BuildCount()
        let service = PlaylistSyncService(yieldDuringReconciliation: {})
        _ = try await TrackAliasIndex.$didBuild.withValue({ builds.value += 1 }) {
            try await service.reconcile(snapshots: snapshots, playlistRecord: playlist, syncedAt: .now, in: context)
        }
        // First chunk: one build. Second chunk: all stored, none. Third: one.
        #expect(builds.value == 2)
        #expect(try TrackRecordRepository.allTracks(in: context).count == count)
    }
}

@MainActor
private final class BuildCount {
    var value = 0
}
