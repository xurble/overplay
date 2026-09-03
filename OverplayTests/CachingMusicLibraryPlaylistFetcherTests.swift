import Foundation
import MusicKit
import Testing
@testable import Overplay

@MainActor
@Suite("Caching music library playlist fetcher")
struct CachingMusicLibraryPlaylistFetcherTests {
    @MainActor
    private final class CountingFetcher: MusicLibraryPlaylistFetching {
        private(set) var fetchCount = 0
        private(set) var lookupCount = 0
        var playlists: [Playlist] = []

        func fetchAllPlaylists(pageLimit: Int) async throws -> [Playlist] {
            fetchCount += 1
            return playlists
        }

        func fetchPlaylist(id playlistID: String) async throws -> Playlist? {
            lookupCount += 1
            return playlists.first { $0.id.rawValue == playlistID }
        }
    }

    /// MusicKit's `Playlist` is `Codable`, so a library playlist can be
    /// built from the Apple Music API shape without touching the device.
    private static func makePlaylist(id: String, name: String) throws -> Playlist {
        let json = """
        {
          "id": "\(id)",
          "type": "library-playlists",
          "href": "/v1/me/library/playlists/\(id)",
          "attributes": { "name": "\(name)", "canEdit": true, "hasCatalog": false }
        }
        """
        return try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
    }

    @Test("fetches within the TTL reuse one underlying enumeration")
    func fetchesWithinTheTTLReuseOneUnderlyingEnumeration() async throws {
        let underlying = CountingFetcher()
        var currentDate = Date(timeIntervalSince1970: 0)
        let fetcher = CachingMusicLibraryPlaylistFetcher(
            underlying: underlying,
            timeToLive: 60,
            now: { currentDate }
        )

        _ = try await fetcher.fetchAllPlaylists(pageLimit: 100)
        currentDate = Date(timeIntervalSince1970: 59)
        _ = try await fetcher.fetchAllPlaylists(pageLimit: 100)

        #expect(underlying.fetchCount == 1)
    }

    @Test("an expired TTL refetches")
    func anExpiredTTLRefetches() async throws {
        let underlying = CountingFetcher()
        var currentDate = Date(timeIntervalSince1970: 0)
        let fetcher = CachingMusicLibraryPlaylistFetcher(
            underlying: underlying,
            timeToLive: 60,
            now: { currentDate }
        )

        _ = try await fetcher.fetchAllPlaylists(pageLimit: 100)
        currentDate = Date(timeIntervalSince1970: 60)
        _ = try await fetcher.fetchAllPlaylists(pageLimit: 100)

        #expect(underlying.fetchCount == 2)
    }

    @Test("invalidation forces a refetch")
    func invalidationForcesARefetch() async throws {
        let underlying = CountingFetcher()
        let fetcher = CachingMusicLibraryPlaylistFetcher(
            underlying: underlying,
            timeToLive: 60,
            now: { Date(timeIntervalSince1970: 0) }
        )

        _ = try await fetcher.fetchAllPlaylists(pageLimit: 100)
        fetcher.invalidate()
        _ = try await fetcher.fetchAllPlaylists(pageLimit: 100)

        #expect(underlying.fetchCount == 2)
    }

    @Test("a different page limit bypasses the cached list")
    func aDifferentPageLimitBypassesTheCachedList() async throws {
        let underlying = CountingFetcher()
        let fetcher = CachingMusicLibraryPlaylistFetcher(
            underlying: underlying,
            timeToLive: 60,
            now: { Date(timeIntervalSince1970: 0) }
        )

        _ = try await fetcher.fetchAllPlaylists(pageLimit: 100)
        _ = try await fetcher.fetchAllPlaylists(pageLimit: 50)

        #expect(underlying.fetchCount == 2)
    }

    // MARK: - Single-playlist lookup

    @Test("resolving one playlist uses a filtered lookup, not a full enumeration")
    func resolvingOnePlaylistUsesAFilteredLookupNotAFullEnumeration() async throws {
        let underlying = CountingFetcher()
        underlying.playlists = [try Self.makePlaylist(id: "p.1", name: "One")]
        let fetcher = CachingMusicLibraryPlaylistFetcher(
            underlying: underlying,
            timeToLive: 60,
            now: { Date(timeIntervalSince1970: 0) }
        )

        let playlist = try await fetcher.fetchPlaylist(id: "p.1")

        #expect(playlist?.id.rawValue == "p.1")
        #expect(underlying.lookupCount == 1)
        #expect(underlying.fetchCount == 0)
    }

    @Test("repeat lookups within the TTL reuse one underlying lookup")
    func repeatLookupsWithinTheTTLReuseOneUnderlyingLookup() async throws {
        let underlying = CountingFetcher()
        underlying.playlists = [try Self.makePlaylist(id: "p.1", name: "One")]
        var currentDate = Date(timeIntervalSince1970: 0)
        let fetcher = CachingMusicLibraryPlaylistFetcher(
            underlying: underlying,
            timeToLive: 60,
            now: { currentDate }
        )

        _ = try await fetcher.fetchPlaylist(id: "p.1")
        currentDate = Date(timeIntervalSince1970: 59)
        _ = try await fetcher.fetchPlaylist(id: "p.1")

        #expect(underlying.lookupCount == 1)

        currentDate = Date(timeIntervalSince1970: 61)
        _ = try await fetcher.fetchPlaylist(id: "p.1")

        #expect(underlying.lookupCount == 2)
    }

    @Test("a fresh enumeration answers a lookup without any extra request")
    func aFreshEnumerationAnswersALookupWithoutAnyExtraRequest() async throws {
        let underlying = CountingFetcher()
        underlying.playlists = [
            try Self.makePlaylist(id: "p.1", name: "One"),
            try Self.makePlaylist(id: "p.2", name: "Two")
        ]
        let fetcher = CachingMusicLibraryPlaylistFetcher(
            underlying: underlying,
            timeToLive: 60,
            now: { Date(timeIntervalSince1970: 0) }
        )

        _ = try await fetcher.fetchAllPlaylists(pageLimit: 100)
        let playlist = try await fetcher.fetchPlaylist(id: "p.2")

        #expect(playlist?.id.rawValue == "p.2")
        #expect(underlying.lookupCount == 0)
        #expect(underlying.fetchCount == 1)
    }

    @Test("an unknown id resolves to nil so callers can fall back to healing")
    func anUnknownIDResolvesToNilSoCallersCanFallBackToHealing() async throws {
        let underlying = CountingFetcher()
        let fetcher = CachingMusicLibraryPlaylistFetcher(
            underlying: underlying,
            timeToLive: 60,
            now: { Date(timeIntervalSince1970: 0) }
        )

        #expect(try await fetcher.fetchPlaylist(id: "p.missing") == nil)
        // A miss is not cached, so healing can retry after the library changes.
        #expect(underlying.lookupCount == 1)
    }

    @Test("invalidation clears the per-id cache too")
    func invalidationClearsThePerIDCacheToo() async throws {
        let underlying = CountingFetcher()
        underlying.playlists = [try Self.makePlaylist(id: "p.1", name: "One")]
        let fetcher = CachingMusicLibraryPlaylistFetcher(
            underlying: underlying,
            timeToLive: 60,
            now: { Date(timeIntervalSince1970: 0) }
        )

        _ = try await fetcher.fetchPlaylist(id: "p.1")
        fetcher.invalidate()
        _ = try await fetcher.fetchPlaylist(id: "p.1")

        #expect(underlying.lookupCount == 2)
    }
}
