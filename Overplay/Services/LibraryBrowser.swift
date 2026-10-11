import Foundation
@preconcurrency import MusicKit

/// The user's Apple Music library by category, as the Music app's Library
/// shows it, read from the web library API (as playlist sync reads iCloud's
/// copy). Its songs carry web library IDs and the catalog IDs Overplay's
/// tracks hold, on every device; a Mac's on-device library reports only
/// local persistent IDs, which nothing can match. Songs are keyed by catalog
/// ID, else library ID, and queued from the decoded tracks.
@MainActor
enum LibraryBrowser {
    enum Category: String, CaseIterable, Identifiable {
        case playlists = "Playlists"
        case albums = "Albums"
        case artists = "Artists"
        case songs = "Songs"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .playlists: "music.note.list"
            case .albums: "square.stack"
            case .artists: "music.mic"
            case .songs: "music.note"
            }
        }
    }

    /// A browsable collection: one of the user's playlists, albums or artists.
    struct Item: Identifiable {
        enum Kind: String {
            case playlist = "Playlist"
            case album = "Album"
            case artist = "Artist"
        }

        var kind: Kind
        /// The web library ID.
        var libraryID: String
        var title: String
        var subtitle: String?
        var artwork: Artwork?

        var id: String { "\(kind.rawValue):\(libraryID)" }
        var kindName: String { kind.rawValue }

        var collection: PlaybackCollection {
            let collectionKind: PlaybackCollection.Kind = switch kind {
            case .playlist: .libraryPlaylist
            case .album: .libraryAlbum
            case .artist: .libraryArtist
            }
            return PlaybackCollection(kind: collectionKind, catalogID: libraryID, title: title)
        }

        fileprivate var tracksPath: String {
            switch kind {
            case .playlist: "/v1/me/library/playlists/\(libraryID)/tracks"
            case .album: "/v1/me/library/albums/\(libraryID)/tracks"
            case .artist: "/v1/me/library/artists/\(libraryID)/albums?include=tracks"
            }
        }
    }

    static let allSongs = PlaybackCollection(kind: .librarySongs, catalogID: "songs", title: "Songs")

    /// A song to show and save, with the native track that plays it.
    struct Entry {
        var song: PlaybackCollectionSong
        var track: Track
    }

    static func items(_ category: Category) async throws -> [Item] {
        let items: [Item]
        switch category {
        case .playlists:
            items = try await fetchAll(Playlist.self, "/v1/me/library/playlists", .libraryPlaylistEnumeration).map {
                Item(kind: .playlist, libraryID: $0.id.rawValue, title: $0.name, subtitle: $0.curatorName, artwork: $0.artwork)
            }
        case .albums:
            items = try await fetchAll(Album.self, "/v1/me/library/albums", .libraryTrackQuery).map {
                Item(kind: .album, libraryID: $0.id.rawValue, title: $0.title, subtitle: $0.artistName, artwork: $0.artwork)
            }
        case .artists:
            // Library artists carry no image; their catalog artist does.
            var catalogArtwork: [String: Artwork] = [:]
            let artists = try await fetchAll(Artist.self, "/v1/me/library/artists?include=catalog", .libraryTrackQuery) { data in
                for artist in (try? JSONDecoder().decode(ArtistCatalogPage.self, from: data))?.data ?? [] {
                    if let artwork = artist.relationships?.catalog?.data.first?.attributes?.artwork {
                        catalogArtwork[artist.id] = artwork
                    }
                }
            }
            items = artists.map {
                Item(kind: .artist, libraryID: $0.id.rawValue, title: $0.name, subtitle: nil,
                     artwork: $0.artwork ?? catalogArtwork[$0.id.rawValue])
            }
        case .songs:
            items = []
        }
        return items
            .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Every library song, by title.
    static func allLibrarySongs() async throws -> [Entry] {
        let songs = try await fetchAll(Song.self, "/v1/me/library/songs", .libraryTrackQuery)
        return unique(songs.map(Track.song).compactMap(entry))
            .sorted { $0.song.title.localizedStandardCompare($1.song.title) == .orderedAscending }
    }

    /// A playlist's, album's or artist's songs in play order.
    static func songs(in item: Item) async throws -> [Entry] {
        switch item.kind {
        case .playlist, .album:
            return unique(try await fetchAll(Track.self, item.tracksPath, .playlistTrackFetch).compactMap(entry))
        case .artist:
            let albums = try await fetchAll(Album.self, item.tracksPath, .libraryTrackQuery)
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let tracks = albums.flatMap { album in
                (album.tracks.map(Array.init) ?? []).sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
            }
            return unique(tracks.compactMap(entry))
        }
    }

    private static func entry(_ track: Track) -> Entry? {
        guard VideoTrackPolicy.isSong(track) else { return nil }
        let identity = MusicTrackIdentity.ids(for: track)
        return Entry(song: PlaybackCollectionSong(
            catalogID: identity.catalogID ?? track.id.rawValue, title: track.title, artistName: track.artistName,
            albumTitle: track.albumTitle, artworkURLTemplate: track.artwork?.url(width: 512, height: 512)?.absoluteString,
            durationSeconds: track.duration
        ), track: track)
    }

    /// A song listed twice plays once.
    private static func unique(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.song.catalogID).inserted }
    }

    /// Every page of a web library resource list. An empty list answers 404.
    private static func fetchAll<Item: MusicItem & Decodable>(
        _ type: Item.Type, _ path: String, _ operation: MusicKitActivityOperation, onPage: (Data) -> Void = { _ in }
    ) async throws -> [Item] {
        let base = URL(string: "https://api.music.apple.com")!
        let separator = path.contains("?") ? "&" : "?"
        var next: String? = path + separator + "limit=100"
        var items: [Item] = []
        var visited = Set<String>()
        while let path = next, visited.insert(path).inserted, let url = URL(string: path, relativeTo: base)?.absoluteURL {
            let data: Data
            do {
                data = try await MusicKitActivityLog.shared.measure(operation, detail: "library browser \(type)") {
                    try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
                }
            } catch let error as MusicDataRequest.Error where error.status == 404 && items.isEmpty {
                return []
            }
            onPage(data)
            items += try JSONDecoder().decode(MusicItemCollection<Item>.self, from: data)
            next = try JSONDecoder().decode(NextPage.self, from: data).next
            try Task.checkCancellation()
        }
        return items
    }
}

private struct NextPage: Decodable { var next: String? }

/// The catalog artist's artwork from a library artists page with
/// `include=catalog`.
private struct ArtistCatalogPage: Decodable {
    struct Resource: Decodable {
        struct Relationships: Decodable {
            struct Catalog: Decodable {
                struct CatalogArtist: Decodable {
                    struct Attributes: Decodable { var artwork: Artwork? }
                    var attributes: Attributes?
                }
                var data: [CatalogArtist]
            }
            var catalog: Catalog?
        }
        var id: String
        var relationships: Relationships?
    }
    var data: [Resource]
}
