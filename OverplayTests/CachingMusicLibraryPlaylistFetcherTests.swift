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

        func fetchAllPlaylists(pageLimit: Int) async throws -> [Playlist] {
            fetchCount += 1
            return []
        }
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
}
