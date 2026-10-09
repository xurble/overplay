import Foundation
import SwiftData

/// A Recents entry as the app and CarPlay show it (`PLAY-019`).
@MainActor
enum RecentCollectionPresentation {
    struct Song: Identifiable, Equatable {
        let catalogID: String
        let summary: TrackSummaryPresentation
        var id: String { catalogID }
    }

    /// "Album", "Artist · Essentials" or "Artist · Top Songs", and the count.
    static func subtitle(for recent: RecentCollectionRecord) -> String {
        let kind = switch recent.collection.kind {
        case .album: "Album"
        case .artistEssentials: "Artist · Essentials"
        case .artistTopSongs: "Artist · Top Songs"
        }
        let count = recent.songs.count
        return "\(kind) · \(count == 1 ? "1 song" : "\(count) songs")"
    }

    /// The saved songs as track rows. Songs Overplay tracks show their counts
    /// and retired state; the rest show none.
    static func songs(for recent: RecentCollectionRecord, in context: ModelContext) -> [Song] {
        let tracked = (try? TrackRecordRepository.tracksByCatalogID(in: context)) ?? [:]
        return recent.songs.map { song in
            let item = tracked[song.catalogID].flatMap { try? PlaylistItemRepository.item(trackID: $0.id, in: context) }
            return Song(catalogID: song.catalogID, summary: TrackSummaryPresentation(
                // Rows are identified by catalog song ID (`Song.id`), not this.
                id: item?.id ?? recent.id,
                trackID: item?.trackID,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                artworkURLString: song.artworkURLTemplate,
                skipCount: item?.skipCount ?? 0,
                playthroughCount: item?.playthroughCount ?? 0,
                applePlayCount: item?.applePlayCount,
                isRetired: item?.evictedAt != nil
            ))
        }
    }

    static func isPlaying(_ recent: RecentCollectionRecord, controller: PlaybackController) -> Bool {
        controller.currentTrack != nil && controller.playingCollectionGroupKey == recent.groupKey
    }

    static func isCurrent(_ song: Song, in recent: RecentCollectionRecord, controller: PlaybackController) -> Bool {
        isPlaying(recent, controller: controller) && controller.currentMember?.catalogSongID == song.catalogID
    }
}
