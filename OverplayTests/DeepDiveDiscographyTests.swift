import Foundation
import SwiftData
import Testing
@testable import Overplay

/// A deep dive's artist and albums (`PLAY-021`): the order and choice of
/// albums, the tiles every surface shows, the lookup shared by surfaces, and
/// the one action a tile runs from the app and CarPlay.
@MainActor
@Suite("Deep dive discography", .serialized)
struct DeepDiveDiscographyTests {
    private static func day(_ year: Int) -> Date {
        var components = DateComponents(year: year, month: 1, day: 1)
        components.timeZone = TimeZone(identifier: "GMT")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private let discography = ArtistDiscography(
        artistID: "r1", artistName: "Public Enemy", artistArtworkURL: "artist.jpg",
        albums: [.init(id: "a1", title: "Yo! Bum Rush the Show", releaseDate: Self.day(1987)),
                 .init(id: "album-1", title: "Test Album", releaseDate: Self.day(1988)),
                 .init(id: "a3", title: "Fear of a Black Planet", releaseDate: Self.day(1990))]
    )

    // MARK: - Which albums, in which order

    @Test func albumsRunOldestFirstWithUndatedOnesLast() {
        let albums: [ArtistDiscography.Album] = [
            .init(id: "c", title: "Third", releaseDate: Self.day(1990)),
            .init(id: "x", title: "Undated", releaseDate: nil),
            .init(id: "a", title: "First", releaseDate: Self.day(1987)),
            .init(id: "b", title: "Second", releaseDate: Self.day(1988)),
        ]

        #expect(PlaybackCollectionPolicy.oldestFirst(albums).map(\.id) == ["a", "b", "c", "x"])
    }

    @Test func aCleanCopyGivesWayToTheExplicitOneWhicheverComesFirst() {
        let clean = ArtistDiscography.Album(id: "clean", title: "Nation", releaseDate: Self.day(1988), isClean: true)
        let explicit = ArtistDiscography.Album(id: "explicit", title: "nation", releaseDate: Self.day(1988))

        #expect(PlaybackCollectionPolicy.oldestFirst([clean, explicit]).map(\.id) == ["explicit"])
        #expect(PlaybackCollectionPolicy.oldestFirst([explicit, clean]).map(\.id) == ["explicit"])
    }

    // MARK: - The tiles

    @Test func anAlbumsPageOffersTheArtistThenEveryAlbumWithItselfMarked() {
        let album = PlaybackCollection(kind: .album, catalogID: "album-1", title: "Test Album")

        let tiles = DeepDiveDiscographyPresentation.tiles(for: album, discography: discography, playingGroupKey: "album:a3")

        #expect(tiles.map(\.id) == ["artist:r1", "album:a1", "album:album-1", "album:a3"])
        #expect(tiles.map(\.subtitle) == ["Artist", "1987", "This Album", "1990"])
        #expect(tiles.map(\.isThisPage) == [false, false, true, false])
        #expect(tiles.map(\.isPlaying) == [false, false, false, true])
        #expect(tiles.first?.item == .artist(id: "r1", name: "Public Enemy"))
        #expect(DeepDiveDiscographyPresentation.heading(for: album, discography: discography) == "Public Enemy")
    }

    @Test func anArtistsPageOffersOnlyItsAlbums() {
        let artist = PlaybackCollection(kind: .artistEssentials, catalogID: "r1", title: "Public Enemy")

        let tiles = DeepDiveDiscographyPresentation.tiles(for: artist, discography: discography, playingGroupKey: "artist:r1")

        #expect(tiles.map(\.id) == ["album:a1", "album:album-1", "album:a3"])
        #expect(!tiles.contains(where: \.isThisPage) && !tiles.contains(where: \.isPlaying))
        #expect(DeepDiveDiscographyPresentation.heading(for: artist, discography: discography) == "Albums")
    }

    @Test func onlyAlbumAndArtistDeepDivesOfferADiscography() {
        #expect(DeepDiveDiscographyPresentation.offersDiscography(.init(kind: .album, catalogID: "1", title: "A")))
        #expect(DeepDiveDiscographyPresentation.offersDiscography(.init(kind: .artistTopSongs, catalogID: "1", title: "A")))
        #expect(!DeepDiveDiscographyPresentation.offersDiscography(.init(kind: .libraryAlbum, catalogID: "1", title: "A")))
        #expect(!DeepDiveDiscographyPresentation.offersDiscography(.init(kind: .madeForYou, catalogID: "1", title: "A")))
    }

    // MARK: - The shared lookup

    @Test func theLookupIsMadeOnceAndAFailureIsTriedAgain() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = FakePlaybackCatalog()
        fixture.controller.playbackCatalog = catalog.catalog
        let album = PlaybackCollection(kind: .album, catalogID: "album-1", title: "Test Album")

        catalog.failure = URLError(.notConnectedToInternet)
        #expect(await fixture.controller.loadDiscography(for: album) == nil)
        catalog.failure = nil
        catalog.discography = discography
        #expect(await fixture.controller.loadDiscography(for: album) == discography)
        #expect(await fixture.controller.loadDiscography(for: album) == discography)

        #expect(catalog.discographyRequests == ["album:album-1", "album:album-1"])
        #expect(fixture.controller.discographies["album:album-1"] == discography)
    }

    // MARK: - A tile, from the app and CarPlay

    private func albumCatalog(for fixture: PlaybackFixture) throws -> FakePlaybackCatalog {
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        return catalog
    }

    @Test func anAlbumTilePlaysItAsADeepDiveFromTrackOne() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try albumCatalog(for: fixture)

        let started = await fixture.controller.playDiscographyItem(.album(id: "album-1", title: "Test Album"),
                                                                   context: fixture.context)

        #expect(started)
        #expect(catalog.idRequests.map(\.1) == ["album-1"])
        #expect(fixture.player.submittedTitles.last == ["Song 0", "Album Song 1", "Album Song 2"])
        #expect(fixture.player.submittedStartIndices.last == 0)
        #expect(try RecentCollectionRepository.recents(in: fixture.context).map(\.groupKey) == ["album:album-1"])
    }

    @Test func theTileOfWhatIsPlayingCarriesOn() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try albumCatalog(for: fixture)
        await fixture.controller.playDiscographyItem(.album(id: "album-1", title: "Test Album"), context: fixture.context)
        let submits = fixture.player.submitCount

        let playing = await fixture.controller.playDiscographyItem(.album(id: "album-1", title: "Test Album"),
                                                                   context: fixture.context)

        #expect(playing)
        #expect(fixture.player.submitCount == submits)
        #expect(catalog.idRequests.count == 1)
    }

    @Test func carPlaysTileRunsTheSharedActionAndGoesToNowPlaying() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        _ = try albumCatalog(for: fixture)

        let followUp = await CarPlayAction.playDiscographyItem(.album(id: "album-1", title: "Test Album"))
            .perform(controller: fixture.controller, context: fixture.context)

        #expect(followUp == .nowPlaying)
        #expect(fixture.controller.playingCollectionGroupKey == "album:album-1")
    }

    @Test func carPlaysTileReportsAFailedLookup() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try albumCatalog(for: fixture)
        catalog.failure = URLError(.notConnectedToInternet)

        let followUp = await CarPlayAction.playDiscographyItem(.album(id: "album-1", title: "Test Album"))
            .perform(controller: fixture.controller, context: fixture.context)

        #expect(followUp == .playbackFailed)
        #expect(fixture.player.submitCount == 0)
    }
}
