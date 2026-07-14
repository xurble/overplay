import Foundation
@preconcurrency import MusicKit

/// Memoizes the library playlist enumeration for a short window.
///
/// Every playlist sync resolves its target through the full library playlist
/// list. During a catch-up cycle each stale playlist would otherwise pay for
/// its own complete enumeration; sharing this fetcher means one enumeration
/// serves the whole cycle. The TTL is short enough that ID healing never
/// sees a meaningfully stale library.
@MainActor
final class CachingMusicLibraryPlaylistFetcher: MusicLibraryPlaylistFetching {
    static let shared = CachingMusicLibraryPlaylistFetcher()

    private struct CachedPlaylists {
        var playlists: [Playlist]
        var pageLimit: Int
        var fetchedAt: Date
    }

    private let underlying: any MusicLibraryPlaylistFetching
    private let timeToLive: TimeInterval
    private let now: () -> Date
    private var cached: CachedPlaylists?
    private var inFlightFetch: Task<[Playlist], Error>?

    init(
        underlying: any MusicLibraryPlaylistFetching = MusicKitLibraryPlaylistFetcher(),
        timeToLive: TimeInterval = 60,
        now: @escaping () -> Date = { .now }
    ) {
        self.underlying = underlying
        self.timeToLive = timeToLive
        self.now = now
    }

    func fetchAllPlaylists(pageLimit: Int) async throws -> [Playlist] {
        if let cached,
           cached.pageLimit == pageLimit,
           now().timeIntervalSince(cached.fetchedAt) < timeToLive {
            return cached.playlists
        }

        if let inFlightFetch {
            return try await inFlightFetch.value
        }

        let fetch = Task { [underlying] in
            try await underlying.fetchAllPlaylists(pageLimit: pageLimit)
        }
        inFlightFetch = fetch
        defer { inFlightFetch = nil }

        let playlists = try await fetch.value
        cached = CachedPlaylists(playlists: playlists, pageLimit: pageLimit, fetchedAt: now())
        return playlists
    }

    /// Drops the memoized list so the next fetch sees library mutations
    /// Overplay itself just made (for example a newly created playlist).
    func invalidate() {
        cached = nil
    }
}
