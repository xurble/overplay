import Foundation
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
