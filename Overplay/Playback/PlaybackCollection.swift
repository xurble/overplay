import Foundation
@preconcurrency import MusicKit

/// An Apple Music collection Overplay plays instead of one of its own
/// playlists: the current song's album, or its artist (`PLAY-018`), or a
/// playlist, album, artist or the songs in the user's library.
nonisolated struct PlaybackCollection: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case album
        case artistEssentials
        case artistTopSongs
        /// Browsed from the library: played like a deep dive, never recorded
        /// in Recents.
        case libraryPlaylist
        case libraryAlbum
        case libraryArtist
        case librarySongs
        /// One song played from search, outside any playlist. Never
        /// recorded in Recents.
        case searchSong
        /// One of Apple Music's Made For You playlists (`MFY-001`), played
        /// like a deep dive, never recorded in Recents.
        case madeForYou
    }

    /// What the user asked for. Which artist collection plays is the
    /// catalog's answer.
    enum Request: String, Sendable {
        case album
        case artist
    }

    var kind: Kind
    /// The catalog album or artist ID; for a library collection, its library
    /// ID ("songs" for all songs).
    var catalogID: String
    /// The album title or the artist name.
    var title: String

    /// The playback context shown instead of a playlist name.
    var contextTitle: String {
        switch kind {
        case .album: "Album · \(title)"
        case .artistEssentials: "\(title) Essentials"
        case .artistTopSongs: "\(title) · Top Songs"
        case .libraryPlaylist: "Playlist · \(title)"
        case .libraryAlbum: "Album · \(title)"
        case .libraryArtist: title
        case .librarySongs: "Songs"
        case .searchSong: "Search"
        case .madeForYou: title
        }
    }

    /// One Recents entry per album or artist, whichever artist collection
    /// played (`PLAY-019`).
    var groupKey: String {
        switch kind {
        case .album: "album:\(catalogID)"
        case .artistEssentials, .artistTopSongs: "artist:\(catalogID)"
        case .libraryPlaylist, .libraryAlbum, .libraryArtist, .librarySongs, .searchSong, .madeForYou:
            "\(kind.rawValue):\(catalogID)"
        }
    }

    /// Reserved, so the intent's playlist reference never matches an
    /// Overplay playlist.
    var reservedPlaylistID: String { "overplay.collection.\(kind.rawValue).\(catalogID)" }
}

/// Something an Apple Music search found, to play (`SIRI-003`).
nonisolated enum CatalogPlayItem: Equatable, Sendable {
    /// Played on its own, as search's Play Now.
    case song(PlaybackCollectionSong)
    case album(id: String, title: String)
    case artist(id: String, name: String)

    /// The Recents entry it plays as; nil for a song, which is never one.
    var groupKey: String? {
        switch self {
        case .song: nil
        case .album(let id, _): "album:\(id)"
        case .artist(let id, _): "artist:\(id)"
        }
    }
}

