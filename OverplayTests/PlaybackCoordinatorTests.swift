import Foundation
import SwiftData
import Testing
@testable import Overplay

@Suite("Playback coordinators")
struct PlaybackCoordinatorTests {
    @Test("shuffle enable stores an order retaining the current track first")
    func shuffleEnableStoresCurrentTrackFirst() throws {
        let defaults = try #require(UserDefaults(suiteName: "OverplayTests.PlaybackCoordinator.\(UUID().uuidString)"))
        let trackIDs = [UUID(), UUID(), UUID()]
        let orderTracks = playbackItems(trackIDs)
        let currentLocalTrackID = trackIDs[1].uuidString

        PlaybackModeCoordinator.setShuffleEnabled(
            true,
            playerID: "main",
            playlistID: "playlist-1",
            orderTracks: orderTracks,
            currentLocalTrackID: currentLocalTrackID,
            defaults: defaults
        )

        let state = PlaybackModeStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults)
        #expect(state.shuffleEnabled)
        #expect(state.orderedTrackIDs.first == currentLocalTrackID)
        #expect(Set(state.orderedTrackIDs) == Set(trackIDs.map(\.uuidString)))
    }

    @Test("starting playback at a track keeps the stored shuffled order")
    func startingPlaybackAtTrackKeepsStoredShuffledOrder() throws {
        let defaults = try #require(UserDefaults(suiteName: "OverplayTests.PlaybackCoordinator.\(UUID().uuidString)"))
        let trackIDs = [UUID(), UUID(), UUID(), UUID()]
        let orderTracks = playbackItems(trackIDs)
        let storedOrder = [
            trackIDs[2].uuidString,
            trackIDs[0].uuidString,
            trackIDs[3].uuidString,
            trackIDs[1].uuidString
        ]
        PlaybackModeStore.save(
            PlaybackModeState(
                playerID: "main",
                musicPlaylistID: "playlist-1",
                shuffleEnabled: true,
                orderedTrackIDs: storedOrder
            ),
            to: defaults
        )

        let orderedTrackIDs = PlaybackModeCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: "main",
            playlistID: "playlist-1",
            startingTrackID: trackIDs[1].uuidString,
            promoteStartingTrackInShuffle: false,
            defaults: defaults
        )

        let state = PlaybackModeStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults)
        #expect(orderedTrackIDs == storedOrder)
        #expect(state.orderedTrackIDs == storedOrder)
    }

    @Test("repeat restart keeps last played last for small shuffled queues")
    func repeatRestartKeepsLastPlayedLastForSmallShuffledQueues() throws {
        let defaults = try #require(UserDefaults(suiteName: "OverplayTests.PlaybackCoordinator.\(UUID().uuidString)"))
        let trackIDs = [UUID(), UUID(), UUID()]
        let orderTracks = playbackItems(trackIDs)
        let lastLocalTrackID = trackIDs[0].uuidString
        PlaybackModeStore.save(
            PlaybackModeState(
                playerID: "main",
                musicPlaylistID: "playlist-1",
                shuffleEnabled: true,
                orderedTrackIDs: trackIDs.map(\.uuidString)
            ),
            to: defaults
        )

        let restart = PlaybackModeCoordinator.repeatRestartOrder(
            orderTracks: orderTracks,
            playerID: "main",
            playlistID: "playlist-1",
            lastLocalTrackID: lastLocalTrackID,
            defaults: defaults
        )

        let state = PlaybackModeStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults)
        #expect(restart.didUpdateStoredShuffleOrder)
        #expect(restart.orderedTrackIDs.last == lastLocalTrackID)
        #expect(state.orderedTrackIDs == restart.orderedTrackIDs)
    }

    @Test("active queue index advances and clears at bounds")
    func activeQueueIndexAdvancesAndClearsAtBounds() {
        let ids = ["first", "second", "third"]

        #expect(PlaybackQueueCoordinator.advancedActiveQueueIndex(
            by: 1,
            activeQueueLocalTrackIDs: ids,
            currentIndex: 1
        ) == 2)
        #expect(PlaybackQueueCoordinator.advancedActiveQueueIndex(
            by: 1,
            activeQueueLocalTrackIDs: ids,
            currentIndex: 2
        ) == nil)
        #expect(PlaybackQueueCoordinator.updatedActiveQueueIndex(
            localTrackID: "first",
            activeQueueLocalTrackIDs: ids,
            currentIndex: 2
        ) == 0)
    }

    @Test("realized active queue state preserves queue and playlist item identity")
    func realizedActiveQueueStatePreservesQueueAndPlaylistItemIdentity() {
        let firstItemID = UUID()
        let secondItemID = UUID()
        let entries = [
            RealizedPlaybackQueueEntry(
                queueEntryID: "queue-1",
                playlistItemID: firstItemID,
                localTrackID: "local-1",
                queuedMusicItemID: "music-1"
            ),
            RealizedPlaybackQueueEntry(
                queueEntryID: "queue-2",
                playlistItemID: secondItemID,
                localTrackID: "local-2",
                queuedMusicItemID: "music-2"
            )
        ]

        let state = PlaybackQueueCoordinator.activeQueueState(entries: entries, startingAt: "local-2")

        #expect(state.index == 1)
        #expect(state.entries[1].queueEntryID == "queue-2")
        #expect(state.entries[1].playlistItemID == secondItemID)
        #expect(PlaybackQueueCoordinator.updatedActiveQueueIndex(
            localTrackID: "local-1",
            activeQueueEntries: state.entries,
            currentIndex: state.index
        ) == 0)
    }

    @Test("playlist scoped local track lookup ignores matching tracks in other playlists")
    func playlistScopedLocalTrackLookupIgnoresOtherPlaylists() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let targetPlaylist = PlaylistRecord(
            musicPlaylistID: "target-playlist",
            name: "Target",
            role: .oneTruePlaylist
        )
        let otherPlaylist = PlaylistRecord(
            musicPlaylistID: "other-playlist",
            name: "Other",
            role: .triage
        )
        let targetTrack = TrackRecord(
            catalogID: "shared-music-id",
            libraryID: "shared-music-id",
            title: "Z Target",
            artistName: "Artist"
        )
        let otherTrack = TrackRecord(
            catalogID: "shared-music-id",
            libraryID: "shared-music-id",
            title: "A Other",
            artistName: "Artist"
        )
        context.insert(targetPlaylist)
        context.insert(otherPlaylist)
        context.insert(targetTrack)
        context.insert(otherTrack)
        context.insert(PlaylistItemRecord(playlistID: targetPlaylist.id, trackID: targetTrack.id))
        context.insert(PlaylistItemRecord(playlistID: otherPlaylist.id, trackID: otherTrack.id))

        let scopedID = try PlaybackQueueOrchestrator.localTrackID(
            matching: "shared-music-id",
            playlistID: targetPlaylist.musicPlaylistID,
            in: context
        )

        #expect(scopedID == targetTrack.id.uuidString)
    }

    private func playbackItems(_ trackIDs: [UUID]) -> [PlaybackOrderTrack] {
        trackIDs.enumerated().map { index, trackID in
            PlaybackOrderTrack(
                id: trackID.uuidString,
                sortOrder: index,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
    }
}
