import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// A catalog that answers Play Album and Play Artist from fixed contents, or fails.
@MainActor
final class FakePlaybackCatalog {
    var contents: [PlaybackCollection.Request: PlaybackCollectionContents] = [:]
    var failure: Error?
    private(set) var requests: [(PlaybackCollection.Request, String)] = []
    private(set) var songRequests: [[String]] = []

    var catalog: PlaybackCatalog {
        PlaybackCatalog(
            collection: { [self] request, songID in
                requests.append((request, songID))
                if let failure { throw failure }
                guard let contents = contents[request] else { throw PlaybackCollectionError.albumNotFound }
                return contents
            },
            songs: { [self] ids in
                songRequests.append(ids)
                if let failure { throw failure }
                let tracks = contents.values.flatMap(\.tracks)
                return Dictionary(tracks.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
            }
        )
    }

    static func track(id: String, title: String, artist: String = "Artist 0") throws -> Track {
        try JSONDecoder().decode(Track.self, from: PlaybackFixture.encodedTrack(id: id, title: title, artist: artist))
    }

    /// An album holding fixture song 0 (tracked, catalog ID `cat-0`) and two
    /// songs Overplay does not track.
    static func album() throws -> PlaybackCollectionContents {
        PlaybackCollectionContents(
            collection: PlaybackCollection(kind: .album, catalogID: "album-1", title: "Test Album"),
            tracks: [try track(id: "cat-0", title: "Song 0"), try track(id: "alb-1", title: "Album Song 1"),
                     try track(id: "alb-2", title: "Album Song 2")]
        )
    }
}

/// Play Album and Play Artist (`PLAY-018`), through the shared controller
/// action that the app and CarPlay both call.
@MainActor
@Suite("Play album and artist", .serialized)
struct PlaybackCollectionTests {
    private func playing(_ fixture: PlaybackFixture, at index: Int = 0) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    private func catalog(for fixture: PlaybackFixture, album: PlaybackCollectionContents? = nil) throws -> FakePlaybackCatalog {
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try album ?? FakePlaybackCatalog.album()
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        return catalog
    }

    // MARK: - Starting

    @Test func playAlbumStartsTheAlbumFromTrackOneThroughTheSharedStart() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let catalog = try catalog(for: fixture)
        await playing(fixture, at: 1)

        let started = await fixture.controller.playCurrentCollection(.album, context: fixture.context)

        #expect(started)
        #expect(catalog.requests.map(\.1) == ["cat-1"])
        #expect(fixture.player.submittedTitles.last == ["Song 0", "Album Song 1", "Album Song 2"])
        #expect(fixture.player.submittedStartIndices.last == 0)
        // Paused, submitted, loaded, then played: the shared start (#76).
        #expect(Array(fixture.player.commands.suffix(4)) == ["pause", "submit", "prepare", "play"])
        let intent = try #require(fixture.intentStore.loadIntent())
        #expect(intent.collection?.kind == .album)
        #expect(intent.members.first?.localTrackID == fixture.tracks[0].id.uuidString)
        #expect(intent.members.last?.localTrackID == PlaybackIntent.Member.untrackedID(catalogID: "alb-2"))
        #expect(intent.members.map(\.catalogSongID) == ["cat-0", "alb-1", "alb-2"])
        #expect(fixture.controller.playbackCollectionTitle == "Album · Test Album")
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        #expect(fixture.controller.isPlaying)
    }

    @Test func playArtistPlaysWhatTheCatalogChose() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let catalog = try catalog(for: fixture)
        catalog.contents[.artist] = PlaybackCollectionContents(
            collection: PlaybackCollection(kind: .artistTopSongs, catalogID: "artist-0", title: "Artist 0"),
            tracks: [try FakePlaybackCatalog.track(id: "top-1", title: "Hit")]
        )
        await playing(fixture)

