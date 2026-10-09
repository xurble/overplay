import Foundation
@preconcurrency import MusicKit

/// An Apple Music collection Overplay plays instead of one of its own
/// playlists: the current song's album, or its artist (`PLAY-018`).
nonisolated struct PlaybackCollection: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case album
        case artistEssentials
        case artistTopSongs
    }

    /// What the user asked for. Which artist collection plays is the
    /// catalog's answer.
    enum Request: String, Sendable {
        case album
        case artist
    }

    var kind: Kind
    /// The catalog album or artist ID.
    var catalogID: String
    /// The album title or the artist name.
    var title: String

    /// The playback context shown instead of a playlist name.
    var contextTitle: String {
        switch kind {
        case .album: "Album · \(title)"
        case .artistEssentials: "\(title) Essentials"
        case .artistTopSongs: "\(title) · Top Songs"
        }
    }

    /// One Recents entry per album or artist, whichever artist collection
    /// played (`PLAY-019`).
    var groupKey: String {
        switch kind {
        case .album: "album:\(catalogID)"
        case .artistEssentials, .artistTopSongs: "artist:\(catalogID)"
        }
    }

    /// Reserved, so the intent's playlist reference never matches an
    /// Overplay playlist.
    var reservedPlaylistID: String { "overplay.collection.\(kind.rawValue).\(catalogID)" }
}

/// The songs a collection lookup found, in play order.
struct PlaybackCollectionContents {
    var collection: PlaybackCollection
    var tracks: [Track]
    /// The album cover or artist image, for Recents (`PLAY-019`).
    var artworkURLTemplate: String? = nil
}

enum PlaybackCollectionError: LocalizedError, Equatable {
    case songNotInCatalog
    case albumNotFound
    case artistNotFound
    case empty

    var errorDescription: String? {
        switch self {
        case .songNotInCatalog: "This song isn't in the Apple Music catalog."
        case .albumNotFound: "Apple Music has no album for this song."
        case .artistNotFound: "Apple Music has no artist for this song."
        case .empty: "Apple Music returned no songs to play."
        }
    }
}

/// Pure choices behind Play Artist, testable without MusicKit.
enum PlaybackCollectionPolicy {
    /// MusicKit has no Essentials field: it is the Apple Music playlist named
    /// "<Artist> Essentials". Needs device evidence in other storefront
    /// languages; a miss falls back to Top Songs.
    static func isEssentials(playlistName: String, curatorName: String?, isEditorial: Bool?, artistName: String) -> Bool {
        guard normalized(playlistName) == normalized("\(artistName) Essentials") else { return false }
        if isEditorial == true { return true }
        guard let curatorName else { return isEditorial == nil }
        return normalized(curatorName) == "apple music"
    }

    /// Top Songs in Apple's order with versions of one song collapsed to the
    /// highest-ranked: remasters, deluxe, single and compilation copies, live
    /// recordings and remixes. Only orders this list; it never establishes
    /// Overplay track identity.
    static func collapsingVersions<Song>(
        _ songs: [Song], title: (Song) -> String, isrc: (Song) -> String?
    ) -> [Song] {
        var seenTitles: Set<String> = []
        var seenISRCs: Set<String> = []
        return songs.filter { song in
            let key = songKey(title(song))
            let code = isrc(song).map(normalized)
            guard !seenTitles.contains(key), !(code.map(seenISRCs.contains) ?? false) else { return false }
            seenTitles.insert(key)
            if let code { seenISRCs.insert(code) }
            return true
        }
    }

