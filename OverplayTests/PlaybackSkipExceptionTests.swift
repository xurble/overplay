import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// `COUNT-003` (owner request, 2026-10-30): starting something else, or
/// ending a song after a long pause, is not a skip.
@MainActor
@Suite("Skips not counted", .serialized)
struct PlaybackSkipExceptionTests {
    private func start(_ fixture: PlaybackFixture, at index: Int) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    /// Paused, then playing again after `seconds`.
    private func pause(_ fixture: PlaybackFixture, for seconds: TimeInterval) async {
        fixture.controller.pause()
        await fixture.controller.samplePlayback()
        fixture.player.playbackStatus = .playing
        await fixture.controller.samplePlayback(now: .now.addingTimeInterval(seconds))
    }

    @Test func skippingWithinTheQueueStillCounts() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        await fixture.player.externallyAdvance()
        #expect(try fixture.item(0).skipCount == 1)
    }

    /// The live queue cannot take the selection (not loaded yet, windowed
    /// by shuffle, or re-issued), so it is resubmitted from that song: still
    /// a skip within the playlist, as a jump in the queue is.
    @Test func selectingASongTheQueueCannotTakeStillCounts() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        fixture.player.replaceItem(at: 2, with: PlayerItemSnapshot(
            id: "foreign", identifiers: ["foreign"], title: "Someone Else", artistName: "Elsewhere",
            albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 200))
        await start(fixture, at: 2)
        #expect(fixture.player.submitCount == 2, "The selection should be resubmitted")
        #expect(fixture.controller.currentTrack?.title == "Song 2")
        #expect(try fixture.item(0).skipCount == 1)
    }

    /// A song synced into the playing playlist after it started is not in
    /// the intent, so choosing it starts a new one: still the same playlist.
    @Test func selectingASongNewToThePlayingPlaylistStillCounts() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        let added = try addTrack(3, to: fixture.playlist, in: fixture)
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: added,
                                              settings: fixture.settings, context: fixture.context)
        #expect(fixture.player.submitCount == 2)
        #expect(fixture.controller.currentTrack?.title == "Song 3")
        #expect(try fixture.item(0).skipCount == 1)
    }

    @Test func selectingASongOfAnotherPlaylistIsNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        let other = PlaylistRecord(musicPlaylistID: "playlist-other", name: "Other", role: .triageSource)
        fixture.context.insert(other)
        let added = try addTrack(3, to: other, in: fixture)
        await fixture.controller.playPlaylist(other, startingAt: added,
                                              settings: fixture.settings, context: fixture.context)
        #expect(fixture.controller.currentTrack?.title == "Song 3")
        #expect(try fixture.item(0).skipCount == 0)
    }

    // MARK: - Albums, artists and other collections

    @Test func selectingAnotherSongOfThePlayingAlbumStillCounts() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let album = try await playingAlbum(fixture)
        // The live queue cannot take it, so it is resubmitted from that song.
        fixture.player.replaceItem(at: 1, with: PlayerItemSnapshot(
            id: "foreign", identifiers: ["foreign"], title: "Someone Else", artistName: "Elsewhere",
            albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 200))
        await fixture.controller.playCollection(album.collection, songs: Self.songs(album), startingAt: "alb-1",
                                                recordsRecent: false, context: fixture.context)
        #expect(fixture.player.submitCount == 2, "The selection should be resubmitted")
        #expect(fixture.controller.currentTrack?.title == "Album Song 1")
        #expect(try fixture.item(0).skipCount == 1)
    }

    /// Restarting the playing album is a new start, not a judgement on the
    /// song: Shuffle and Play, as on a playlist (`PLAY-020`), counts nothing.
    @Test func shuffleAndPlayOfThePlayingAlbumIsNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let album = try await playingAlbum(fixture)
        await fixture.controller.playCollection(album.collection, songs: Self.songs(album), startingAt: nil,
                                                recordsRecent: false, context: fixture.context)
        #expect(fixture.player.submitCount == 2)
        #expect(try fixture.item(0).skipCount == 0)
    }

    @Test func playAlbumDuringThatAlbumIsNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        _ = try await playingAlbum(fixture)
        let started = await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        #expect(started)
        #expect(fixture.player.submitCount == 2)
        #expect(try fixture.item(0).skipCount == 0)
    }

    /// Fixture song 0 (tracked) playing for 20 seconds as track 1 of an album.
    private func playingAlbum(_ fixture: PlaybackFixture) async throws -> PlaybackCollectionContents {
        let album = try FakePlaybackCatalog.album()
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = album
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        let started = await fixture.controller.playCollection(album.collection, songs: Self.songs(album), startingAt: "cat-0",
                                                              recordsRecent: false, context: fixture.context)
        #expect(started)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        await fixture.listen(seconds: 20)
        return album
    }

    private static func songs(_ album: PlaybackCollectionContents) -> [PlaybackCollectionSong] {
        album.tracks.map { PlaybackCollectionSong(catalogID: $0.id.rawValue, title: $0.title, artistName: $0.artistName) }
    }

    private func addTrack(_ index: Int, to playlist: PlaylistRecord, in fixture: PlaybackFixture) throws -> TrackRecord {
        let track = TrackRecord(catalogID: "cat-\(index)", libraryID: "i.lib-\(index)",
                                title: "Song \(index)", artistName: "Artist \(index)", durationSeconds: 180)
        fixture.context.insert(track)
        fixture.context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: track.id))
        DevicePlaybackCache.shared.set(try PlaybackFixture.encodedTrack(id: "i.lib-\(index)", title: "Song \(index)",
                                                                        artist: "Artist \(index)"), for: track.id)
        try fixture.context.save()
        return track
    }

    @Test func aResubmissionIsTheSameQueueOnlyForTheSamePlaylistScopeOrCollection() {
        func intent(_ playlistID: String, _ scope: PlaylistPlaybackScope = .active,
                    collection: PlaybackCollection? = nil) -> PlaybackIntent {
            PlaybackIntent(id: UUID(), createdAt: .now, musicPlaylistID: playlistID, scope: scope, members: [],
                           collection: collection)
        }
        let album = PlaybackCollection(kind: .album, catalogID: "alb-1", title: "Album")
        let otherAlbum = PlaybackCollection(kind: .album, catalogID: "alb-2", title: "Other")
        #expect(intent("p1").playsSameQueue(as: intent("p1")))
        #expect(!intent("p1").playsSameQueue(as: intent("p2")))
        #expect(!intent("p1").playsSameQueue(as: intent("p1", .retired)))
        #expect(intent("x", collection: album).playsSameQueue(as: intent("y", collection: album)))
        #expect(!intent("x", collection: album).playsSameQueue(as: intent("x", collection: otherAlbum)))
        #expect(!intent("p1").playsSameQueue(as: intent("p1", collection: album)))
    }

    @Test func startingAnotherQueueIsNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        // Play Now from Search: a new queue.
        let started = await fixture.controller.playCollection(
            PlaybackCollection(kind: .searchSong, catalogID: "alb-1", title: "Album Song 1"),
            songs: [PlaybackCollectionSong(catalogID: "alb-1", title: "Album Song 1", artistName: "Artist 0")],
            startingAt: "alb-1", recordsRecent: false, context: fixture.context
        )
        #expect(started)
        #expect(fixture.controller.currentTrack?.title == "Album Song 1")
        #expect(try fixture.item(0).skipCount == 0)
    }

    @Test func endingASongAfterALongPauseIsNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        await pause(fixture, for: PlaybackController.longPauseSeconds + 1)
        await fixture.listen(seconds: 5)
        await fixture.player.externallyAdvance()
        #expect(try fixture.item(0).skipCount == 0)
    }

    @Test func aShortPauseStillCountsTheSkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        await pause(fixture, for: PlaybackController.longPauseSeconds - 30)
        await fixture.listen(seconds: 5)
        await fixture.player.externallyAdvance()
        #expect(try fixture.item(0).skipCount == 1)
    }

    @Test func aLongPauseIsOneMinute() {
        #expect(PlaybackController.longPauseSeconds == 60)
    }
}