        #expect(await fixture.controller.playCurrentCollection(.artist, context: fixture.context))
        #expect(catalog.requests.map(\.0) == [.artist])
        #expect(fixture.player.submittedTitles.last == ["Hit"])
        #expect(fixture.controller.playbackCollectionTitle == "Artist 0 · Top Songs")
    }

    @Test func failedLookupChangesNothing() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let catalog = try catalog(for: fixture)
        catalog.failure = PlaybackCollectionError.artistNotFound
        await playing(fixture)
        let intent = fixture.controller.intent

        let started = await fixture.controller.playCurrentCollection(.artist, context: fixture.context)

        #expect(!started)
        #expect(fixture.controller.intent == intent)
        #expect(fixture.intentStore.loadIntent() == intent)
        #expect(fixture.player.submitCount == 1)
        #expect(fixture.controller.isPlaying)
        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.statusMessage?.hasPrefix("Couldn't play the artist") == true)
    }

    @Test func nothingPlayingOffersNothingToLookUp() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let catalog = try catalog(for: fixture)

        #expect(!fixture.controller.canPlayCurrentCollection)
        #expect(!(await fixture.controller.playCurrentCollection(.album, context: fixture.context)))
        #expect(catalog.requests.isEmpty)
        #expect(fixture.player.submitCount == 0)
    }

    // MARK: - Tracked and untracked songs

    @Test func trackedSongsCountAndKeepTheirCurationWhileUntrackedSongsOfferAdd() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        _ = try catalog(for: fixture)
        await playing(fixture, at: 1)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)

        #expect(fixture.controller.currentPlaylistRole(context: fixture.context) == .oneTruePlaylist)
        #expect(!fixture.controller.canAddCurrentToOverplay)
        await fixture.listen(to: 170)
        #expect(try fixture.item(0).playthroughCount == 1)

        await fixture.player.externallyAdvance()
        #expect(fixture.controller.currentTrack?.title == "Album Song 1")
        #expect(fixture.controller.currentMember?.trackID == nil)
        #expect(fixture.controller.currentPlaylistRole(context: fixture.context) == nil)
        #expect(fixture.controller.canAddCurrentToOverplay)
        #expect(fixture.controller.canAddCurrentToOneTruePlaylist(context: fixture.context))
        #expect(fixture.controller.displayedPlaythroughCount(context: fixture.context) == 0)

        await fixture.listen(to: 170)
        await fixture.player.externallyAdvance()
        #expect(try TrackRecordRepository.allTracks(in: fixture.context).count == 3)
        #expect(try fixture.item(0).playthroughCount == 1)
    }

    @Test func retiredSongsInTheAlbumStillPlay() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let album = PlaybackCollectionContents(
            collection: PlaybackCollection(kind: .album, catalogID: "album-1", title: "Test Album"),
            tracks: [try FakePlaybackCatalog.track(id: "alb-1", title: "Album Song 1"),
                     try FakePlaybackCatalog.track(id: "cat-1", title: "Song 1", artist: "Artist 1")]
        )
        _ = try catalog(for: fixture, album: album)
        await playing(fixture)
        try fixture.item(1).evictedAt = .now
        try fixture.context.save()
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)

        await fixture.player.externallyAdvance()

        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[1].id.uuidString)
        #expect(!fixture.player.commands.contains("next"))
        #expect(fixture.controller.displayedIsEvicted(context: fixture.context))
    }

    @Test func addToTriageTracksTheSongAndCountsFromItsNextListen() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        _ = try catalog(for: fixture)
        await playing(fixture)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        await fixture.player.externallyAdvance()
        await fixture.listen(seconds: 3)

        await fixture.controller.addCurrentToTriage(context: fixture.context)

        #expect(fixture.controller.statusMessage == "Added to Triage.")
        let trackID = try #require(fixture.controller.currentMember?.trackID)
        let item = try #require(try PlaylistItemRepository.item(trackID: trackID, in: fixture.context))
        #expect(item.playlistID == (try PlaylistRepository.triageBucket(in: fixture.context)).id)
        #expect(item.isExplicitlyKept)
        #expect(!fixture.controller.canAddCurrentToOverplay)
        #expect(fixture.controller.currentPlaylistRole(context: fixture.context) == .triageBucket)
        #expect(fixture.player.submitCount == 2)
        #expect(fixture.intentStore.loadIntent()?.members[1].localTrackID == trackID.uuidString)

        // The listen in progress when it was added is not counted.
        await fixture.listen(to: 170)
        await fixture.player.externallyAdvance()
        #expect(item.playthroughCount == 0)
        #expect(item.skipCount == 0)
    }

    @Test func addToOneTruePlaylistWritesAppleMusicFirst() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        _ = try catalog(for: fixture)
        var remoteAdds: [(String, String)] = []
        fixture.controller.addCatalogSongToPlaylist = { songID, playlist, _ in
            remoteAdds.append((songID, playlist.musicPlaylistID))
        }
        await playing(fixture)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        await fixture.player.externallyAdvance()

        await fixture.controller.addCurrentToOneTruePlaylist(context: fixture.context)

        #expect(remoteAdds.map(\.0) == ["alb-1"])
        #expect(remoteAdds.map(\.1) == [fixture.playlist.musicPlaylistID])
        #expect(fixture.controller.currentPlaylistRole(context: fixture.context) == .oneTruePlaylist)
        #expect(fixture.controller.statusMessage == "Added to the One True Playlist.")
    }

    @Test func failedOneTruePlaylistAddAddsNothing() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        _ = try catalog(for: fixture)
        fixture.controller.addCatalogSongToPlaylist = { _, _, _ in throw PlaylistMutationError.musicItemMissing }
        await playing(fixture)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        await fixture.player.externallyAdvance()

        await fixture.controller.addCurrentToOneTruePlaylist(context: fixture.context)

        #expect(fixture.controller.canAddCurrentToOverplay)
        #expect(try TrackRecordRepository.allTracks(in: fixture.context).count == 3)
        #expect(fixture.controller.statusMessage?.hasPrefix("Couldn't add Album Song 1") == true)
    }

    // MARK: - Afterwards

    @Test func selectingAPlaylistTrackAfterwardsStartsAPlaylistIntent() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        _ = try catalog(for: fixture)
        await playing(fixture)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)

        // Song 0 is in the album too, but the album is not this playlist.
        await playing(fixture, at: 0)

        #expect(fixture.controller.intent?.collection == nil)
        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.player.submitCount == 3)
        #expect(fixture.player.submittedTitles.last == ["Song 0", "Song 1", "Song 2"])
    }

    @Test func playAfterRelaunchResumesTheAlbumFromTheCatalog() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        _ = try catalog(for: fixture)
        await playing(fixture)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        await fixture.player.externallyAdvance()
        fixture.controller.pause()

        let player = FakePlaybackPlayer()
        let relaunched = PlaybackController(player: player, intentStore: fixture.intentStore,
                                            preparePlaybackTracks: { _, _ in }, sleep: PlaybackFixture.manualSampling)
        let catalog = try catalog(for: fixture)
        relaunched.playbackCatalog = catalog.catalog
        // A device that has not played these songs looks them up.
        relaunched.collectionTrackCache = DevicePlaybackCache(directory: nil)
        defer { relaunched.stopMonitoring() }
        relaunched.restoreLocalPlaybackDisplay(context: fixture.context)
        relaunched.startMonitoring(context: fixture.context)
        #expect(relaunched.playbackCollectionTitle == "Album · Test Album")

        await relaunched.play(context: fixture.context)

        #expect(catalog.songRequests == [["cat-0", "alb-1", "alb-2"]])
        #expect(player.submittedTitles == [["Song 0", "Album Song 1", "Album Song 2"]])
        #expect(player.submittedStartIndices == [1])
        #expect(relaunched.intent?.collection?.kind == .album)
        #expect(relaunched.currentTrack?.title == "Album Song 1")
    }

    /// Recovering an album needs no network (#84): its songs were cached
    /// on this device when it started, so rung 3 resubmits from the cache.
    @Test func recoveringAnAlbumWorksWithTheCatalogUnreachable() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let catalog = try catalog(for: fixture)
        await playing(fixture)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        await fixture.player.externallyAdvance()
        catalog.failure = URLError(.notConnectedToInternet)
        let lookupsBefore = catalog.songRequests.count
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
        #expect(fixture.controller.playbackFailure?.kind == .stalled)

        // Rung 2's prepare fails, so the same press reaches rung 3.
        fixture.player.prepareFailuresRemaining = 1
        await fixture.controller.play(context: fixture.context)

        #expect(catalog.songRequests.count == lookupsBefore)
        #expect(fixture.player.submittedTitles.last == ["Song 0", "Album Song 1", "Album Song 2"])
        #expect(fixture.player.submittedStartIndices.last == 1)
        #expect(fixture.controller.intent?.collection?.kind == .album)
        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.currentTrack?.title == "Album Song 1")
    }
}

