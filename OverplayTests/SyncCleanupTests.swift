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
            library: { ids in
                ids.flatMap { id -> [Song] in
                    switch id.rawValue {
                    case "i.on-device": [onDevice]
                    case "i.ambiguous": [ambiguous, ambiguous]
                    default: []
                    }
                }
            },
            webLibrary: { ids in webRequested.append(ids.map(\.rawValue)); return ["i.web"] },
            catalog: { ids in ids.map(\.rawValue).contains("1234") ? [catalogOnly] : [] }
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

    // MARK: - #111 batched on-device library and catalog lookups

    @Test("On-device library and catalog lookups are batched in 100s and correlated by ID")
    func nativeAndCatalogAreBatched() async throws {
        let observed = try (0..<230).map { try Self.song("cat-\($0)") }
        var nativeBatches: [Int] = []
        var catalogBatches: [Int] = []
        let result = try await MusicLibrarySongResolver.resolveAll(
            observed,
            library: { ids in nativeBatches.append(ids.count); return [] },
            librarySong: { _ in Issue.record("per-song lookup without a reason"); return [] },
            webLibrary: { _ in [] },
            catalog: { ids in
                catalogBatches.append(ids.count)
                return try ids.reversed().map { try Self.song($0.rawValue) }
            }
        )
        #expect(nativeBatches == [100, 100, 30])
        #expect(catalogBatches == [100, 100, 30])
        #expect(result.unresolved.isEmpty)
        #expect(result.resolutions.count == 230)
        #expect(result.resolutions.values.allSatisfy { $0.identity.catalogID != nil })
    }

    @Test("A batched native lookup with two matches for a song leaves that song unresolved, not the rest")
    func batchedMultipleMatchesAreUnresolved() async throws {
        let plain = try Self.song("i.plain")
        let twice = try Self.song("i.twice")
        let result = try await MusicLibrarySongResolver.resolveAll(
            [plain, twice],
            library: { _ in [plain, twice, twice] },
            librarySong: { _ in Issue.record("per-song lookup without a reason"); return [] },
            webLibrary: { _ in Issue.record("web library consulted"); return [] },
            catalog: { _ in Issue.record("catalog consulted"); return [] }
        )
        #expect(result.resolutions[plain.id]?.identity.libraryID == "i.plain")
        #expect(result.unresolved == [twice.id])
    }

    /// Mac persistent IDs answer with a different, web library ID: probe of
    /// 2026-09-27, `[native song id=-3140821922437280474]`. A batch cannot say
    /// which observed song such an answer belongs to.
    @Test("A native batch answering under other IDs falls back to per-song lookups")
    func unattributableNativeBatchFallsBackPerSong() async throws {
        let observed = try ["111", "222", "333"].map { try Self.song($0) }
        var batches = 0
        var perSong: [String] = []
        let result = try await MusicLibrarySongResolver.resolveAll(
            observed,
            library: { _ in batches += 1; return try [Self.song("i.mapped-a"), Self.song("i.mapped-b")] },
            librarySong: { id in
                perSong.append(id.rawValue)
                return id.rawValue == "333" ? [] : [try Self.song("i.mapped-\(id.rawValue)")]
            },
            webLibrary: { _ in [] },
            catalog: { _ in [] }
        )
        #expect(batches == 1)
        #expect(perSong == ["111", "222", "333"])
        #expect(result.resolutions[observed[0].id]?.identity.libraryID == "i.mapped-111")
        #expect(result.resolutions[observed[1].id]?.identity.libraryID == "i.mapped-222")
        #expect(result.unresolved == [observed[2].id])
    }

    @Test("A native batch that mixes correlated and mapped answers only falls back for the unanswered")
    func mixedNativeBatchFallsBackForTheUnanswered() async throws {
        let answered = try Self.song("i.answered")
        let mapped = try Self.song("222")
        var perSong: [String] = []
        let result = try await MusicLibrarySongResolver.resolveAll(
            [answered, mapped],
            library: { _ in [answered, try Self.song("i.mapped")] },
            librarySong: { id in perSong.append(id.rawValue); return [try Self.song("i.mapped")] },
            webLibrary: { _ in [] },
            catalog: { _ in [] }
        )
        #expect(perSong == ["222"])
        #expect(result.resolutions[answered.id]?.identity.libraryID == "i.answered")
        #expect(result.resolutions[mapped.id]?.identity.libraryID == "i.mapped")
    }

    @Test("A native batch failure stops the fetch")
    func nativeBatchFailureThrows() async throws {
        await #expect(throws: URLError.self) {
            _ = try await MusicLibrarySongResolver.resolveAll(
                [try Self.song("i.a")],
                library: { _ in throw URLError(.notConnectedToInternet) },
                librarySong: { _ in Issue.record("per-song lookup after a failure"); return [] },
                webLibrary: { _ in [] },
                catalog: { _ in [] }
            )
        }
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