    /// The title without version decorations: anything in brackets, and
    /// anything after " - ", as in "Song - Remastered 2011".
    static func songKey(_ title: String) -> String {
        var base = ""
        var depth = 0
        for character in title {
            if character == "(" || character == "[" { depth += 1; continue }
            if character == ")" || character == "]" { depth = max(depth - 1, 0); continue }
            if depth == 0 { base.append(character) }
        }
        if let dash = base.range(of: " - ") { base = String(base[..<dash.lowerBound]) }
        let key = normalized(base)
        return key.isEmpty ? normalized(title) : key
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The catalog boundary behind Play Album and Play Artist. Injectable so the
/// shared action is tested without MusicKit.
@MainActor
struct PlaybackCatalog {
    /// The collection for a catalog song ID.
    var collection: (PlaybackCollection.Request, String) async throws -> PlaybackCollectionContents
    /// Catalog songs by ID, for resuming or recovering a collection intent.
    var songs: ([String]) async throws -> [String: Track]

    static let live = PlaybackCatalog(
        collection: { request, songID in try await MusicKitPlaybackCatalog.collection(request, songID: songID) },
        songs: { try await MusicKitPlaybackCatalog.songs(ids: $0) }
    )
}

@MainActor
private enum MusicKitPlaybackCatalog {
    /// Bounds paging, so one lookup is a handful of requests (`LOAD-001`).
    static let maximumTracks = 200
    static let topSongsTarget = 40

    static func collection(_ request: PlaybackCollection.Request, songID: String) async throws -> PlaybackCollectionContents {
        let song = try await catalogSong(id: songID, properties: request == .album ? [.albums] : [.artists])
        switch request {
        case .album:
            guard let album = song.albums?.first else { throw PlaybackCollectionError.albumNotFound }
            let detailed = try await measure("album tracks") { try await album.with([.tracks]) }
            let tracks = try await allTracks(detailed.tracks)
            return PlaybackCollectionContents(
                collection: PlaybackCollection(kind: .album, catalogID: album.id.rawValue, title: album.title),
                tracks: tracks,
                artworkURLTemplate: artworkURL(album.artwork)
            )
        case .artist:
            guard let artist = song.artists?.first else { throw PlaybackCollectionError.artistNotFound }
            let detailed = try await measure("artist playlists and top songs") {
                try await artist.with([.featuredPlaylists, .playlists, .topSongs])
            }
            let playlists = Array(detailed.featuredPlaylists ?? []) + Array(detailed.playlists ?? [])
            if let essentials = playlists.first(where: {
                PlaybackCollectionPolicy.isEssentials(
                    playlistName: $0.name, curatorName: $0.curatorName,
                    isEditorial: $0.kind.map { $0 == .editorial }, artistName: artist.name
                )
            }) {
                let withTracks = try await measure("essentials tracks") { try await essentials.with([.tracks]) }
                let tracks = try await allTracks(withTracks.tracks)
                if !tracks.isEmpty {
                    return PlaybackCollectionContents(
                        collection: PlaybackCollection(kind: .artistEssentials, catalogID: artist.id.rawValue, title: artist.name),
                        tracks: tracks,
                        artworkURLTemplate: artworkURL(artist.artwork)
                    )
                }
            }
            var songs = Array(detailed.topSongs ?? [])
            var batch = detailed.topSongs
            while songs.count < topSongsTarget, batch?.hasNextBatch == true {
                batch = try await measure("top songs page") { try await batch?.nextBatch() }
                songs += Array(batch ?? [])
            }
            let collapsed = PlaybackCollectionPolicy.collapsingVersions(songs, title: \.title, isrc: \.isrc)
            return PlaybackCollectionContents(
                collection: PlaybackCollection(kind: .artistTopSongs, catalogID: artist.id.rawValue, title: artist.name),
                tracks: collapsed.map(Track.song),
                artworkURLTemplate: artworkURL(artist.artwork)
            )
        }
    }

    static func songs(ids: [String]) async throws -> [String: Track] {
        var result: [String: Track] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: chunk.map { MusicItemID($0) })
            let songs = try await measure("songs by id") { try await request.response().items }
            for song in songs { result[song.id.rawValue] = .song(song) }
        }
        return result
    }

    private static func artworkURL(_ artwork: Artwork?) -> String? {
        artwork?.url(width: 512, height: 512)?.absoluteString
    }

    private static func catalogSong(id: String, properties: [PartialMusicAsyncProperty<Song>]) async throws -> Song {
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        request.properties = properties
        request.limit = 1
        guard let song = try await measure("song for collection", { try await request.response().items }).first else {
            throw PlaybackCollectionError.songNotInCatalog
        }
        return song
    }

    private static func allTracks(_ first: MusicItemCollection<Track>?) async throws -> [Track] {
        var tracks = Array(first ?? [])
        var batch = first
        while tracks.count < maximumTracks, batch?.hasNextBatch == true {
            batch = try await measure("collection tracks page") { try await batch?.nextBatch() }
            tracks += Array(batch ?? [])
        }
        return Array(tracks.prefix(maximumTracks))
    }

    private static func measure<T>(_ detail: String, _ operation: () async throws -> T) async throws -> T {
        try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: detail) {
            try await operation()
        }
    }
}
