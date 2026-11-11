import Foundation
@preconcurrency import MusicKit
import Synchronization
import SwiftData
import Testing
@testable import Overplay

/// Counts the main-actor work a start does before its first MusicKit call
/// (PB-9, PB-10), through the shared entry points.
@MainActor
@Suite("Playback start cost", .serialized)
struct PlaybackStartCostTests {
    /// Counts decodes of the given keys in a cache.
    final class DecodeCounter: Sendable {
        private let counts = Mutex<[String: Int]>([:])
        private let cache: DevicePlaybackCache

        init(_ cache: DevicePlaybackCache = .shared) {
            self.cache = cache
            cache.decodeObserver.withLock { $0 = { [self] key in self.counts.withLock { $0[key, default: 0] += 1 } } }
        }

        func stop() { cache.decodeObserver.withLock { $0 = nil } }
        func reset() { counts.withLock { $0 = [:] } }
        func counts(_ ids: [UUID]) -> [Int] { counts.withLock { all in ids.map { all[$0.uuidString] ?? 0 } } }
    }

    private static let noLookups = PlaybackStartParityTests.Lookups().prepare

    private func clearCache(_ fixture: PlaybackFixture) {
        for track in fixture.tracks { DevicePlaybackCache.shared.set(nil, for: track.id) }
    }

    // MARK: - PB-9

    @Test func playAfterRelaunchFetchesTheIntentsRecordsOnce() async throws {
        let first = try PlaybackFixture(trackCount: 5)
        defer { first.cleanUp(); clearCache(first) }
        await first.controller.playPlaylist(first.playlist, startingAt: first.tracks[2],
                                            settings: first.settings, context: first.context)
        first.controller.pause()
        first.controller.stopMonitoring()

        let player = FakePlaybackPlayer()
        let relaunched = PlaybackController(player: player, intentStore: first.intentStore,
                                            preparePlaybackTracks: Self.noLookups,
                                            refreshUnknownApplePlayCount: { _, _ in 0 },
                                            sleep: PlaybackFixture.manualSampling)
        defer { relaunched.stopMonitoring() }
        var fetches: [[UUID]] = []
        relaunched.fetchTrackRecords = { ids, context in
            fetches.append(ids)
            return try TrackRecordRepository.tracks(ids: ids, in: context)
        }
        relaunched.restoreIntent()
        await relaunched.play(context: first.context)

        #expect(fetches == [first.tracks.map(\.id)])
        #expect(player.submittedTitles == [first.tracks.map(\.title)])
        #expect(player.submittedStartIndices == [2])
    }

    @Test func playlistStartDecodesEachCachedTrackOnce() async throws {
        let fixture = try PlaybackFixture(trackCount: 4, preparePlaybackTracks: Self.noLookups)
        defer { fixture.cleanUp(); clearCache(fixture) }
        for track in fixture.tracks { track.hasDocumentedIdentity = true }
        let counter = DecodeCounter()
        defer { counter.stop() }

        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)