/// An artist and their full albums, oldest first: what an album or artist
/// deep dive offers next (`PLAY-021`).
nonisolated struct ArtistDiscography: Equatable, Sendable {
    struct Album: Equatable, Sendable {
        var id: String
        var title: String
        var artworkURL: String?
        var releaseDate: Date?
        /// A clean version, left out when the explicit one is listed.
        var isClean = false
    }

    var artistID: String
    var artistName: String
    var artistArtworkURL: String?
    var albums: [Album]
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
    /// Full albums oldest first, those without a release date last, each
    /// title once: a clean copy is dropped when another version is listed.
    static func oldestFirst(_ albums: [ArtistDiscography.Album]) -> [ArtistDiscography.Album] {
        var kept: [String: Int] = [:]
        var unique: [ArtistDiscography.Album] = []
        for album in albums {
            let key = normalized(album.title)
            if let index = kept[key] {
                if unique[index].isClean, !album.isClean { unique[index] = album }
                continue
            }
            kept[key] = unique.count
            unique.append(album)
        }
        return unique.enumerated().sorted { lhs, rhs in
            switch (lhs.element.releaseDate, rhs.element.releaseDate) {
            case let (left?, right?) where left != right: left < right
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

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
    /// The collection for a catalog album or artist ID, found by search
    /// rather than from a song (`SIRI-003`).
    var collectionByID: (PlaybackCollection.Request, String) async throws -> PlaybackCollectionContents = { request, _ in
        throw request == .album ? PlaybackCollectionError.albumNotFound : PlaybackCollectionError.artistNotFound
    }

    /// The artist and full albums of an album or artist deep dive
    /// (`PLAY-021`).
    var discography: (PlaybackCollection) async throws -> ArtistDiscography = { _ in
        throw PlaybackCollectionError.artistNotFound
    }

    static let live = PlaybackCatalog(
        collection: { request, songID in try await MusicKitPlaybackCatalog.collection(request, songID: songID) },
        songs: { try await MusicKitPlaybackCatalog.songs(ids: $0) },
        collectionByID: { request, id in try await MusicKitPlaybackCatalog.collection(request, id: id) },
        discography: { try await MusicKitPlaybackCatalog.discography(of: $0) }
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
            return try await contents(of: album)
        case .artist:
            guard let artist = song.artists?.first else { throw PlaybackCollectionError.artistNotFound }
            return try await contents(of: artist)
        }
    }

    /// An album or artist by its catalog ID.
    static func collection(_ request: PlaybackCollection.Request, id: String) async throws -> PlaybackCollectionContents {
        let musicID = MusicItemID(id)
        switch request {
        case .album:
            let response = try await measure("album by id") {
                try await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: musicID).response()
            }
            guard let album = response.items.first else { throw PlaybackCollectionError.albumNotFound }
            return try await contents(of: album)
        case .artist:
            let response = try await measure("artist by id") {
                try await MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: musicID).response()
            }
            guard let artist = response.items.first else { throw PlaybackCollectionError.artistNotFound }
            return try await contents(of: artist)
        }
    }

    private static func contents(of album: Album) async throws -> PlaybackCollectionContents {
        let detailed = try await measure("album tracks") { try await album.with([.tracks]) }
        let tracks = try await allTracks(detailed.tracks)
        return PlaybackCollectionContents(
            collection: PlaybackCollection(kind: .album, catalogID: album.id.rawValue, title: album.title),
            tracks: tracks,
            artworkURLTemplate: artworkURL(album.artwork)
        )
    }

    private static func contents(of artist: Artist) async throws -> PlaybackCollectionContents {
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

    /// Bounds album paging for a prolific artist (`LOAD-001`).
    static let maximumAlbums = 100

    /// An album's first artist, or the artist itself, with their full albums.
    static func discography(of collection: PlaybackCollection) async throws -> ArtistDiscography {
        let artist: Artist
        switch collection.kind {
        case .album:
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(collection.catalogID))
            request.properties = [.artists]
            let response = try await measure("album artist") { try await request.response() }
            guard let found = response.items.first?.artists?.first else { throw PlaybackCollectionError.artistNotFound }
            artist = found
        case .artistEssentials, .artistTopSongs:
            let request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: MusicItemID(collection.catalogID))
            let response = try await measure("artist by id") { try await request.response() }
            guard let found = response.items.first else { throw PlaybackCollectionError.artistNotFound }
            artist = found
        default:
            throw PlaybackCollectionError.artistNotFound
        }
        let detailed = try await measure("artist full albums") { try await artist.with([.fullAlbums]) }
        var albums = Array(detailed.fullAlbums ?? [])
        var batch = detailed.fullAlbums
        while albums.count < maximumAlbums, batch?.hasNextBatch == true {
            batch = try await measure("full albums page") { try await batch?.nextBatch() }
            albums += Array(batch ?? [])
        }
        return ArtistDiscography(
            artistID: artist.id.rawValue,
            artistName: artist.name,
            artistArtworkURL: artworkURL(detailed.artwork ?? artist.artwork),
            albums: PlaybackCollectionPolicy.oldestFirst(albums.prefix(maximumAlbums).map { album in
                ArtistDiscography.Album(id: album.id.rawValue, title: album.title, artworkURL: artworkURL(album.artwork),
                                        releaseDate: album.releaseDate, isClean: album.contentRating == .clean)
            })
        )
    }

    static func songs(ids: [String]) async throws -> [String: Track] {
        try await AppleMusicSongLookup.playableCatalogSongs(ids) { batch in
            try await AppleMusicSongLookup.catalogSongs(batch, detail: "songs by id")
        }.mapValues(Track.song)
    }

    private static func artworkURL(_ artwork: Artwork?) -> String? {
        artwork?.url(width: 512, height: 512)?.absoluteString
    }

    private static func catalogSong(id: String, properties: [PartialMusicAsyncProperty<Song>]) async throws -> Song {
        guard let song = try await AppleMusicSongLookup.catalogSong(id: id, detail: "song for collection", properties: properties, limit: 1) else {
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
