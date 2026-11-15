import Foundation

/// What an album or artist deep dive offers under its header (`PLAY-021`):
/// the artist, on an album's page, then the artist's full albums oldest
/// first. The app's strip and CarPlay's strip and list all show these tiles.
enum DeepDiveDiscographyPresentation {
    struct Tile: Identifiable, Equatable {
        /// The Recents group key it plays as.
        var id: String
        var item: CatalogPlayItem
        var title: String
        var subtitle: String
        var artworkURL: String?
        /// The album whose page this is: marked, and does nothing.
        var isThisPage: Bool
        var isPlaying: Bool

        var isArtist: Bool {
            if case .artist = item { true } else { false }
        }
    }

    /// Only album and artist deep dives offer a discography.
    static func offersDiscography(_ collection: PlaybackCollection) -> Bool {
        switch collection.kind {
        case .album, .artistEssentials, .artistTopSongs: true
        default: false
        }
    }

    /// The strip's title: the artist on an album's page; on the artist's own
    /// page, its albums.
    static func heading(for collection: PlaybackCollection, discography: ArtistDiscography) -> String {
        collection.kind == .album ? discography.artistName : "Albums"
    }

    static func tiles(
        for collection: PlaybackCollection, discography: ArtistDiscography, playingGroupKey: String?
    ) -> [Tile] {
        var tiles: [Tile] = []
        if collection.kind == .album {
            let item = CatalogPlayItem.artist(id: discography.artistID, name: discography.artistName)
            tiles.append(Tile(id: item.groupKey ?? "", item: item, title: discography.artistName, subtitle: "Artist",
                              artworkURL: discography.artistArtworkURL, isThisPage: false,
                              isPlaying: item.groupKey == playingGroupKey))
        }
        for album in discography.albums {
            let item = CatalogPlayItem.album(id: album.id, title: album.title)
            let isThisPage = collection.kind == .album && album.id == collection.catalogID
            tiles.append(Tile(id: item.groupKey ?? "", item: item, title: album.title,
                              subtitle: isThisPage ? "This Album" : year(album.releaseDate) ?? "Album",
                              artworkURL: album.artworkURL, isThisPage: isThisPage,
                              isPlaying: item.groupKey == playingGroupKey))
        }
        return tiles
    }

    /// Release dates are calendar days at midnight GMT, so the year is read
    /// in GMT: a local zone west of it would give 1 January the year before.
    private static func year(_ date: Date?) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT") ?? .gmt
        return date.map { String(calendar.component(.year, from: $0)) }
    }
}
