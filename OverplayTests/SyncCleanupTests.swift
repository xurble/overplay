import Foundation
import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// #65 (batched web-library resolution) and #69 (retention sweep).
@MainActor
@Suite("Sync clean-up", .serialized)
struct SyncCleanupTests {
    private static func song(_ id: String) throws -> Song {
        try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "type": "library-songs",
            "attributes": ["name": id, "artistName": "Artist", "albumName": "Album", "genreNames": []]
        ]))
    }

    // MARK: - #65 batched resolution

    @Test("Songs missing from the on-device library are resolved in web batches of 25, not one request each")
    func webLookupsAreBatched() async throws {
        let observed = try (0..<60).map { try Self.song("i.song-\($0)") }
        var batches: [Int] = []
        let result = try await MusicLibrarySongResolver.resolveAll(
            observed,
            library: { _ in [] },
            webLibrary: { ids in batches.append(ids.count); return ids.map(\.rawValue) },
            catalog: { _ in Issue.record("catalog consulted"); return [] }
        )
        #expect(batches == [25, 25, 10])
        #expect(result.unresolved.isEmpty)
        #expect(result.resolutions.count == 60)
        #expect(result.resolutions.values.allSatisfy { $0.identity.libraryID != nil })
    }

    @Test("Batching keeps the resolution order: on-device hits, then web library, then catalog; unidentified songs are reported")
    func batchedOrderAndUnresolved() async throws {
        let onDevice = try Self.song("i.on-device")
        let web = try Self.song("i.web")
        let catalogOnly = try Self.song("1234")
        let nowhere = try Self.song("i.nowhere")
        let ambiguous = try Self.song("i.ambiguous")
        var webRequested: [[String]] = []
        let result = try await MusicLibrarySongResolver.resolveAll(
            [onDevice, web, catalogOnly, nowhere, ambiguous, web],
            library: { id in
                switch id.rawValue {
                case "i.on-device": [onDevice]
                case "i.ambiguous": [ambiguous, ambiguous]
                default: []
                }
            },
            webLibrary: { ids in webRequested.append(ids.map(\.rawValue)); return ["i.web"] },
            catalog: { id in id.rawValue == "1234" ? [catalogOnly] : [] }
        )
        #expect(webRequested == [["i.web", "1234", "i.nowhere"]])
        #expect(result.resolutions[onDevice.id]?.identity.libraryID == "i.on-device")
        #expect(result.resolutions[web.id]?.identity.libraryID == "i.web")
        #expect(result.resolutions[catalogOnly.id]?.identity.catalogID == "1234")
        #expect(Set(result.unresolved) == [nowhere.id, ambiguous.id])
    }

    @Test("A web answer for an ID nobody asked about stops the fetch")
    func unexpectedWebAnswerThrows() async throws {
        await #expect(throws: MusicLibrarySongResolver.ResolutionError.self) {
            _ = try await MusicLibrarySongResolver.resolveAll(
                [try Self.song("i.asked")],
                library: { _ in [] },
                webLibrary: { _ in ["i.someone-else"] },
                catalog: { _ in [] }
            )
        }
    }

    @Test("Copying a playlist still needs every song")
    func copyRequiresEverySong() async throws {
        let resolved = try await AppleMusicPlaylistTrackLoader.resolveSongs(
            from: [.song(try Self.song("i.a")), .song(try Self.song("i.b"))], playlistID: "copy",
            resolveAll: { songs in
                var batch = MusicLibrarySongResolver.BatchResolution()
                batch.resolutions[songs[0].id] = .library(songs[0])
                batch.unresolved = [songs[1].id]
                return batch
            }
        )
        #expect(resolved.snapshots.map { $0?.libraryID } == ["i.a", nil])
        #expect(throws: MusicLibrarySongResolver.ResolutionError.self) { try resolved.requireAll() }
    }

    // MARK: - #69 retention sweep

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let bucket: PlaylistRecord
    }

    private func fixture() throws -> Fixture {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        return Fixture(container: container, context: context, bucket: try PlaylistRepository.triageBucket(in: context))
    }

    @discardableResult
    private func row(
        in fixture: Fixture, retired: Bool = true, sources: [String] = [], suppressed: [String] = [],
        skips: Int = 0, pending: Bool = false
    ) throws -> PlaylistItemRecord {
        let track = TrackRecord(catalogID: UUID().uuidString, title: "Song", artistName: "Artist")
        fixture.context.insert(track)
        let item = PlaylistItemRecord(playlistID: fixture.bucket.id, trackID: track.id, sourceMusicPlaylistIDs: sources)
        item.evictedAt = retired ? .now : nil
        item.suppressedOTPMusicPlaylistIDs = suppressed
        item.skipCount = skips
        item.pendingRetentionCleanup = pending
        fixture.context.insert(item)
        try fixture.context.save()
        return item
    }

    private func exists(_ item: PlaylistItemRecord, in fixture: Fixture) throws -> Bool {
        try PlaylistItemRepository.item(id: item.id, in: fixture.context) != nil
    }

    @Test("The sweep deletes a retired 0/0 row that missed its trigger, and records it in history")
    func sweepDeletesMissedRow() throws {
        let f = try fixture()
        let missed = try row(in: f)
        #expect(try TrackRetentionPolicy.sweep(in: f.context) == 1)
        #expect(try !exists(missed, in: f))
        let events = try f.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(events.contains { $0.eventType == .trackRemoved && $0.trackID == missed.trackID })
        #expect(try TrackRetentionPolicy.sweep(in: f.context) == 0)
    }

    @Test("The sweep keeps every protected row and never touches active Triage")
    func sweepKeepsProtectedRows() throws {
        let f = try fixture()
        let kept = [
            try row(in: f, sources: ["source"]),
            try row(in: f, suppressed: ["otp"]),
            try row(in: f, skips: 2),
            // The rule would delete this untouched active row, but only on its own triggers.
            try row(in: f, retired: false),
        ]
        #expect(try TrackRetentionPolicy.sweep(in: f.context) == 0)
        for item in kept { #expect(try exists(item, in: f)) }
    }

    @Test("A deferred deletion completes once the song is no longer playing")
    func sweepCompletesDeferredDeletion() throws {
        let f = try fixture()
        let deferred = try row(in: f, retired: false, pending: true)
        let lease = TrackRetentionPolicy.makePlaybackLease()
        lease.itemID = deferred.id
        #expect(try TrackRetentionPolicy.sweep(in: f.context) == 0)
        #expect(try exists(deferred, in: f))
        lease.itemID = nil
        #expect(try TrackRetentionPolicy.sweep(in: f.context) == 1)
        #expect(try !exists(deferred, in: f))
    }

    @Test("Each periodic sync cycle ends with the sweep")
    func periodicCycleSweeps() async throws {
        let f = try fixture()
        let missed = try row(in: f)
        let service = PeriodicPlaylistSyncService(syncPlaylist: { _, _ in PlaylistSyncSummary() })
        await service.syncLinkedPlaylists(context: f.context)
        #expect(try !exists(missed, in: f))
    }
}
