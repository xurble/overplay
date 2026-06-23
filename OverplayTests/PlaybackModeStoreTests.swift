import Foundation
import Testing
@testable import Overplay

@Suite("Playback order store")
struct PlaybackOrderStoreTests {
    @Test("stores independent order state by player and playlist")
    func storesIndependentOrderStateByPlayerAndPlaylist() throws {
        let suiteName = "OverplayTests.PlaybackOrderStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: "main",
                musicPlaylistID: "playlist-1",
                orderedTrackIDs: ["a", "b"],
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            to: defaults,
            flushImmediately: true
        )

        let saved = PlaybackOrderStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults)
        let otherPlaylist = PlaybackOrderStore.state(playerID: "main", musicPlaylistID: "playlist-2", from: defaults)
        let otherPlayer = PlaybackOrderStore.state(playerID: "carplay", musicPlaylistID: "playlist-1", from: defaults)

        #expect(saved.orderedTrackIDs == ["a", "b"])
        #expect(otherPlaylist.orderedTrackIDs.isEmpty)
        #expect(otherPlayer.orderedTrackIDs.isEmpty)
    }

    @Test("updates and clears stored order state")
    func updatesAndClearsStoredOrderState() throws {
        let suiteName = "OverplayTests.PlaybackOrderStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PlaybackOrderStore.update(
            playerID: "main",
            musicPlaylistID: "playlist-1",
            in: defaults,
            flushImmediately: true
        ) { state in
            state.orderedTrackIDs = ["track-1"]
        }

        #expect(PlaybackOrderStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults).orderedTrackIDs == ["track-1"])

        PlaybackOrderStore.clear(
            playerID: "main",
            musicPlaylistID: "playlist-1",
            from: defaults,
            flushImmediately: true
        )

        #expect(PlaybackOrderStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults).orderedTrackIDs.isEmpty)
    }

    @Test("rekeys stored order state when playlist ID heals")
    func rekeysStoredOrderStateWhenPlaylistIDHeals() throws {
        let suiteName = "OverplayTests.PlaybackOrderStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PlaybackOrderStore.update(playerID: "main", musicPlaylistID: "p.old", in: defaults) { state in
            state.orderedTrackIDs = ["track-1"]
        }

        PlaybackOrderStore.rekeyMusicPlaylistID(from: "p.old", to: "p.new", from: defaults, flushImmediately: true)

        #expect(PlaybackOrderStore.state(playerID: "main", musicPlaylistID: "p.new", from: defaults).orderedTrackIDs == ["track-1"])
        #expect(PlaybackOrderStore.state(playerID: "main", musicPlaylistID: "p.old", from: defaults).orderedTrackIDs.isEmpty)
    }
}
