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
        case .searchSong: "Song"
        case .madeForYou: "Made For You"
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
        // Three fetches in all, then lookups: a library's Songs list is
        // thousands of rows, and a fetch per row hung the Mac.
        let allTracks = (try? TrackRecordRepository.allTracks(in: context)) ?? []
        let tracked = TrackRecordRepository.tracksByCatalogID(allTracks)
        let scope = MusicResourceReference.currentLibraryScope
        var byLibraryID: [String: TrackRecord] = [:]
        for record in allTracks {
            // A merged track keeps the library IDs it absorbed as aliases.
            let aliases = record.confirmedAliases.filter { $0.domain == .librarySong && $0.scope == scope }.map(\.value)
            let own = record.libraryScope == scope ? [record.libraryID].compactMap { $0 } : []
            for libraryID in own + aliases where byLibraryID[libraryID] == nil { byLibraryID[libraryID] = record }
        }
        var itemsByTrackID: [UUID: PlaylistItemRecord] = [:]
        for item in (try? PlaylistItemRepository.allItems(in: context)) ?? [] where !item.isDeleted {
            if itemsByTrackID[item.trackID] == nil { itemsByTrackID[item.trackID] = item }
        }
        let roles = Dictionary(((try? context.fetch(FetchDescriptor<PlaylistRecord>())) ?? []).map { ($0.id, $0.role) },
                               uniquingKeysWith: { first, _ in first })
        return songs.map { song in
            // A library song is keyed by its library ID.
            let record = tracked[song.catalogID] ?? byLibraryID[song.catalogID]
            let item = record.flatMap { itemsByTrackID[$0.id] }
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
