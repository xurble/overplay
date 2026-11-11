import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// What a start queues, through the shared entry points only, so the same
/// tests run unchanged against the code before the PB-9 and PB-10 changes:
/// order, start index, resume position, left-out songs and members.
@MainActor
@Suite("Playback start parity", .serialized)
struct PlaybackStartParityTests {
    /// Library and catalog lookups that answer only for the given songs.
    struct Lookups {
        var library: [String: String] = [:]
        var catalog: [String: String] = [:]

        var prepare: @MainActor ([TrackRecord], Set<UUID>) async throws -> Void {
            { [library, catalog] records, refreshing in
                try await DevicePlaybackCache.prepare(records, refreshing: refreshing, libraryLookup: { ids in
                    try Self.songs(ids, titles: library)
                }, catalogLookup: { ids in
                    try Self.songs(ids, titles: catalog)
                })
            }
        }

        static func songs(_ ids: [String], titles: [String: String]) throws -> [String: Song] {
            var songs: [String: Song] = [:]
            for id in ids {
                guard let title = titles[id] else { continue }
                songs[id] = try PlaybackStartParityTests.song(id, title)
            }
            return songs
        }
    }

    static func song(_ id: String, _ title: String) throws -> Song {
        try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "type": "songs",
            "attributes": ["name": title, "artistName": "Artist", "albumName": "Album", "genreNames": [],
                           "durationInMillis": 180_000, "playParams": ["id": id, "kind": "song"]]
        ]))
    }

    static func videoData(id: String) throws -> Data {
        let json = #"{"id":"\#(id)","type":"music-videos","attributes":{"name":"Video","artistName":"Artist","genreNames":[],"durationInMillis":100000}}"#
        return try JSONEncoder().encode(Track.musicVideo(try JSONDecoder().decode(MusicVideo.self, from: Data(json.utf8))))
    }

    /// Six songs: cached; missing but in the library; missing everywhere;
    /// re-matched to another library ID since it was cached; a cached video;
    /// gone from the library but in the catalog.
    private func mixedFixture() throws -> (PlaybackFixture, Lookups) {
        let lookups = Lookups(library: ["i.lib-1": "Fetched 1", "i.lib-3": "Rematched 3"], catalog: ["cat-5": "Catalog 5"])
        let fixture = try PlaybackFixture(trackCount: 6, preparePlaybackTracks: lookups.prepare)
        let cache = DevicePlaybackCache.shared
        cache.set(nil, for: fixture.tracks[1].id)
        cache.set(nil, for: fixture.tracks[2].id)
        cache.set(try PlaybackFixture.encodedTrack(id: "i.old-3", title: "Stale 3", artist: "Artist 3"), for: fixture.tracks[3].id)
        cache.set(try Self.videoData(id: "i.lib-4"), for: fixture.tracks[4].id)
        cache.set(nil, for: fixture.tracks[5].id)
        return (fixture, lookups)
    }

    private func clearCache(_ fixture: PlaybackFixture) {
        for track in fixture.tracks { DevicePlaybackCache.shared.set(nil, for: track.id) }
    }

    @Test func playlistStartQueuesTheSameSongsOrderAndStart() async throws {
        let (fixture, _) = try mixedFixture()
        defer { fixture.cleanUp(); clearCache(fixture) }

        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[3],
                                              settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.submittedTitles == [["Song 0", "Fetched 1", "Rematched 3", "Catalog 5"]])
        #expect(fixture.player.submittedStartIndices == [2])
        #expect(fixture.controller.statusMessage == "2 tracks couldn't be prepared and were left out.")
        let intent = try #require(fixture.intentStore.loadIntent())
        #expect(intent.members.map(\.localTrackID) == [0, 1, 3, 5].map { fixture.tracks[$0].id.uuidString })
        #expect(intent.startingLocalTrackID == fixture.tracks[3].id.uuidString)
        #expect(intent.members.map(\.musicItemIDs).map(Set.init) == [
            ["cat-0", "i.lib-0"], ["cat-1", "i.lib-1"], ["cat-3", "i.lib-3"], ["cat-5", "i.lib-5"]
        ])
    }

    @Test func playAfterRelaunchQueuesTheSameSongsStartAndPosition() async throws {
        let (first, lookups) = try mixedFixture()
        defer { first.cleanUp(); clearCache(first) }
        await first.controller.playPlaylist(first.playlist, startingAt: first.tracks[3],
                                            settings: first.settings, context: first.context)
        await first.listen(seconds: 40)
        first.controller.pause()
        first.controller.stopMonitoring()
        // Re-matched again while the app was not running; a song becomes unavailable.
        first.tracks[3].libraryID = "i.lib-3b"
        DevicePlaybackCache.shared.set(nil, for: first.tracks[1].id)
        var relaunchLookups = lookups
        relaunchLookups.library = ["i.lib-3b": "Rematched 3b"]

        let player = FakePlaybackPlayer()
        let relaunched = PlaybackController(player: player, intentStore: first.intentStore,
                                            preparePlaybackTracks: relaunchLookups.prepare,
                                            refreshUnknownApplePlayCount: { _, _ in 0 },
                                            sleep: PlaybackFixture.manualSampling)
        defer { relaunched.stopMonitoring() }
        relaunched.restoreIntent()
        await relaunched.play(context: first.context)

        #expect(player.submittedTitles == [["Song 0", "Rematched 3b", "Catalog 5"]])
        #expect(player.submittedStartIndices == [1])
        #expect(player.playbackTime == 40)
        #expect(relaunched.isPlaying)
    }

    // MARK: - Collections

    private static func collectionSong(_ id: String, _ title: String) -> PlaybackCollectionSong {
        PlaybackCollectionSong(catalogID: id, title: title, artistName: "Artist 0")
    }

    /// A library playlist: a song tracked by catalog ID, one by library ID,
    /// one by confirmed library alias, one untracked, and one nothing has.
    private func libraryPlaylist(
        _ fixture: PlaybackFixture
    ) throws -> (PlaybackCollection, [PlaybackCollectionSong], [String: Track]) {
        fixture.tracks[2].confirmedAliases = [.library("i.alias-2")]
        try fixture.context.save()
        let collection = PlaybackCollection(kind: .libraryPlaylist, catalogID: "p.library", title: "Library Playlist")
        let songs = [Self.collectionSong("cat-0", "Song 0"), Self.collectionSong("i.lib-1", "Song 1"),
                     Self.collectionSong("i.alias-2", "Song 2"), Self.collectionSong("alb-9", "Untracked 9"),
                     Self.collectionSong("gone", "Gone")]
        var tracks: [String: Track] = [:]
        for (id, title) in [("cat-0", "Song 0"), ("i.lib-1", "Song 1"), ("i.alias-2", "Song 2"), ("alb-9", "Untracked 9")] {
            tracks[id] = try FakePlaybackCatalog.track(id: id, title: title)
        }
        return (collection, songs, tracks)
    }

    @Test func collectionStartQueuesTheSameSongsMembersAndStart() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp(); clearCache(fixture) }
        fixture.controller.playbackCatalog = FakePlaybackCatalog().catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        let (collection, songs, tracks) = try libraryPlaylist(fixture)

        let started = await fixture.controller.playCollection(collection, songs: songs, startingAt: "i.alias-2",
                                                              recordsRecent: false, tracks: tracks, context: fixture.context)

        #expect(started)
        #expect(fixture.player.submittedTitles == [["Song 0", "Song 1", "Song 2", "Untracked 9"]])
        #expect(fixture.player.submittedStartIndices == [2])
        let intent = try #require(fixture.intentStore.loadIntent())
        #expect(intent.members.map(\.localTrackID) == [
            fixture.tracks[0].id.uuidString, fixture.tracks[1].id.uuidString, fixture.tracks[2].id.uuidString,
            PlaybackIntent.Member.untrackedID(catalogID: "alb-9")
        ])
        #expect(intent.members.map(\.catalogSongID) == ["cat-0", "i.lib-1", "i.alias-2", "alb-9"])

        // Another song of the playing collection is selected in place.
        let selected = await fixture.controller.playCollection(collection, songs: songs, startingAt: "alb-9",
                                                               recordsRecent: false, tracks: tracks, context: fixture.context)
        #expect(selected)
        #expect(fixture.player.submitCount == 1)
        #expect(fixture.controller.currentTrack?.title == "Untracked 9")
    }

    /// A library ID in another library scope is not this library's song.
    @Test func collectionSongInAnotherLibraryScopeIsUntracked() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp(); clearCache(fixture) }
        fixture.controller.playbackCatalog = FakePlaybackCatalog().catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        fixture.tracks[1].libraryScope = "another-library"
        try fixture.context.save()
        let collection = PlaybackCollection(kind: .libraryPlaylist, catalogID: "p.scoped", title: "Scoped")

        let started = await fixture.controller.playCollection(
            collection, songs: [Self.collectionSong("i.lib-1", "Song 1")], startingAt: nil, recordsRecent: false,
            tracks: ["i.lib-1": try FakePlaybackCatalog.track(id: "i.lib-1", title: "Song 1")], context: fixture.context
        )

        #expect(started)
        let intent = try #require(fixture.intentStore.loadIntent())
        #expect(intent.members.map(\.localTrackID) == [PlaybackIntent.Member.untrackedID(catalogID: "i.lib-1")])
    }

    // MARK: - The caller's tracks win a new start

    /// A library browser passes this device's copies; a new start queues
    /// them, not whatever was cached first under the same song ID.
    @Test func newCollectionStartQueuesTheCallersTracksOverADifferingCachedCopy() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp(); clearCache(fixture) }
        let cache = DevicePlaybackCache(directory: nil)
        fixture.controller.playbackCatalog = FakePlaybackCatalog().catalog
        fixture.controller.collectionTrackCache = cache
        // A Mac whose local-copy lookup failed once cached the web-library copy.
        cache.set(try PlaybackFixture.encodedTrack(id: "i.web-1", title: "Web 1", artist: "Artist 0"), forCatalogSongID: "song-1")
        let collection = PlaybackCollection(kind: .libraryPlaylist, catalogID: "p.local", title: "Local")
        let songs = [Self.collectionSong("song-1", "Song 1"), Self.collectionSong("song-2", "Song 2")]
        let tracks = ["song-1": try FakePlaybackCatalog.track(id: "i.local-1", title: "Local 1"),
                      "song-2": try FakePlaybackCatalog.track(id: "i.local-2", title: "Local 2")]

        #expect(await fixture.controller.playCollection(collection, songs: songs, startingAt: "song-1",
                                                        recordsRecent: false, tracks: tracks, context: fixture.context))

        #expect(fixture.player.submittedTitles == [["Local 1", "Local 2"]])
        #expect(fixture.player.queueEntries.map { $0.item?.id } == ["i.local-1", "i.local-2"])
    }

    /// A song first cached by Play Album keeps its catalog copy there, but a
    /// later Library play queues the library browser's copy.
    @Test func libraryPlayAfterPlayAlbumQueuesTheLibraryCopy() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp(); clearCache(fixture) }
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)
        #expect(await fixture.controller.playCurrentCollection(.album, context: fixture.context))
        #expect(fixture.player.submittedTitles.last == ["Song 0", "Album Song 1", "Album Song 2"])

        let library = PlaybackCollection(kind: .libraryPlaylist, catalogID: "p.library-album", title: "Library Album")
        let songs = [Self.collectionSong("alb-1", "Album Song 1"), Self.collectionSong("alb-2", "Album Song 2")]
        let tracks = ["alb-1": try FakePlaybackCatalog.track(id: "i.alb-1", title: "Local Album Song 1"),
                      "alb-2": try FakePlaybackCatalog.track(id: "i.alb-2", title: "Local Album Song 2")]
        #expect(await fixture.controller.playCollection(library, songs: songs, startingAt: nil,
                                                        recordsRecent: false, tracks: tracks, context: fixture.context))

        #expect(Set(fixture.player.submittedTitles.last ?? []) == ["Local Album Song 1", "Local Album Song 2"])
    }

    /// A song first cached by a Recents play (looked up in the catalog), then
    /// played from the library: the library copy is queued.
    @Test func libraryPlayAfterARecentsPlayQueuesTheLibraryCopy() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp(); clearCache(fixture) }
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        let recents = PlaybackCollection(kind: .album, catalogID: "album-1", title: "Test Album")
        let songs = [Self.collectionSong("alb-1", "Album Song 1"), Self.collectionSong("alb-2", "Album Song 2")]
        #expect(await fixture.controller.playCollection(recents, songs: songs, startingAt: "alb-1",
                                                        recordsRecent: false, context: fixture.context))
        #expect(fixture.player.submittedTitles.last == ["Album Song 1", "Album Song 2"])

        let library = PlaybackCollection(kind: .libraryPlaylist, catalogID: "p.library-recent", title: "Library")
        let tracks = ["alb-1": try FakePlaybackCatalog.track(id: "i.alb-1", title: "Local Album Song 1"),
                      "alb-2": try FakePlaybackCatalog.track(id: "i.alb-2", title: "Local Album Song 2")]
        #expect(await fixture.controller.playCollection(library, songs: songs, startingAt: "alb-1",
                                                        recordsRecent: false, tracks: tracks, context: fixture.context))

        #expect(fixture.player.submittedTitles.last == ["Local Album Song 1", "Local Album Song 2"])
    }

    /// A library song removed and re-added has a new library ID; the next
    /// Library play queues that, not the cached copy's old ID.
    @Test func libraryPlayOfAReAddedSongQueuesItsNewLibraryID() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp(); clearCache(fixture) }
        fixture.controller.playbackCatalog = FakePlaybackCatalog().catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        let collection = PlaybackCollection(kind: .libraryPlaylist, catalogID: "p.readded", title: "Re-added")
        let songs = [Self.collectionSong("cat-x", "Song X")]
        #expect(await fixture.controller.playCollection(
            collection, songs: songs, startingAt: nil, recordsRecent: false,
            tracks: ["cat-x": try FakePlaybackCatalog.track(id: "i.old-x", title: "Song X")], context: fixture.context))

        #expect(await fixture.controller.playCollection(
            collection, songs: songs, startingAt: nil, recordsRecent: false,
            tracks: ["cat-x": try FakePlaybackCatalog.track(id: "i.new-x", title: "Song X")], context: fixture.context))

        #expect(fixture.player.submitCount == 2)
        #expect(fixture.player.queueEntries.map { $0.item?.id } == ["i.new-x"])
    }
}
