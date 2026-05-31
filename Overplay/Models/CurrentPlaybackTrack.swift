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
    var evictedAt: Date?
    var protected: Bool

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
        evictedAt: Date? = nil,
        protected: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURLTemplate = artworkURLTemplate
        self.durationSeconds = durationSeconds
        self.skipCount = skipCount
        self.playthroughCount = playthroughCount
        self.evictedAt = evictedAt
        self.protected = protected
    }

    init(_ track: TrackedTrack) {
        self.init(
            id: track.id,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            artworkURLTemplate: track.artworkURLTemplate,
            durationSeconds: track.durationSeconds,
            skipCount: track.skipCount,
            playthroughCount: track.playthroughCount,
            evictedAt: track.evictedAt,
            protected: track.protected
        )
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
            evictedAt: item?.evictedAt,
            protected: item?.protected ?? false
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