@Suite("Play artist choices")
struct PlaybackCollectionPolicyTests {
    @Test func versionsOfOneSongCollapseToTheHighestRanked() {
        let songs: [(title: String, isrc: String?)] = [
            ("Hey Jude", "GB1"), ("Let It Be (Live)", nil), ("Hey Jude - Remastered 2015", "GB2"),
            ("Let It Be", nil), ("Something [Deluxe]", nil), ("Come Together", "GB9"), ("Come Together Again", "GB9")
        ]
        let kept = PlaybackCollectionPolicy.collapsingVersions(songs, title: \.title, isrc: \.isrc).map(\.title)
        #expect(kept == ["Hey Jude", "Let It Be (Live)", "Something [Deluxe]", "Come Together"])
    }

    @Test func essentialsIsTheAppleMusicPlaylistNamedForTheArtist() {
        #expect(PlaybackCollectionPolicy.isEssentials(playlistName: "The Beatles Essentials", curatorName: "Apple Music",
                                                      isEditorial: nil, artistName: "The Beatles"))
        #expect(PlaybackCollectionPolicy.isEssentials(playlistName: "beyoncé essentials", curatorName: nil,
                                                      isEditorial: true, artistName: "Beyoncé"))
        #expect(!PlaybackCollectionPolicy.isEssentials(playlistName: "The Beatles: Deep Cuts", curatorName: "Apple Music",
                                                       isEditorial: true, artistName: "The Beatles"))
        #expect(!PlaybackCollectionPolicy.isEssentials(playlistName: "The Beatles Essentials", curatorName: "A Fan",
                                                       isEditorial: false, artistName: "The Beatles"))
    }

    @Test func carPlayOffersOnlyAddForAnUntrackedSong() {
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: nil, isRetired: false, canAddToOverplay: true)
            == [.shuffle, .repeatMode, .addToTriage, .addToOneTruePlaylist])
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .oneTruePlaylist, isRetired: false)
            == [.shuffle, .repeatMode, .retire])
    }

    @Test func carPlayDoesNotCarryCurationOntoAnUntrackedSong() {
        let previous = CarPlayNowPlayingButtonSignature(hasCurrentTrack: true, playlistRole: .oneTruePlaylist, isEvicted: false)
        let untracked = CarPlayNowPlayingButtonSignature(hasCurrentTrack: true, playlistRole: nil, isEvicted: false,
                                                          canAddToOverplay: true, canAddToOneTruePlaylist: true)
        #expect(untracked.resolvingLayout(previous: previous, samePlaylist: true) == untracked)
    }
}
