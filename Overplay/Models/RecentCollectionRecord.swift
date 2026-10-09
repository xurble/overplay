import Foundation
import SwiftData

/// One song an album or artist entry in Recents plays, as saved when the
/// collection last played (`PLAY-019`).
nonisolated struct PlaybackCollectionSong: Codable, Equatable, Sendable {
    var catalogID: String
    var title: String
    var artistName: String
    var albumTitle: String?
    var artworkURLTemplate: String?
    var durationSeconds: Double?
}

/// An album or artist in Recents (`PLAY-019`). Synced through CloudKit, so
/// every property has a default and nothing is unique: two devices can insert
/// the same album, and `RecentCollectionRepository` merges them by `groupKey`.
@Model
final class RecentCollectionRecord {
    #Index<RecentCollectionRecord>([\.groupKey])

    var id: UUID = UUID()
    /// `album:<catalog ID>` or `artist:<catalog ID>`: one entry per album or
    /// artist, whichever artist collection played.
    var groupKey: String = ""
    var kindRawValue: String = PlaybackCollection.Kind.album.rawValue
    var catalogID: String = ""
    var title: String = ""
    var artworkURLTemplate: String?
    var lastPlayedAt: Date = Date.distantPast
    /// The saved song list, encoded `[PlaybackCollectionSong]`.
    var songsData: Data = Data()

    init(collection: PlaybackCollection, songs: [PlaybackCollectionSong], artworkURLTemplate: String?, playedAt: Date) {
        groupKey = collection.groupKey
        update(collection: collection, songs: songs, artworkURLTemplate: artworkURLTemplate, playedAt: playedAt)
    }

    func update(collection: PlaybackCollection, songs: [PlaybackCollectionSong], artworkURLTemplate: String?, playedAt: Date) {
        kindRawValue = collection.kind.rawValue
        catalogID = collection.catalogID
        title = collection.title
        if let artworkURLTemplate { self.artworkURLTemplate = artworkURLTemplate }
        lastPlayedAt = playedAt
        songsData = (try? JSONEncoder().encode(songs)) ?? Data()
    }

    var collection: PlaybackCollection {
        PlaybackCollection(kind: PlaybackCollection.Kind(rawValue: kindRawValue) ?? .album, catalogID: catalogID, title: title)
    }

    var songs: [PlaybackCollectionSong] {
        (try? JSONDecoder().decode([PlaybackCollectionSong].self, from: songsData)) ?? []
    }
}
