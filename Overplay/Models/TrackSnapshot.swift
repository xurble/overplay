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
}

struct AppleMusicPlaylist: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var trackCount: Int?

    var isPreferredOverplayPlaylist: Bool {
        name.localizedCaseInsensitiveCompare("Overplay") == .orderedSame
    }
}

struct SearchSongResult: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var artistName: String
    var albumTitle: String?
    var artworkURL: String?
}
