import Foundation
import Testing
@testable import Overplay

@MainActor
@Suite("Current playlist item matcher")
struct CurrentPlaylistItemMatcherTests {
    @Test("matches exact item or active playlist music identifiers")
    func matchesExactItemOrActivePlaylistMusicIdentifiers() {
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let otherPlaylist = PlaylistRecord(musicPlaylistID: "other", name: "Other")
        let track = TrackRecord(catalogID: "catalog", libraryID: "library", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
        let otherItem = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID())

        #expect(CurrentPlaylistItemMatcher.isCurrent(
            itemID: item.id,
            track: track,
            playlist: playlist,
            currentPlaylistID: "main",
            currentPlaylistItem: item,
            currentTrack: CurrentPlaybackTrack(id: "other", title: "Track", artistName: "Artist")
        ))
        #expect(!CurrentPlaylistItemMatcher.isCurrent(
            itemID: otherItem.id,
            track: track,
            playlist: playlist,
            currentPlaylistID: "main",
            currentPlaylistItem: item,
            currentTrack: CurrentPlaybackTrack(id: "catalog", title: "Track", artistName: "Artist")
        ))
        #expect(CurrentPlaylistItemMatcher.isCurrent(
            itemID: item.id,
            track: track,
            playlist: playlist,
            currentPlaylistID: "main",
            currentPlaylistItem: nil,
            currentTrack: CurrentPlaybackTrack(id: "catalog", title: "Track", artistName: "Artist")
        ))
        #expect(CurrentPlaylistItemMatcher.isCurrent(
            itemID: item.id,
            track: track,
            playlist: playlist,
            currentPlaylistID: "main",
            currentPlaylistItem: nil,
            currentTrack: CurrentPlaybackTrack(id: "library", title: "Track", artistName: "Artist")
        ))
        #expect(!CurrentPlaylistItemMatcher.isCurrent(
            itemID: item.id,
            track: track,
            playlist: otherPlaylist,
            currentPlaylistID: "main",
            currentPlaylistItem: nil,
            currentTrack: CurrentPlaybackTrack(id: "catalog", title: "Track", artistName: "Artist")
        ))
    }
}
