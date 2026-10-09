import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// Recents (`PLAY-019`): the 10 most recently played albums and artists,
/// played through the same shared actions as playlists.
@MainActor
@Suite("Recents", .serialized)
struct RecentsTests {
    private func album(_ id: String, title: String) -> PlaybackCollection {
        PlaybackCollection(kind: .album, catalogID: id, title: title)
    }

    private func song(_ id: String) -> PlaybackCollectionSong {
        PlaybackCollectionSong(catalogID: id, title: "Song \(id)", artistName: "Artist")
    }

    // MARK: - Repository

    @Test func newestFirstReplayMovesToFrontAndTheEleventhDropsTheOldest() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<10 {
            try RecentCollectionRepository.record(album("a\(index)", title: "A\(index)"), songs: [song("s\(index)")],
                                                  artworkURLTemplate: nil, at: start.addingTimeInterval(Double(index)), in: context)
        }
        try RecentCollectionRepository.record(album("a3", title: "A3"), songs: [song("s3")], artworkURLTemplate: nil,
                                              at: start.addingTimeInterval(20), in: context)
        #expect(try RecentCollectionRepository.recents(in: context).map(\.catalogID).prefix(2) == ["a3", "a9"])

        try RecentCollectionRepository.record(album("new", title: "New"), songs: [song("n")], artworkURLTemplate: nil,
                                              at: start.addingTimeInterval(30), in: context)

