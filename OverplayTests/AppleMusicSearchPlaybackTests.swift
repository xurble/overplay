import Foundation
import SwiftData
import Testing
@testable import Overplay

/// Playing what an Apple Music search found by voice (`SIRI-003`), through
/// the shared `playCatalogItem` and Siri's adapter, and the search cache
/// that answers Siri's three queries with one request.
@MainActor
@Suite("Apple Music search playback", .serialized)
struct AppleMusicSearchPlaybackTests {
    private func catalog(for fixture: PlaybackFixture) throws -> FakePlaybackCatalog {
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        catalog.contents[.artist] = PlaybackCollectionContents(
            collection: PlaybackCollection(kind: .artistEssentials, catalogID: "artist-1", title: "Artist 0"),
            tracks: [try FakePlaybackCatalog.track(id: "art-1", title: "Artist Song 1"),
                     try FakePlaybackCatalog.track(id: "art-2", title: "Artist Song 2")]
        )
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        return catalog
    }

    private let searchedSong = PlaybackCollectionSong(catalogID: "alb-2", title: "Album Song 2", artistName: "Artist 0",
                                                      albumTitle: "Test Album", artworkURLTemplate: nil)

    // MARK: - The shared action

    @Test func aSongPlaysOnItsOwnLikeSearchsPlayNowAndIsNotARecent() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        _ = try catalog(for: fixture)

        let started = await fixture.controller.playCatalogItem(.song(searchedSong), context: fixture.context)

