import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playback track resolver")
struct PlaybackTrackResolverTests {
    @Test("current playback track prefers playlist item state")
    func currentPlaybackTrackPrefersPlaylistItemState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Ready Track",
            artistName: "Ready Artist",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: 2, protected: true)
        context.insert(playlist)
        context.insert(track)
        context.insert(item)

        let currentTrack = try #require(PlaybackTrackResolver.currentPlaybackTrack(
            musicItemID: "library-1",
            playlistItem: item,
            musicPlaylistID: playlist.musicPlaylistID,
            queueItem: nil,
            in: context
        ))

        #expect(currentTrack.id == "library-1")
        #expect(currentTrack.title == "Ready Track")
        #expect(currentTrack.skipCount == 2)
        #expect(currentTrack.protected)
    }

    @Test("current playback track ignores a stale playlist item")
    func currentPlaybackTrackIgnoresStalePlaylistItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let staleTrack = TrackRecord(
            catalogID: "catalog-stale",
            libraryID: "library-stale",
            title: "Stale Track",
            artistName: "Stale Artist"
        )
        let currentTrackRecord = TrackRecord(
            catalogID: "catalog-current",
            libraryID: "library-current",
            title: "Current Track",
            artistName: "Current Artist"
        )
        let staleItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: staleTrack.id,
            skipCount: 4,
            protected: true
        )
        context.insert(playlist)
        context.insert(staleTrack)
        context.insert(currentTrackRecord)
        context.insert(staleItem)

        let currentTrack = try #require(PlaybackTrackResolver.currentPlaybackTrack(
            musicItemID: "catalog-current",
            playlistItem: staleItem,
            musicPlaylistID: playlist.musicPlaylistID,
            queueItem: nil,
            in: context
        ))

        #expect(currentTrack.id == "catalog-current")
        #expect(currentTrack.title == "Current Track")
        #expect(currentTrack.artistName == "Current Artist")
        #expect(currentTrack.skipCount == 0)
        #expect(!currentTrack.protected)
    }

    @Test("metadata sync clears a stale playlist item")
    func metadataSyncClearsStalePlaylistItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let staleTrack = TrackRecord(
            catalogID: "catalog-stale",
            libraryID: "library-stale",
            title: "Stale Track",
            artistName: "Stale Artist"
        )
        let currentTrackRecord = TrackRecord(
            catalogID: "catalog-current",
            libraryID: "library-current",
            title: "Current Track",
            artistName: "Current Artist"
        )
        let staleItem = PlaylistItemRecord(playlistID: playlist.id, trackID: staleTrack.id, skipCount: 4)
        context.insert(playlist)
        context.insert(staleTrack)
        context.insert(currentTrackRecord)
        context.insert(staleItem)

        let update = PlaybackTrackMetadataSync.metadataUpdate(
            for: "library-current",
            currentTrack: CurrentPlaybackTrack(
                id: "library-stale",
                title: "Stale Track",
                artistName: "Stale Artist"
            ),
            currentPlaylistItem: staleItem,
            currentPlaylistID: playlist.musicPlaylistID,
            queueItem: nil,
            in: context
        )

        #expect(update.playlistItem == nil)
        #expect(update.track?.id == "library-current")
        #expect(update.track?.title == "Current Track")
    }

    @Test("restored track lookup uses local track id before music item id")
    func restoredTrackLookupUsesLocalTrackIDFirst() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let localTrack = TrackRecord(
            catalogID: "catalog-local",
            libraryID: "library-local",
            title: "Local Track",
            artistName: "Ready Artist"
        )
        let musicIDTrack = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Music ID Track",
            artistName: "Ready Artist"
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: localTrack.id)
        context.insert(playlist)
        context.insert(localTrack)
        context.insert(musicIDTrack)
        context.insert(item)
        let state = LocalPlaybackState(
            playlistID: playlist.musicPlaylistID,
            musicItemID: "music-1",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: localTrack.id.uuidString
        )

        let restoredCandidate = try PlaybackTrackResolver.restoredTrackAndItem(
            from: state,
            playlist: playlist,
            in: context
        )
        let restored = try #require(restoredCandidate)

        #expect(restored.track.id == localTrack.id)
        #expect(restored.item?.id == item.id)
    }
}
