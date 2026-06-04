import Foundation
import Testing
@testable import Overplay

@Suite("Playlist artwork selector")
struct PlaylistArtworkSelectorTests {
    @Test("representative artwork prefers first active playable track with artwork")
    func representativeArtworkPrefersFirstActivePlayableTrackWithArtwork() {
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let removedTrack = TrackRecord(
            catalogID: "removed",
            title: "Removed",
            artistName: "Artist",
            artworkURLTemplate: "https://example.com/removed.jpg"
        )
        let trackWithoutArtwork = TrackRecord(
            catalogID: "no-art",
            title: "No Art",
            artistName: "Artist"
        )
        let firstPlayableArtworkTrack = TrackRecord(
            catalogID: "first-art",
            title: "First Art",
            artistName: "Artist",
            artworkURLTemplate: "https://example.com/first.jpg"
        )
        let laterPlayableArtworkTrack = TrackRecord(
            catalogID: "later-art",
            title: "Later Art",
            artistName: "Artist",
            artworkURLTemplate: "https://example.com/later.jpg"
        )
        let removedItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: removedTrack.id,
            sortOrder: 0,
            removedFromRemoteAt: Date(timeIntervalSince1970: 10)
        )
        let noArtworkItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: trackWithoutArtwork.id,
            sortOrder: 1
        )
        let firstArtworkItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: firstPlayableArtworkTrack.id,
            sortOrder: 2
        )
        let laterArtworkItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: laterPlayableArtworkTrack.id,
            sortOrder: 3
        )
        let tracksByID = [
            removedTrack.id: removedTrack,
            trackWithoutArtwork.id: trackWithoutArtwork,
            firstPlayableArtworkTrack.id: firstPlayableArtworkTrack,
            laterPlayableArtworkTrack.id: laterPlayableArtworkTrack
        ]

        let artworkURL = PlaylistArtworkSelector.representativeArtworkURL(
            for: playlist,
            items: [laterArtworkItem, removedItem, firstArtworkItem, noArtworkItem],
            tracksByID: tracksByID
        )

        #expect(artworkURL == "https://example.com/first.jpg")
    }
}
