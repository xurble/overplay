import Foundation
import SwiftData
import Testing
@testable import Overplay

@Suite("Playback coordinators")
struct PlaybackCoordinatorTests {
    @Test("reshuffle stores an order with avoided track out of first position")
    func reshuffleStoresOrderAvoidingFirstPosition() throws {
        let defaults = try #require(UserDefaults(suiteName: "OverplayTests.PlaybackCoordinator.\(UUID().uuidString)"))
        let trackIDs = [UUID(), UUID(), UUID()]
        let orderTracks = playbackItems(trackIDs)
        let avoidedLocalTrackID = trackIDs[1].uuidString

        let orderedTrackIDs = PlaybackOrderCoordinator.reshuffle(
            playerID: "main",
            playlistID: "playlist-1",
            orderTracks: orderTracks,
            avoiding: avoidedLocalTrackID,
            defaults: defaults
        )

        let state = PlaybackOrderStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults)
        #expect(orderedTrackIDs.first != avoidedLocalTrackID)
        #expect(Set(state.orderedTrackIDs) == Set(trackIDs.map(\.uuidString)))
    }

    @Test("ordered track IDs preserve stored local order")
    func orderedTrackIDsPreserveStoredLocalOrder() throws {
        let defaults = try #require(UserDefaults(suiteName: "OverplayTests.PlaybackCoordinator.\(UUID().uuidString)"))
        let trackIDs = [UUID(), UUID(), UUID(), UUID()]
        let orderTracks = playbackItems(trackIDs)
        let storedOrder = [
            trackIDs[2].uuidString,
            trackIDs[0].uuidString,
            trackIDs[3].uuidString,
            trackIDs[1].uuidString
        ]
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: "main",
                musicPlaylistID: "playlist-1",
                orderedTrackIDs: storedOrder
            ),
            to: defaults
        )

        let orderedTrackIDs = PlaybackOrderCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: "main",
            playlistID: "playlist-1",
            defaults: defaults
        )

        let state = PlaybackOrderStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults)
        #expect(orderedTrackIDs == storedOrder)
        #expect(state.orderedTrackIDs == storedOrder)
    }

    @Test("append track IDs adds only playable missing tracks")
    func appendTrackIDsAddsOnlyPlayableMissingTracks() throws {
        let defaults = try #require(UserDefaults(suiteName: "OverplayTests.PlaybackCoordinator.\(UUID().uuidString)"))
        let trackIDs = [UUID(), UUID(), UUID(), UUID()]
        var orderTracks = playbackItems(trackIDs)
        orderTracks[3] = PlaybackOrderTrack(
            id: trackIDs[3].uuidString,
            createdAt: Date(timeIntervalSince1970: 3),
            isPlayable: false
        )
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: "main",
                musicPlaylistID: "playlist-1",
                orderedTrackIDs: [trackIDs[0].uuidString]
            ),
            to: defaults
        )

        let orderedTrackIDs = PlaybackOrderCoordinator.appendTrackIDs(
            [trackIDs[1].uuidString, trackIDs[3].uuidString, trackIDs[0].uuidString],
            playerID: "main",
            playlistID: "playlist-1",
            orderTracks: orderTracks,
            defaults: defaults
        )

        #expect(orderedTrackIDs == [trackIDs[0].uuidString, trackIDs[1].uuidString])
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

    @Test("transition index follows the player-reported entry when it moved")
    func transitionIndexFollowsThePlayerReportedEntryWhenItMoved() {
        let entries = realizedEntries(count: 4)

        #expect(PlaybackQueueCoordinator.reconciledTransitionIndex(
            playerReportedEntryID: entries[2].queueEntryID,
            activeQueueEntries: entries,
            preTransitionIndex: 0,
            offset: 1
        ) == 2)
    }

    @Test("transition index advances optimistically while the player still reports the outgoing entry")
    func transitionIndexAdvancesOptimisticallyWhileThePlayerStillReportsTheOutgoingEntry() {
        let entries = realizedEntries(count: 4)

        #expect(PlaybackQueueCoordinator.reconciledTransitionIndex(
            playerReportedEntryID: entries[1].queueEntryID,
            activeQueueEntries: entries,
            preTransitionIndex: 1,
            offset: 1
        ) == 2)
        #expect(PlaybackQueueCoordinator.reconciledTransitionIndex(
            playerReportedEntryID: nil,
            activeQueueEntries: entries,
            preTransitionIndex: 1,
            offset: 1
        ) == 2)
        #expect(PlaybackQueueCoordinator.reconciledTransitionIndex(
            playerReportedEntryID: "unknown-entry",
            activeQueueEntries: entries,
            preTransitionIndex: 2,
            offset: -1
        ) == 1)
    }

    @Test("out-of-bounds transition keeps the pre-transition index")
    func outOfBoundsTransitionKeepsThePreTransitionIndex() {
        let entries = realizedEntries(count: 3)

        #expect(PlaybackQueueCoordinator.reconciledTransitionIndex(
            playerReportedEntryID: entries[0].queueEntryID,
            activeQueueEntries: entries,
            preTransitionIndex: 0,
            offset: -1
        ) == 0)
        #expect(PlaybackQueueCoordinator.reconciledTransitionIndex(
            playerReportedEntryID: nil,
            activeQueueEntries: entries,
            preTransitionIndex: 2,
            offset: 1
        ) == 2)
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
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
    }

    private func realizedEntries(count: Int) -> [RealizedPlaybackQueueEntry] {
        (0..<count).map { index in
            RealizedPlaybackQueueEntry(
                queueEntryID: "queue-\(index)",
                playlistItemID: UUID(),
                localTrackID: "local-\(index)",
                queuedMusicItemID: "music-\(index)"
            )
        }
    }
}
