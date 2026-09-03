import Foundation
@preconcurrency import MusicKit

/// Memoizes library playlist lookups for a short window.
///
/// Two levels, because the two access patterns cost very different amounts:
///
/// - `fetchPlaylist(id:)` resolves one known playlist. It is answered from a
///   fresh full list when one is already cached, then from a per-ID cache,
///   and only then with a single filtered request.
/// - `fetchAllPlaylists` pages the user's whole playlist library. It is
///   needed for the playlist picker and for name-based ID healing, so it
///   stays available but is shared across a whole sync cycle rather than
///   repeated per playlist.
///
/// The TTL is short enough that ID healing never sees a meaningfully stale
/// library.
@MainActor
final class CachingMusicLibraryPlaylistFetcher: MusicLibraryPlaylistFetching {
    static let shared = CachingMusicLibraryPlaylistFetcher()

    private struct CachedPlaylists {
        var playlists: [Playlist]
        var pageLimit: Int
        var fetchedAt: Date
    }

    private struct CachedPlaylist {
        var playlist: Playlist
        var fetchedAt: Date
    }

    private let underlying: any MusicLibraryPlaylistFetching
    private let timeToLive: TimeInterval
    private let now: () -> Date
    private var cached: CachedPlaylists?
    private var cachedByID: [String: CachedPlaylist] = [:]
    private var inFlightFetch: Task<[Playlist], Error>?
    private var inFlightLookups: [String: Task<Playlist?, Error>] = [:]

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
        store(playlists, pageLimit: pageLimit)
        return playlists
    }

    func fetchPlaylist(id playlistID: String) async throws -> Playlist? {
        guard !playlistID.isEmpty else { return nil }

        // A fresh full enumeration already answers this for free.
        if let cached, now().timeIntervalSince(cached.fetchedAt) < timeToLive {
            return cached.playlists.first { $0.id.rawValue == playlistID }
        }

        if let cachedByID = cachedByID[playlistID],
           now().timeIntervalSince(cachedByID.fetchedAt) < timeToLive {
            return cachedByID.playlist
        }

        if let inFlightLookup = inFlightLookups[playlistID] {
            return try await inFlightLookup.value
        }

        let lookup = Task { [underlying] in
            try await underlying.fetchPlaylist(id: playlistID)
        }
        inFlightLookups[playlistID] = lookup
        defer { inFlightLookups[playlistID] = nil }

        let playlist = try await lookup.value
        if let playlist {
            cachedByID[playlist.id.rawValue] = CachedPlaylist(playlist: playlist, fetchedAt: now())
        }
        return playlist
    }

    /// Drops the memoized lookups so the next fetch sees library mutations
    /// Overplay itself just made (for example a newly created playlist).
    func invalidate() {
        cached = nil
        cachedByID.removeAll()
    }

    private func store(_ playlists: [Playlist], pageLimit: Int) {
        let fetchedAt = now()
        cached = CachedPlaylists(playlists: playlists, pageLimit: pageLimit, fetchedAt: fetchedAt)
        for playlist in playlists {
            cachedByID[playlist.id.rawValue] = CachedPlaylist(playlist: playlist, fetchedAt: fetchedAt)
        }
    }
}
