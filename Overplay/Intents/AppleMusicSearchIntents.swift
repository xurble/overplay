import AppIntents
import Foundation

// "Play <anything> in Overplay" (`SIRI-003`): Apple Music search by voice
// through iOS 27's audio schema. Siri passes what was said to each entity's
// string query, picks a song, album or artist, and runs the play intent,
// which hands off to the shared `playCatalogItem`. Nothing here exists
// before iOS 27; every other voice action is unchanged.

@available(iOS 27.0, *)
@AppEntity(schema: .audio.song)
struct AppleMusicSongEntity {
    static let defaultQuery = AppleMusicSongQuery()
    var id: String
    var title: String
    var artistName: String
    var artists: [AppleMusicArtistEntity]
    var albumTitle: String?
    var album: AppleMusicAlbumEntity?
    var composerName: String?
    var composers: [AppleMusicArtistEntity]
    var internationalStandardRecordingCode: String?
    var artworkURL: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: artworkURL.flatMap(URL.init).map { .init(url: $0) })
    }

    init(_ hit: AppleMusicCatalogSearch.SongHit) {
        id = hit.id
        title = hit.title
        artistName = hit.artistName
        artists = []
        albumTitle = hit.albumTitle
        album = nil
        composerName = nil
        composers = []
        internationalStandardRecordingCode = hit.isrc
        artworkURL = hit.artworkURL
    }
}

@available(iOS 27.0, *)
struct AppleMusicSongQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AppleMusicSongEntity] {
        try await AppleMusicCatalogSearch.songs(ids: identifiers).map(AppleMusicSongEntity.init)
    }

    func entities(matching string: String) async throws -> [AppleMusicSongEntity] {
        try await AppleMusicCatalogSearch.search(string).songs.map(AppleMusicSongEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.album)
struct AppleMusicAlbumEntity {
    static let defaultQuery = AppleMusicAlbumQuery()
    var id: String
    var title: String
    var artistName: String
    var artists: [AppleMusicArtistEntity]
    var universalProductCode: String?
    var artworkURL: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: artworkURL.flatMap(URL.init).map { .init(url: $0) })
    }

    init(_ hit: AppleMusicCatalogSearch.AlbumHit) {
        id = hit.id
        title = hit.title
        artistName = hit.artistName
        artists = []
        universalProductCode = hit.upc
        artworkURL = hit.artworkURL
    }
}

@available(iOS 27.0, *)
struct AppleMusicAlbumQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AppleMusicAlbumEntity] {
        try await AppleMusicCatalogSearch.albums(ids: identifiers).map(AppleMusicAlbumEntity.init)
    }

    func entities(matching string: String) async throws -> [AppleMusicAlbumEntity] {
        try await AppleMusicCatalogSearch.search(string).albums.map(AppleMusicAlbumEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct AppleMusicArtistEntity {
    static let defaultQuery = AppleMusicArtistQuery()
    var id: String
    var name: String
    var artworkURL: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: artworkURL.flatMap(URL.init).map { .init(url: $0) })
    }

    init(_ hit: AppleMusicCatalogSearch.ArtistHit) {
        id = hit.id
        name = hit.name
        artworkURL = hit.artworkURL
    }
}

@available(iOS 27.0, *)
struct AppleMusicArtistQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AppleMusicArtistEntity] {
        try await AppleMusicCatalogSearch.artists(ids: identifiers).map(AppleMusicArtistEntity.init)
    }

    func entities(matching string: String) async throws -> [AppleMusicArtistEntity] {
        try await AppleMusicCatalogSearch.search(string).artists.map(AppleMusicArtistEntity.init)
    }
}

/// The schema's warm-up hand-off. Overplay does no warm-up; the play intent
/// ignores it.
@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct AppleMusicQueueWarmup: TransientAppEntity {
    init() {}
    var displayRepresentation: DisplayRepresentation { "Ready" }
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum AppleMusicPlaybackOption: String {
    case shuffle
    case `repeat`
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.shuffle: "Shuffle", .repeat: "Repeat"]
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum AppleMusicQueuePosition: String {
    case next
    case tail
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.next: "Play Next", .tail: "Play Last"]
}

@available(iOS 27.0, *)
@UnionValue
enum AppleMusicItem {
    case song(AppleMusicSongEntity)
    case album(AppleMusicAlbumEntity)
    case artist(AppleMusicArtistEntity)

    var playItem: CatalogPlayItem {
        switch self {
        case .song(let song):
            .song(PlaybackCollectionSong(catalogID: song.id, title: song.title, artistName: song.artistName,
                                         albumTitle: song.albumTitle, artworkURLTemplate: song.artworkURL))
        case .album(let album): .album(id: album.id, title: album.title)
        case .artist(let artist): .artist(id: artist.id, name: artist.name)
        }
    }
}

/// Plays what Siri found: a song on its own, an album in order, or an
/// artist's Essentials or top songs, shuffled when asked. Adding to the queue
/// (Play Next, Play Last) is refused: Overplay only starts things.
@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAppleMusicIntent {
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    var audioEntity: AppleMusicItem
    var playbackAttributes: Set<AppleMusicPlaybackOption>
    var queueLocation: AppleMusicQueuePosition?
    var warmupAudioQueueResult: AppleMusicQueueWarmup?

    func perform() async throws -> some IntentResult {
        if queueLocation != nil {
            throw VoiceActionError(message: "Overplay can only play it now, not add it to the queue.")
        }
        try await VoiceIntentRunner.playCatalogItem(audioEntity.playItem,
                                                    shuffle: playbackAttributes.contains(.shuffle))
        return .result()
    }
}
