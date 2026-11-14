import Foundation
@preconcurrency import MusicKit

/// The Apple Music catalogue search behind "Play … in Overplay" (`SIRI-003`).
/// Siri asks once per kind of result for one spoken phrase, so the last
/// search is kept for a minute and the three answers come from one request.
@MainActor
enum AppleMusicCatalogSearch {
    struct SongHit: Equatable, Sendable {
        var id: String
        var title: String
        var artistName: String
        var albumTitle: String?
        var isrc: String?
        var artworkURL: String?
    }

    struct AlbumHit: Equatable, Sendable {
        var id: String
        var title: String
        var artistName: String
        var upc: String?
        var artworkURL: String?
    }

    struct ArtistHit: Equatable, Sendable {
        var id: String
        var name: String
        var artworkURL: String?
    }

    enum Kind: Equatable, Sendable {
        case song, album, artist
    }

    struct Results: Equatable, Sendable {
        var songs: [SongHit] = []
        var albums: [AlbumHit] = []
        var artists: [ArtistHit] = []
        /// The kind of Apple Music's top result, when it is one of these.
        var topKind: Kind? = nil
    }

    /// Results per kind; Siri chooses among them.
    static let limit = 5
    static let cacheLifetime: TimeInterval = 60

    /// The live request; replaced in tests.
    static var request: (String) async throws -> Results = liveSearch
    static var now: () -> Date = { .now }

    private static var cached: (term: String, at: Date, results: Results)?
    /// Every hit returned recently, so Siri's follow-up lookups by ID need
    /// no request.
    private static var songsByID: [String: SongHit] = [:]
    private static var albumsByID: [String: AlbumHit] = [:]
    private static var artistsByID: [String: ArtistHit] = [:]

    static func search(_ term: String) async throws -> Results {
        let key = normalized(term)
        guard !key.isEmpty else { return Results() }
        if let cached, cached.term == key, now().timeIntervalSince(cached.at) < cacheLifetime {
            return cached.results
        }
        let results = focused(try await request(term), on: term)
        cached = (key, now(), results)
        remember(results)
        return results
    }

    static func songs(ids: [String]) async throws -> [SongHit] {
        let missing = ids.filter { songsByID[$0] == nil }
        if !missing.isEmpty { remember(Results(songs: try await liveSongs(ids: missing))) }
        return ids.compactMap { songsByID[$0] }
    }

    static func albums(ids: [String]) async throws -> [AlbumHit] {
        let missing = ids.filter { albumsByID[$0] == nil }
        if !missing.isEmpty { remember(Results(albums: try await liveAlbums(ids: missing))) }
        return ids.compactMap { albumsByID[$0] }
    }

    static func artists(ids: [String]) async throws -> [ArtistHit] {
        let missing = ids.filter { artistsByID[$0] == nil }
        if !missing.isEmpty { remember(Results(artists: try await liveArtists(ids: missing))) }
        return ids.compactMap { artistsByID[$0] }
    }

    /// Siri picks freely among what the queries return, and given an
    /// artist's songs it may play one ("Public Enemy" played "Fight the
    /// Power", 2026-11-14). So only one kind is offered: an exact artist
    /// name, then an exact album or song title (alone or "… by <artist>"),
    /// then the kind Apple Music ranks first. Without any of those, all
    /// kinds are offered.
    static func focused(_ results: Results, on term: String) -> Results {
        let key = normalized(term)
        let artists = results.artists.filter { normalized($0.name) == key }
        if !artists.isEmpty { return Results(artists: artists, topKind: .artist) }
        let albums = results.albums.filter { matches(key, title: $0.title, artist: $0.artistName) }
        if !albums.isEmpty { return Results(albums: albums, topKind: .album) }
        let songs = results.songs.filter { matches(key, title: $0.title, artist: $0.artistName) }
        if !songs.isEmpty { return Results(songs: songs, topKind: .song) }
        switch results.topKind {
        case .artist where !results.artists.isEmpty: return Results(artists: results.artists, topKind: .artist)
        case .album where !results.albums.isEmpty: return Results(albums: results.albums, topKind: .album)
        case .song where !results.songs.isEmpty: return Results(songs: results.songs, topKind: .song)
        default: return results
        }
    }

    private static func matches(_ key: String, title: String, artist: String) -> Bool {
        let title = normalized(title)
        return key == title || key == "\(title) by \(normalized(artist))"
    }

    /// Clears the cache; for tests.
    static func reset() {
        cached = nil
        songsByID = [:]
        albumsByID = [:]
        artistsByID = [:]
    }

    private static func remember(_ results: Results) {
        for song in results.songs { songsByID[song.id] = song }
        for album in results.albums { albumsByID[album.id] = album }
        for artist in results.artists { artistsByID[artist.id] = artist }
    }

    private static func normalized(_ term: String) -> String {
        term.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - MusicKit

    private static func liveSearch(_ term: String) async throws -> Results {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Artist.self])
        request.limit = limit
        request.includeTopResults = true
        let response = try await MusicKitActivityLog.shared.measure(.catalogSearch, detail: "voice search") {
            try await request.response()
        }
        let topKind: Kind? = response.topResults.lazy.compactMap { result -> Kind? in
            switch result {
            case .song: .song
            case .album: .album
            case .artist: .artist
            default: nil
            }
        }.first
        return Results(songs: response.songs.map(hit), albums: response.albums.map(hit),
                       artists: response.artists.map(hit), topKind: topKind)
    }

    private static func liveSongs(ids: [String]) async throws -> [SongHit] {
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        let response = try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: "voice songs by id") {
            try await request.response()
        }
        return response.items.map(hit)
    }

    private static func liveAlbums(ids: [String]) async throws -> [AlbumHit] {
        let request = MusicCatalogResourceRequest<Album>(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        let response = try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: "voice albums by id") {
            try await request.response()
        }
        return response.items.map(hit)
    }

    private static func liveArtists(ids: [String]) async throws -> [ArtistHit] {
        let request = MusicCatalogResourceRequest<Artist>(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        let response = try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: "voice artists by id") {
            try await request.response()
        }
        return response.items.map(hit)
    }

    private static func hit(_ song: Song) -> SongHit {
        SongHit(id: song.id.rawValue, title: song.title, artistName: song.artistName, albumTitle: song.albumTitle,
                isrc: song.isrc, artworkURL: artworkURL(song.artwork))
    }

    private static func hit(_ album: Album) -> AlbumHit {
        AlbumHit(id: album.id.rawValue, title: album.title, artistName: album.artistName, upc: album.upc,
                 artworkURL: artworkURL(album.artwork))
    }

    private static func hit(_ artist: Artist) -> ArtistHit {
        ArtistHit(id: artist.id.rawValue, name: artist.name, artworkURL: artworkURL(artist.artwork))
    }

    private static func artworkURL(_ artwork: Artwork?) -> String? {
        artwork?.url(width: 300, height: 300)?.absoluteString
    }
}