        #expect(counter.counts(fixture.tracks.map(\.id)) == [1, 1, 1, 1])
        #expect(fixture.player.submittedTitles == [fixture.tracks.map(\.title)])
    }

    /// A record without documented identity is also decoded for its IDs: once
    /// with the start's tracks, once more when `submit` rebuilds the playlist
    /// rows (outside this change).
    @Test func playlistStartSharesTheIdentityDecode() async throws {
        let fixture = try PlaybackFixture(trackCount: 3, preparePlaybackTracks: Self.noLookups)
        defer { fixture.cleanUp(); clearCache(fixture) }
        let counter = DecodeCounter()
        defer { counter.stop() }

        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)

        #expect(counter.counts(fixture.tracks.map(\.id)) == [2, 2, 2])
    }

    @Test func playAfterRelaunchDecodesEachCachedTrackOnce() async throws {
        let first = try PlaybackFixture(trackCount: 4)
        defer { first.cleanUp(); clearCache(first) }
        for track in first.tracks { track.hasDocumentedIdentity = true }
        await first.controller.playPlaylist(first.playlist, startingAt: first.tracks[3],
                                            settings: first.settings, context: first.context)
        first.controller.pause()
        first.controller.stopMonitoring()
        let counter = DecodeCounter()
        defer { counter.stop() }

        let player = FakePlaybackPlayer()
        let relaunched = PlaybackController(player: player, intentStore: first.intentStore,
                                            preparePlaybackTracks: Self.noLookups,
                                            refreshUnknownApplePlayCount: { _, _ in 0 },
                                            sleep: PlaybackFixture.manualSampling)
        defer { relaunched.stopMonitoring() }
        relaunched.restoreIntent()
        await relaunched.play(context: first.context)

        #expect(counter.counts(first.tracks.map(\.id)) == [1, 1, 1, 1])
        #expect(player.submittedStartIndices == [3])
    }

    /// A sync that re-matches a record and refills its data during a start is
    /// queued with the new data, not the start's earlier decode.
    @Test func dataReplacedDuringAStartIsNotServedStale() async throws {
        let fixture = try PlaybackFixture(trackCount: 2, preparePlaybackTracks: { records, refreshing in
            try await Self.noLookups(records, refreshing)
            let record = try #require(records.first { $0.title == "Song 1" })
            record.libraryID = "i.rematched"
            DevicePlaybackCache.shared.set(try PlaybackFixture.encodedTrack(id: "i.rematched", title: "Rematched",
                                                                            artist: "Artist 1"), for: record.id)
        })
        defer { fixture.cleanUp(); clearCache(fixture) }

        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.submittedTitles == [["Song 0", "Rematched"]])
    }

    // MARK: - The decoding scope

    @Test func aDecodeIsSharedOnlyWithinAScope() async throws {
        let cache = DevicePlaybackCache(directory: nil)
        let counter = DecodeCounter(cache)
        defer { counter.stop() }
        let id = UUID()
        cache.set(try PlaybackFixture.encodedTrack(id: "i.a", title: "A", artist: "Artist"), for: id)

        await DevicePlaybackCache.decodingOnce {
            #expect(cache.track(for: id)?.title == "A")
            #expect(cache.track(for: id)?.title == "A")
            // A nested call shares the enclosing start's decodes.
            await DevicePlaybackCache.decodingOnce { #expect(cache.track(for: id)?.title == "A") }
        }
        #expect(counter.counts([id]) == [1])

        // Nothing decoded is kept once the start is over.
        #expect(cache.track(for: id)?.title == "A")
        #expect(cache.track(for: id)?.title == "A")
        #expect(counter.counts([id]) == [3])
        // The next start decodes afresh: nothing was held over.
        await DevicePlaybackCache.decodingOnce { #expect(cache.track(for: id)?.title == "A") }
        #expect(counter.counts([id]) == [4])
    }

    @Test func settingDataDropsItsDecode() async throws {
        let cache = DevicePlaybackCache(directory: nil)
        let id = UUID()
        cache.set(try PlaybackFixture.encodedTrack(id: "i.a", title: "A", artist: "Artist"), for: id)
        let replacement = try PlaybackFixture.encodedTrack(id: "i.b", title: "B", artist: "Artist")
        await DevicePlaybackCache.decodingOnce {
            #expect(cache.track(for: id)?.title == "A")

            cache.set(replacement, for: id)
            #expect(cache.track(for: id)?.title == "B")
            cache.set(nil, for: id)
            #expect(cache.track(for: id) == nil)
        }
    }

    /// The decode is shared; whether it is the record's song is not.
    @Test func aReMatchedRecordIsNotCurrentWithinAScope() async throws {
        let record = TrackRecord(catalogID: "cat-r", libraryID: "i.r", title: "R", artistName: "Artist")
        defer { DevicePlaybackCache.shared.set(nil, for: record.id) }
        DevicePlaybackCache.shared.set(try PlaybackFixture.encodedTrack(id: "i.r", title: "R", artist: "Artist"), for: record.id)

        await DevicePlaybackCache.decodingOnce {
            #expect(DevicePlaybackCache.hasCurrentData(for: record))
            record.libraryID = "i.other"
            record.catalogID = "cat-other"
            #expect(!DevicePlaybackCache.hasCurrentData(for: record))
        }
    }

    /// A start held up by a lookup that has not returned keeps only its own
    /// decodes: other callers' decodes are never kept meanwhile.
    @Test func aHungLookupKeepsNoOtherCallersDecodes() async throws {
        let cache = DevicePlaybackCache.shared
        let waiting = TrackRecord(libraryID: "i.hung", title: "Hung", artistName: "Artist")
        let other = UUID()
        defer { cache.set(nil, for: other) }
        cache.set(try PlaybackFixture.encodedTrack(id: "i.other", title: "Other", artist: "Artist"), for: other)
        let counter = DecodeCounter()
        defer { counter.stop() }
        let (entered, enteredLookup) = AsyncStream<Void>.makeStream()
        let (release, releaseLookup) = AsyncStream<Void>.makeStream()
        let start = Task { @MainActor in
            try? await DevicePlaybackCache.prepare([waiting], libraryLookup: { _ in
                enteredLookup.yield()
                for await _ in release {}
                return [:]
            }, catalogLookup: { _ in [:] })
        }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // The start is suspended in its lookup; sync or play-count code
        // reading another track decodes it each time.
        #expect(cache.track(for: other)?.title == "Other")
        #expect(cache.track(for: other)?.title == "Other")
        #expect(counter.counts([other]) == [2])

        releaseLookup.finish()
        await start.value
    }

    @Test func preparationDecodesEachCachedTrackOnce() async throws {
        let tracks = (0..<3).map { TrackRecord(libraryID: "i.prep-\($0)", title: "Prep \($0)", artistName: "Artist") }
        defer { for track in tracks { track.musicKitPlaybackData = nil } }
        for track in tracks {
            track.musicKitPlaybackData = try PlaybackFixture.encodedTrack(id: track.libraryID!, title: track.title, artist: "Artist")
        }
        let counter = DecodeCounter()
        defer { counter.stop() }

        try await DevicePlaybackCache.prepare(tracks, libraryLookup: { _ in [:] }, catalogLookup: { _ in [:] })

        #expect(counter.counts(tracks.map(\.id)) == [1, 1, 1])
    }

    // MARK: - PB-10

    private static func collection() throws -> (PlaybackCollection, [PlaybackCollectionSong], [String: Track]) {
        let ids = ["alb-1", "alb-2", "alb-3"]
        let songs = ids.map { PlaybackCollectionSong(catalogID: $0, title: "Title \($0)", artistName: "Artist 0") }
        let tracks = try Dictionary(uniqueKeysWithValues: ids.map { ($0, try FakePlaybackCatalog.track(id: $0, title: "Title \($0)")) })
        return (PlaybackCollection(kind: .libraryPlaylist, catalogID: "p.cost", title: "Cost"), songs, tracks)
    }

    private static func trackFiles(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    }

    @Test func tappingAnotherSongOfAPlayingCollectionWritesNoTrackFiles() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackStartCost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        fixture.controller.playbackCatalog = FakePlaybackCatalog().catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: directory)
        let (collection, songs, tracks) = try Self.collection()

        #expect(await fixture.controller.playCollection(collection, songs: songs, startingAt: "alb-1",
                                                        recordsRecent: false, tracks: tracks, context: fixture.context))
        #expect(Self.trackFiles(in: directory) == ["catalog-alb-1.json", "catalog-alb-2.json", "catalog-alb-3.json"])
        // Any write would put a file back.
        for file in Self.trackFiles(in: directory) { try FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }

        #expect(await fixture.controller.playCollection(collection, songs: songs, startingAt: "alb-3",
                                                        recordsRecent: false, tracks: tracks, context: fixture.context))
        #expect(fixture.player.submitCount == 1)
        #expect(fixture.controller.currentTrack?.title == "Title alb-3")
        #expect(Self.trackFiles(in: directory).isEmpty)

        // Even when the caller's copies differ: the playing queue is not
        // rebuilt, so the cached copies stay.
        let differing = try Dictionary(uniqueKeysWithValues: tracks.keys.map {
            ($0, try FakePlaybackCatalog.track(id: "i.\($0)", title: "Other \($0)"))
        })
        #expect(await fixture.controller.playCollection(collection, songs: songs, startingAt: "alb-2",
                                                        recordsRecent: false, tracks: differing, context: fixture.context))
        #expect(fixture.player.submitCount == 1)
        #expect(Self.trackFiles(in: directory).isEmpty)

        // A new start writes only songs whose copy changed: none here.
        let other = PlaybackCollection(kind: .libraryPlaylist, catalogID: "p.other", title: "Other")
        #expect(await fixture.controller.playCollection(other, songs: songs, startingAt: "alb-2",
                                                        recordsRecent: false, tracks: tracks, context: fixture.context))
        #expect(fixture.player.submitCount == 2)
        #expect(Self.trackFiles(in: directory).isEmpty)

        // A new start with one changed copy writes that song alone.
        var changed = tracks
        changed["alb-1"] = differing["alb-1"]
        let third = PlaybackCollection(kind: .libraryPlaylist, catalogID: "p.third", title: "Third")
        #expect(await fixture.controller.playCollection(third, songs: songs, startingAt: "alb-1",
                                                        recordsRecent: false, tracks: changed, context: fixture.context))
        #expect(fixture.player.submittedTitles.last == ["Other alb-1", "Title alb-2", "Title alb-3"])
        #expect(Self.trackFiles(in: directory) == ["catalog-alb-1.json"])
    }

    /// The selection still fills songs the cache lost, for a selection that
    /// has to resubmit from them.
    @Test func selectingFillsSongsTheCacheLost() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let cache = DevicePlaybackCache(directory: nil)
        fixture.controller.playbackCatalog = FakePlaybackCatalog().catalog
        fixture.controller.collectionTrackCache = cache
        let (collection, songs, tracks) = try Self.collection()
        #expect(await fixture.controller.playCollection(collection, songs: songs, startingAt: "alb-1",
                                                        recordsRecent: false, tracks: tracks, context: fixture.context))
        cache.removeAll()

        #expect(await fixture.controller.playCollection(collection, songs: songs, startingAt: "alb-2",
                                                        recordsRecent: false, tracks: tracks, context: fixture.context))
        #expect(["alb-1", "alb-2", "alb-3"].allSatisfy { cache.data(forCatalogSongID: $0) != nil })
    }
}
