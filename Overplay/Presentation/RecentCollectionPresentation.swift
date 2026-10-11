import Foundation
import SwiftData

/// A Recents entry as the app and CarPlay show it (`PLAY-019`).
@MainActor
enum RecentCollectionPresentation {
    struct Song: Identifiable, Equatable {
        let catalogID: String
        let summary: TrackSummaryPresentation
        /// Swipe right: an untracked, Triage or retired song.
        var canMoveToOneTruePlaylist = true
        /// Swipe left: an untracked or retired song.
        var canMoveToTriage = true
        var id: String { catalogID }
    }

    /// "Album", "Artist · Essentials" or "Artist · Top Songs", and the count.
    static func subtitle(for recent: RecentCollectionRecord) -> String {
        let kind = switch recent.collection.kind {
        case .album: "Album"
        case .artistEssentials: "Artist · Essentials"
        case .artistTopSongs: "Artist · Top Songs"
        case .libraryPlaylist: "Playlist"
        case .libraryAlbum: "Album"
        case .libraryArtist: "Artist"
        case .librarySongs: "Songs"
        }
        let count = recent.songs.count
        return "\(kind) · \(count == 1 ? "1 song" : "\(count) songs")"
    }

    /// The saved songs as track rows. Songs Overplay tracks show their counts
    /// and retired state; the rest show none.
    static func songs(for recent: RecentCollectionRecord, in context: ModelContext) -> [Song] {
        songs(recent.songs, rowID: recent.id, in: context)
    }

    /// Any collection's songs as track rows, as for a Recents entry.
    static func songs(_ songs: [PlaybackCollectionSong], rowID: UUID, in context: ModelContext) -> [Song] {
        let tracked = (try? TrackRecordRepository.tracksByCatalogID(in: context)) ?? [:]
        let roles = Dictionary(((try? context.fetch(FetchDescriptor<PlaylistRecord>())) ?? []).map { ($0.id, $0.role) },
                               uniquingKeysWith: { first, _ in first })
        return songs.map { song in
            // A library song is keyed by its library ID.
            let record = tracked[song.catalogID] ?? (try? TrackRecordRepository.track(musicItemID: song.catalogID, in: context))
            let item = record.flatMap { try? PlaylistItemRepository.item(trackID: $0.id, in: context) }
            return Song(catalogID: song.catalogID, summary: TrackSummaryPresentation(
                // Rows are identified by catalog song ID (`Song.id`), not this.
                id: item?.id ?? rowID,
                trackID: item?.trackID,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                artworkURLString: song.artworkURLTemplate,
                skipCount: item?.skipCount ?? 0,
                playthroughCount: item?.playthroughCount ?? 0,
                applePlayCount: item?.applePlayCount,
                isRetired: item?.evictedAt != nil,
                isTracked: item != nil
            ), canMoveToOneTruePlaylist: item.map { roles[$0.playlistID] == .triageBucket } ?? true,
               canMoveToTriage: item == nil || item?.evictedAt != nil)
        }
    }

    static func isPlaying(_ recent: RecentCollectionRecord, controller: PlaybackController) -> Bool {
        controller.currentTrack != nil && controller.playingCollectionGroupKey == recent.groupKey
    }

    static func isCurrent(_ song: Song, in recent: RecentCollectionRecord, controller: PlaybackController) -> Bool {
        isCurrent(song, groupKey: recent.groupKey, controller: controller)
    }

    static func isCurrent(_ song: Song, groupKey: String, controller: PlaybackController) -> Bool {
        controller.currentTrack != nil && controller.playingCollectionGroupKey == groupKey
            && controller.currentMember?.catalogSongID == song.catalogID
    }
}