        let ids = try RecentCollectionRepository.recents(in: context).map(\.catalogID)
        #expect(ids.count == 10)
        #expect(ids.first == "new")
        #expect(!ids.contains("a0"))
        #expect(try context.fetchCount(FetchDescriptor<RecentCollectionRecord>()) == 10)
    }

    @Test func anArtistIsOneEntryWhicheverCollectionPlayed() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        try RecentCollectionRepository.record(PlaybackCollection(kind: .artistEssentials, catalogID: "art", title: "James"),
                                              songs: [song("e")], artworkURLTemplate: "https://art/{w}x{h}.jpg", in: context)
        try RecentCollectionRepository.record(PlaybackCollection(kind: .artistTopSongs, catalogID: "art", title: "James"),
                                              songs: [song("t")], artworkURLTemplate: nil, in: context)

        let recents = try RecentCollectionRepository.recents(in: context)
        #expect(recents.count == 1)
        #expect(recents.first?.collection.kind == .artistTopSongs)
        #expect(recents.first?.songs.map(\.catalogID) == ["t"])
        // A later play without artwork keeps the image already saved.
        #expect(recents.first?.artworkURLTemplate == "https://art/{w}x{h}.jpg")
    }

    @Test func copiesFromAnotherDeviceAreHiddenOnReadAndMergedOnTheNextRecord() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let collection = album("dup", title: "Dup")
        context.insert(RecentCollectionRecord(collection: collection, songs: [song("old")], artworkURLTemplate: nil,
                                              playedAt: Date(timeIntervalSince1970: 1)))
        context.insert(RecentCollectionRecord(collection: collection, songs: [song("new")], artworkURLTemplate: nil,
                                              playedAt: Date(timeIntervalSince1970: 2)))
        try context.save()

        let read = try RecentCollectionRepository.recents(in: context)
        #expect(read.map { $0.songs.first?.catalogID } == ["new"])
        #expect(try context.fetchCount(FetchDescriptor<RecentCollectionRecord>()) == 2)

        try RecentCollectionRepository.record(album("other", title: "Other"), songs: [song("o")], artworkURLTemplate: nil, in: context)
        #expect(try context.fetchCount(FetchDescriptor<RecentCollectionRecord>()) == 2)
        #expect(try RecentCollectionRepository.recents(in: context).map(\.catalogID) == ["other", "dup"])
    }

    // MARK: - Playing

    private func playingAlbum() async throws -> (PlaybackFixture, FakePlaybackCatalog) {
        let fixture = try PlaybackFixture()
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        catalog.contents[.album]?.artworkURLTemplate = "https://cover/{w}x{h}.jpg"
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        return (fixture, catalog)
    }

    @Test func playAlbumAddsItToRecentsWithItsSongsAndCover() async throws {
        let (fixture, _) = try await playingAlbum()
        defer { fixture.cleanUp() }

        let recent = try #require(try RecentCollectionRepository.recents(in: fixture.context).first)
        #expect(recent.title == "Test Album")
        #expect(recent.artworkURLTemplate == "https://cover/{w}x{h}.jpg")
        #expect(recent.songs.map(\.catalogID) == ["cat-0", "alb-1", "alb-2"])
        #expect(fixture.controller.playingCollectionGroupKey == recent.groupKey)
    }

    @Test func shuffleAndPlayFromRecentsUsesTheSavedSongsWithoutTheNetwork() async throws {
        let (fixture, catalog) = try await playingAlbum()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[2],
                                              settings: fixture.settings, context: fixture.context)
        let recent = try #require(try RecentCollectionRepository.recents(in: fixture.context).first)
        catalog.failure = PlaybackCollectionError.empty

        let started = await fixture.controller.playRecent(recent, startingAt: nil, context: fixture.context)

        #expect(started)
        #expect(catalog.songRequests.isEmpty)
        #expect(fixture.player.submittedTitles.last == ["Song 0", "Album Song 1", "Album Song 2"])
        // Shuffle and Play: shuffle on the loaded queue, then a random song.
        #expect(fixture.player.commands.suffix(5) == ["prepare", "shuffle=off", "shuffle=songs", "next", "play"])
        #expect(fixture.controller.intent?.collection?.groupKey == recent.groupKey)
    }

    @Test func aSongFromRecentsStartsThereAndASongInTheLiveQueueIsSelectedInPlace() async throws {
        let (fixture, _) = try await playingAlbum()
        defer { fixture.cleanUp() }
        let recent = try #require(try RecentCollectionRepository.recents(in: fixture.context).first)

        await fixture.controller.playRecent(recent, startingAt: "alb-2", context: fixture.context)

        #expect(fixture.player.submitCount == 2)
        #expect(fixture.player.commands.last == "play")
        #expect(fixture.player.commands.dropLast().last == "select")
        #expect(fixture.controller.currentTrack?.title == "Album Song 2")
    }

    @Test func aSongFromAnotherRecentStartsANewIntentAtThatSong() async throws {
        let (fixture, _) = try await playingAlbum()
        defer { fixture.cleanUp() }
        let recent = try #require(try RecentCollectionRepository.recents(in: fixture.context).first)
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)

        await fixture.controller.playRecent(recent, startingAt: "alb-1", context: fixture.context)

        #expect(fixture.player.submitCount == 4)
        #expect(fixture.player.submittedStartIndices.last == 1)
        #expect(fixture.controller.currentTrack?.title == "Album Song 1")
    }

    @Test func playingFromRecentsMovesTheEntryToTheFront() async throws {
        let (fixture, _) = try await playingAlbum()
        defer { fixture.cleanUp() }
        let album = try #require(try RecentCollectionRepository.recents(in: fixture.context).first)
        try RecentCollectionRepository.record(PlaybackCollection(kind: .album, catalogID: "later", title: "Later"),
                                              songs: [PlaybackCollectionSong(catalogID: "x", title: "X", artistName: "Y")],
                                              artworkURLTemplate: nil, at: album.lastPlayedAt.addingTimeInterval(0.001),
                                              in: fixture.context)
        #expect(try RecentCollectionRepository.recents(in: fixture.context).first?.catalogID == "later")
        try await Task.sleep(for: .milliseconds(20))

        await fixture.controller.playRecent(album, startingAt: nil, context: fixture.context)

        #expect(try RecentCollectionRepository.recents(in: fixture.context).map(\.catalogID) == ["album-1", "later"])
    }

    @Test func onlySongsOverplayTracksShowCounts() async throws {
        let (fixture, _) = try await playingAlbum()
        defer { fixture.cleanUp() }
        let recent = try #require(try RecentCollectionRepository.recents(in: fixture.context).first)

        let songs = RecentCollectionPresentation.songs(for: recent, in: fixture.context)

        #expect(songs.map(\.summary.isTracked) == [true, false, false])
        #expect(songs[0].summary.detailText.contains(songs[0].summary.playSkipMetricLabel))
        #expect(songs[1].summary.detailText == "Artist 0")
        // Now Playing: the tracked song shows counts; the next, untracked, does not.
        #expect(NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, settings: fixture.settings,
                                                           context: fixture.context).isTracked)
        await fixture.player.externallyAdvance()
        #expect(!NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, settings: fixture.settings,
                                                            context: fixture.context).isTracked)
    }

    @Test func unreachableUnplayedSongsChangeNothing() async throws {
        let (fixture, catalog) = try await playingAlbum()
        defer { fixture.cleanUp() }
        let recent = try #require(try RecentCollectionRepository.recents(in: fixture.context).first)
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        catalog.failure = PlaybackCollectionError.empty
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)
        let intent = fixture.controller.intent

        let started = await fixture.controller.playRecent(recent, startingAt: nil, context: fixture.context)

        #expect(!started)
        #expect(fixture.controller.intent == intent)
        #expect(fixture.controller.statusMessage?.hasPrefix("Couldn't play Test Album") == true)
    }

    @Test func albumRecoveryUsesThisDevicesSavedSongs() async throws {
        let (fixture, catalog) = try await playingAlbum()
        defer { fixture.cleanUp() }
        await fixture.player.abandonQueue()
        catalog.failure = PlaybackCollectionError.empty

        await fixture.controller.play(context: fixture.context)

        #expect(catalog.songRequests.isEmpty)
        #expect(fixture.player.submitCount == 3)
        #expect(fixture.controller.playbackFailure == nil)
    }
}

@Suite("CarPlay Back while a Recents entry plays")
struct RecentsBackStackTests {
    private let playing = UUID()

    @Test func theEntryOverRecentsIsAlreadyRight() {
        #expect(!CarPlayNowPlayingBackStack.needsPlayingRecent(
            beneathRecentID: playing, recentsListBeneathThat: true, playingRecentID: playing))
    }

    @Test func aPlaylistOrAnotherEntryBeneathIsReplaced() {
        #expect(CarPlayNowPlayingBackStack.needsPlayingRecent(
            beneathRecentID: nil, recentsListBeneathThat: false, playingRecentID: playing))
        #expect(CarPlayNowPlayingBackStack.needsPlayingRecent(
            beneathRecentID: UUID(), recentsListBeneathThat: true, playingRecentID: playing))
    }

    @Test func theEntryWithoutRecentsBeneathItIsRebuilt() {
        #expect(CarPlayNowPlayingBackStack.needsPlayingRecent(
            beneathRecentID: playing, recentsListBeneathThat: false, playingRecentID: playing))
    }

    @Test func nothingPlayingFromRecentsLeavesTheStackAlone() {
        #expect(!CarPlayNowPlayingBackStack.needsPlayingRecent(
            beneathRecentID: nil, recentsListBeneathThat: false, playingRecentID: nil))
    }
}
