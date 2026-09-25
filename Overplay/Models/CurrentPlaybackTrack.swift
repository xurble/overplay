import Foundation

struct CurrentPlaybackTrack: Equatable, Sendable {
    var id: String
    var title: String
    var artistName: String
    var albumTitle: String?
    var artworkURLTemplate: String?
    var durationSeconds: Double?
    var skipCount: Int
    var playthroughCount: Int
    var applePlayCount: Int?
    var evictedAt: Date?

    var isEvicted: Bool {
        evictedAt != nil
    }

    init(
        id: String,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURLTemplate: String? = nil,
        durationSeconds: Double? = nil,
        skipCount: Int = 0,
        playthroughCount: Int = 0,
        applePlayCount: Int? = nil,
        evictedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURLTemplate = artworkURLTemplate
        self.durationSeconds = durationSeconds
        self.skipCount = skipCount
        self.playthroughCount = playthroughCount
        self.applePlayCount = applePlayCount
        self.evictedAt = evictedAt
    }

    init(_ track: TrackRecord, musicItemID: String, item: PlaylistItemRecord?) {
        self.init(
            id: musicItemID,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            artworkURLTemplate: track.artworkURLTemplate,
            durationSeconds: track.durationSeconds,
            skipCount: item?.skipCount ?? 0,
            playthroughCount: item?.playthroughCount ?? 0,
            applePlayCount: item?.applePlayCount,
            evictedAt: item?.evictedAt
        )
    }

    init(_ snapshot: TrackSnapshot) {
        self.init(
            id: snapshot.id,
            title: snapshot.title,
            artistName: snapshot.artistName,
            albumTitle: snapshot.albumTitle,
            artworkURLTemplate: snapshot.artworkURLTemplate,
            durationSeconds: snapshot.durationSeconds
        )
    }
}
