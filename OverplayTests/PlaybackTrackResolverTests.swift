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

    @Test("current playback track can trust a queue correlated playlist item")
    func currentPlaybackTrackCanTrustQueueCorrelatedPlaylistItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Current Track",
            artistName: "Current Artist"
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: 2)
        context.insert(playlist)
        context.insert(track)
        context.insert(item)

        let currentTrack = try #require(PlaybackTrackResolver.currentPlaybackTrack(
            musicItemID: "runtime-only-id",
            playlistItem: item,
            musicPlaylistID: playlist.musicPlaylistID,
            queueItem: nil,
            trustPlaylistItem: true,
            in: context
        ))

        #expect(currentTrack.id == "runtime-only-id")
        #expect(currentTrack.title == "Current Track")
        #expect(currentTrack.skipCount == 2)
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

    @Test("metadata sync trusts a queue correlated playlist item")
    func metadataSyncTrustsQueueCorrelatedPlaylistItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let track = TrackRecord(
            catalogID: "catalog-current",
            libraryID: "library-current",
            title: "Current Track",
            artistName: "Current Artist"
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: 3)
        context.insert(playlist)
        context.insert(track)
        context.insert(item)

        let update = PlaybackTrackMetadataSync.metadataUpdate(
            for: "runtime-only-id",
            currentTrack: CurrentPlaybackTrack(
                id: "library-current",
                title: "Current Track",
                artistName: "Current Artist"
            ),
            currentPlaylistItem: item,
            trustedPlaylistItem: item,
            currentPlaylistID: playlist.musicPlaylistID,
            queueItem: nil,
            in: context
        )

        #expect(update.playlistItem?.id == item.id)
        #expect(update.track?.id == "runtime-only-id")
        #expect(update.track?.title == "Current Track")
        #expect(update.track?.skipCount == 3)
    }

    @Test("metadata sync lets queue correlated identity replace stale display")
    func metadataSyncLetsQueueCorrelatedIdentityReplaceStaleDisplay() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let staleTrack = TrackRecord(
            catalogID: "kennedy",
            libraryID: "kennedy",
            title: "Kennedy",
            artistName: "Stale Artist"
        )
        let currentTrack = TrackRecord(
            catalogID: "shimmy",
            libraryID: "shimmy",
            title: "Shimmy Shimmy",
            artistName: "Current Artist"
        )
        let staleItem = PlaylistItemRecord(playlistID: playlist.id, trackID: staleTrack.id, skipCount: 1)
        let currentItem = PlaylistItemRecord(playlistID: playlist.id, trackID: currentTrack.id, skipCount: 7)
        context.insert(playlist)
        context.insert(staleTrack)
        context.insert(currentTrack)
        context.insert(staleItem)
        context.insert(currentItem)

        let update = PlaybackTrackMetadataSync.metadataUpdate(
            for: "shimmy",
            currentTrack: CurrentPlaybackTrack(staleTrack, musicItemID: "kennedy", item: staleItem),
            currentPlaylistItem: staleItem,
            trustedPlaylistItem: currentItem,
            currentPlaylistID: playlist.musicPlaylistID,
            queueItem: nil,
            in: context
        )

        #expect(update.playlistItem?.id == currentItem.id)
        #expect(update.track?.id == "shimmy")
        #expect(update.track?.title == "Shimmy Shimmy")
        #expect(update.track?.skipCount == 7)
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

    @Test("restored playback target resolves through the active playlist item")
    func restoredPlaybackTargetResolvesThroughActivePlaylistItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let targetTrack = TrackRecord(
            catalogID: "shared",
            libraryID: "shared",
            title: "Target",
            artistName: "Artist"
        )
        let otherTrack = TrackRecord(
            catalogID: "shared",
            libraryID: "shared",
            title: "Other",
            artistName: "Artist"
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: targetTrack.id)
        context.insert(playlist)
        context.insert(targetTrack)
        context.insert(otherTrack)
        context.insert(item)

        let target = try PlaybackTrackResolver.restoredPlaybackTarget(
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: item,
            currentTrack: CurrentPlaybackTrack(id: "shared", title: "Target", artistName: "Artist"),
            in: context
        )

        #expect(target?.playlist.id == playlist.id)
        #expect(target?.track.id == targetTrack.id)
    }

    @Test("restored playback target uses local track id when runtime music id is unresolved")
    func restoredPlaybackTargetUsesLocalTrackIDWhenRuntimeMusicIDIsUnresolved() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let targetTrack = TrackRecord(
            catalogID: "catalog-target",
            libraryID: "library-target",
            title: "Target",
            artistName: "Artist"
        )
        let firstTrack = TrackRecord(
            catalogID: "catalog-first",
            libraryID: "library-first",
            title: "First",
            artistName: "Artist"
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: targetTrack.id)
        context.insert(playlist)
        context.insert(targetTrack)
        context.insert(firstTrack)
        context.insert(item)

        let target = try PlaybackTrackResolver.restoredPlaybackTarget(
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: nil,
            currentLocalTrackID: targetTrack.id.uuidString,
            currentTrack: CurrentPlaybackTrack(
                id: "runtime-only-restored-id",
                title: "Target",
                artistName: "Artist"
            ),
            in: context
        )

        #expect(target?.playlist.id == playlist.id)
        #expect(target?.track.id == targetTrack.id)
    }

    @Test("default playback playlist prefers selected active playlist then main playlist")
    func defaultPlaybackPlaylistPrefersSelectedThenMain() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let main = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let triage = PlaylistRecord(musicPlaylistID: "triage", name: "Triage", role: .triage)
        let inactiveSelected = PlaylistRecord(
            musicPlaylistID: "inactive",
            name: "Inactive",
            role: .triage,
            isActive: false
        )
        context.insert(main)
        context.insert(triage)
        context.insert(inactiveSelected)

        let selected = try PlaybackTrackResolver.defaultPlaybackPlaylist(
            settings: OverplaySettings(selectedPlaylistID: triage.musicPlaylistID),
            in: context
        )
        let fallback = try PlaybackTrackResolver.defaultPlaybackPlaylist(
            settings: OverplaySettings(selectedPlaylistID: inactiveSelected.musicPlaylistID),
            in: context
        )

        #expect(selected?.id == triage.id)
        #expect(fallback?.id == main.id)
    }
}
