import Foundation

struct TrackSnapshot: Identifiable, Hashable, Sendable {
    var id: String
    var catalogID: String?
    var libraryID: String?
    var playlistEntryID: String?
    var playlistID: String?
    var title: String
    var artistName: String
    var albumTitle: String?
    var artworkURLTemplate: String?
    var durationSeconds: Double?
    var musicKitPlaybackData: Data?

    init(
        id: String,
        catalogID: String?,
        libraryID: String?,
        playlistEntryID: String?,
        playlistID: String?,
        title: String,
        artistName: String,
        albumTitle: String?,
        artworkURLTemplate: String?,
        durationSeconds: Double?,
        musicKitPlaybackData: Data? = nil
    ) {
        self.id = id
        self.catalogID = catalogID
        self.libraryID = libraryID
        self.playlistEntryID = playlistEntryID
        self.playlistID = playlistID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURLTemplate = artworkURLTemplate
        self.durationSeconds = durationSeconds
        self.musicKitPlaybackData = musicKitPlaybackData
    }
}

struct AppleMusicPlaylist: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var trackCount: Int?

    var isPreferredOverplayPlaylist: Bool {
        name.localizedCaseInsensitiveCompare("Overplay") == .orderedSame
    }
}

struct RemotePlaylistLink: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var trackCount: Int?
    var source: PlaylistSource

    init(id: String, name: String, trackCount: Int? = nil, source: PlaylistSource) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.source = source
    }

    init(_ playlist: AppleMusicPlaylist) {
        self.init(id: playlist.id, name: playlist.name, trackCount: playlist.trackCount, source: .appleMusic)
    }
}

struct SearchSongResult: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var artistName: String
    var albumTitle: String?
    var artworkURL: String?
}
