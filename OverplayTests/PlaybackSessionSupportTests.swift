import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playback session support")
struct PlaybackSessionSupportTests {
    @Test("resolve prefers current item when it matches the music item id")
    func resolvePrefersMatchingCurrentItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Track",
            artistName: "Artist"
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: 2)
        context.insert(playlist)
        context.insert(track)
        context.insert(item)

        let resolved = try PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: "library-1",
            currentPlaylistItem: item,
            playlist: playlist,
            in: context
        )

        #expect(resolved?.id == item.id)
        #expect(resolved?.skipCount == 2)
    }

    @Test("resolve falls back to playlist lookup when current item does not match")
    func resolveFallsBackToPlaylistLookup() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let currentTrack = TrackRecord(
            catalogID: "catalog-current",
            libraryID: "library-current",
            title: "Current",
            artistName: "Artist"
        )
        let targetTrack = TrackRecord(
            catalogID: "catalog-target",
            libraryID: "library-target",
            title: "Target",
            artistName: "Artist"
        )
        let currentItem = PlaylistItemRecord(playlistID: playlist.id, trackID: currentTrack.id)
        let targetItem = PlaylistItemRecord(playlistID: playlist.id, trackID: targetTrack.id, skipCount: 3)
        context.insert(playlist)
        context.insert(currentTrack)
        context.insert(targetTrack)
        context.insert(currentItem)
        context.insert(targetItem)

        let resolved = try PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: "catalog-target",
            currentPlaylistItem: currentItem,
            playlist: playlist,
            in: context
        )

        #expect(resolved?.id == targetItem.id)
        #expect(resolved?.skipCount == 3)
    }

    @Test("resolve returns nil when no playlist item matches")
    func resolveReturnsNilWhenNoMatch() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        context.insert(playlist)

        let resolved = try PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: "missing-track",
            currentPlaylistItem: nil,
            playlist: playlist,
            in: context
        )

        #expect(resolved == nil)
    }
}