        #expect(started)
        #expect(fixture.player.submittedTitles.last == ["Album Song 2"])
        #expect(fixture.controller.currentTrack?.title == "Album Song 2")
        #expect(try RecentCollectionRepository.recents(in: fixture.context).isEmpty)
    }

    @Test func anAlbumPlaysInOrderFromTrackOneByItsIDAndIsARecent() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try catalog(for: fixture)

        let started = await fixture.controller.playCatalogItem(.album(id: "album-1", title: "Test Album"),
                                                               context: fixture.context)

        #expect(started)
        #expect(catalog.idRequests.map(\.1) == ["album-1"])
        #expect(catalog.requests.isEmpty)
        #expect(fixture.player.submittedTitles.last == ["Song 0", "Album Song 1", "Album Song 2"])
        #expect(fixture.player.submittedStartIndices.last == 0)
        #expect(!fixture.controller.shuffleEnabled)
        #expect(try RecentCollectionRepository.recents(in: fixture.context).map(\.catalogID) == ["album-1"])
    }

    @Test func anArtistAskedForShuffledStartsShuffled() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try catalog(for: fixture)

        let started = await fixture.controller.playCatalogItem(.artist(id: "artist-1", name: "Artist 0"), shuffle: true,
                                                               context: fixture.context)

        #expect(started)
        #expect(catalog.idRequests.map(\.0) == [.artist])
        #expect(fixture.controller.shuffleEnabled)
        #expect(fixture.controller.currentPlaylistContext != nil)
    }

    @Test func aFailedLookupChangesNothingAndSaysWhy() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try catalog(for: fixture)
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)
        catalog.failure = URLError(.notConnectedToInternet)

        let started = await fixture.controller.playCatalogItem(.album(id: "album-1", title: "Test Album"),
                                                               context: fixture.context)

        #expect(!started)
        #expect(fixture.controller.statusMessage != nil)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(fixture.player.submitCount == 1)
    }

    // MARK: - Siri's adapter

    @Test func playingASearchResultByVoiceSaysNothingOnceItPlays() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        _ = try catalog(for: fixture)

        let failure = await VoiceActions.playCatalogItem(.album(id: "album-1", title: "Test Album"), shuffle: false,
                                                         controller: fixture.controller, context: fixture.context)

        #expect(failure == nil)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
    }

    @Test func aSearchResultThatCannotPlaySaysWhyByVoice() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try catalog(for: fixture)
        catalog.contents[.album] = nil

        let failure = await VoiceActions.playCatalogItem(.album(id: "album-9", title: "Gone"), shuffle: false,
                                                         controller: fixture.controller, context: fixture.context)

        #expect(failure != nil)
        #expect(fixture.player.submitCount == 0)
    }

    // MARK: - The search cache

    @Test func siriQueriesForOnePhraseShareOneSearch() async throws {
        AppleMusicCatalogSearch.reset()
        defer { AppleMusicCatalogSearch.reset(); AppleMusicCatalogSearch.request = { _ in .init() } }
        var terms: [String] = []
        let results = AppleMusicCatalogSearch.Results(
            songs: [.init(id: "s1", title: "Creep", artistName: "Radiohead")],
            albums: [.init(id: "a1", title: "OK Computer", artistName: "Radiohead")],
            artists: [.init(id: "r1", name: "Radiohead")]
        )
        AppleMusicCatalogSearch.request = { term in terms.append(term); return results }

        let songs = try await AppleMusicCatalogSearch.search("Radio").songs
        let albums = try await AppleMusicCatalogSearch.search("radio ").albums
        let byID = try await AppleMusicCatalogSearch.artists(ids: ["r1"])

        #expect(terms == ["Radio"])
        #expect(songs.map(\.id) == ["s1"] && albums.map(\.id) == ["a1"])
        #expect(byID.map(\.name) == ["Radiohead"])
    }

    // MARK: - One kind offered to Siri

    private let publicEnemy = AppleMusicCatalogSearch.Results(
        songs: [.init(id: "s1", title: "Fight the Power", artistName: "Public Enemy")],
        albums: [.init(id: "a1", title: "Fear of a Black Planet", artistName: "Public Enemy")],
        artists: [.init(id: "r1", name: "Public Enemy"), .init(id: "r2", name: "Public Enemy Tribute")],
        topKind: .song
    )

    /// "Play Public Enemy in Overplay" played one song (2026-11-14): an
    /// exact artist name now offers only that artist.
    @Test func anExactArtistNameOffersOnlyThatArtist() {
        let focused = AppleMusicCatalogSearch.focused(publicEnemy, on: "public enemy")

        #expect(focused.artists.map(\.id) == ["r1"])
        #expect(focused.songs.isEmpty && focused.albums.isEmpty)
    }

    @Test func anExactAlbumOrSongTitleOffersOnlyThat() {
        let album = AppleMusicCatalogSearch.focused(publicEnemy, on: "Fear of a Black Planet")
        let song = AppleMusicCatalogSearch.focused(publicEnemy, on: "Fight the Power by Public Enemy")

        #expect(album.albums.map(\.id) == ["a1"] && album.songs.isEmpty && album.artists.isEmpty)
        #expect(song.songs.map(\.id) == ["s1"] && song.albums.isEmpty && song.artists.isEmpty)
    }

    @Test func withoutAnExactMatchAppleMusicsTopKindIsOffered() {
        var results = publicEnemy
        results.topKind = .album

        let focused = AppleMusicCatalogSearch.focused(results, on: "black planet")

        #expect(focused.albums.map(\.id) == ["a1"] && focused.songs.isEmpty && focused.artists.isEmpty)
    }

    @Test func withNoExactMatchOrTopKindEverythingIsOffered() {
        var results = publicEnemy
        results.topKind = nil

        #expect(AppleMusicCatalogSearch.focused(results, on: "enemy power") == results)
    }

    @Test func anOldSearchIsAskedAgain() async throws {
        AppleMusicCatalogSearch.reset()
        var clock = Date(timeIntervalSince1970: 0)
        defer {
            AppleMusicCatalogSearch.reset()
            AppleMusicCatalogSearch.request = { _ in .init() }
            AppleMusicCatalogSearch.now = { .now }
        }
        AppleMusicCatalogSearch.now = { clock }
        var count = 0
        AppleMusicCatalogSearch.request = { _ in count += 1; return .init() }

        _ = try await AppleMusicCatalogSearch.search("Blur")
        clock.addTimeInterval(AppleMusicCatalogSearch.cacheLifetime + 1)
        _ = try await AppleMusicCatalogSearch.search("Blur")
        _ = try await AppleMusicCatalogSearch.search("")

        #expect(count == 2)
    }
}
