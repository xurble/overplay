import Foundation
import SwiftData
import Testing
@testable import Overplay

@Suite("Playback queue orchestrator")
struct PlaybackQueueOrchestratorTests {
    @MainActor
    @Test("previewing a reshuffled queue never persists the order")
    func previewingAReshuffledQueueNeverPersistsTheOrder() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)
        let playerID = "test-\(UUID().uuidString)"
        let musicPlaylistID = "playlist-\(UUID().uuidString)"

        let playlist = PlaylistRecord(musicPlaylistID: musicPlaylistID, name: "Main")
        context.insert(playlist)
        let trackIDs = (0..<3).map { _ in UUID() }
        for (index, trackID) in trackIDs.enumerated() {
            context.insert(PlaylistItemRecord(
                playlistID: playlist.id,
                trackID: trackID,
                createdAt: Date(timeIntervalSince1970: Double(index))
            ))
        }
        try context.save()

        let storedOrder = trackIDs.map(\.uuidString)
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: playerID,
                musicPlaylistID: musicPlaylistID,
                orderedTrackIDs: storedOrder
            ),
            flushImmediately: true
        )
        defer {
            PlaybackOrderStore.clear(playerID: playerID, musicPlaylistID: musicPlaylistID, flushImmediately: true)
        }

        let preview = try PlaybackQueueOrchestrator.previewedReshuffledQueue(
            playlistID: musicPlaylistID,
            playerID: playerID,
            avoiding: storedOrder.first,
            in: context
        )

        #expect(Set(preview.orderedTrackIDs) == Set(storedOrder))
        // The stored order must be untouched until the player confirms it
        // can play the new queue.
        #expect(PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: musicPlaylistID).orderedTrackIDs == storedOrder)
    }

    @MainActor
    @Test("persisting a reshuffled order saves it under the scoped playlist ID")
    func persistingAReshuffledOrderSavesItUnderTheScopedPlaylistID() {
        let playerID = "test-\(UUID().uuidString)"
        let musicPlaylistID = "playlist-\(UUID().uuidString)"
        defer {
            PlaybackOrderStore.clear(playerID: playerID, musicPlaylistID: musicPlaylistID, flushImmediately: true)
        }

        PlaybackQueueOrchestrator.persistReshuffledOrder(
            ["a", "b", "c"],
            playlistID: musicPlaylistID,
            playerID: playerID
        )

        #expect(PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: musicPlaylistID).orderedTrackIDs == ["a", "b", "c"])
    }
}
