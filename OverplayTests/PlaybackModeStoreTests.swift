import Foundation
import Testing
@testable import Overplay

@Suite("Playback mode store")
struct PlaybackModeStoreTests {
    @Test("stores independent mode state by player and playlist")
    func storesIndependentModeStateByPlayerAndPlaylist() throws {
        let suiteName = "OverplayTests.PlaybackModeStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PlaybackModeStore.save(
            PlaybackModeState(
                playerID: "main",
                musicPlaylistID: "playlist-1",
                shuffleEnabled: true,
                repeatEnabled: true,
                orderedTrackIDs: ["a", "b"],
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            to: defaults
        )

        let saved = PlaybackModeStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults)
        let otherPlaylist = PlaybackModeStore.state(playerID: "main", musicPlaylistID: "playlist-2", from: defaults)
        let otherPlayer = PlaybackModeStore.state(playerID: "carplay", musicPlaylistID: "playlist-1", from: defaults)

        #expect(saved.shuffleEnabled)
        #expect(saved.repeatEnabled)
        #expect(saved.orderedTrackIDs == ["a", "b"])
        #expect(!otherPlaylist.shuffleEnabled)
        #expect(!otherPlaylist.repeatEnabled)
        #expect(otherPlaylist.orderedTrackIDs.isEmpty)
        #expect(!otherPlayer.shuffleEnabled)
        #expect(!otherPlayer.repeatEnabled)
        #expect(otherPlayer.orderedTrackIDs.isEmpty)
    }

    @Test("updates and clears stored mode state")
    func updatesAndClearsStoredModeState() throws {
        let suiteName = "OverplayTests.PlaybackModeStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PlaybackModeStore.update(playerID: "main", musicPlaylistID: "playlist-1", in: defaults) { state in
            state.shuffleEnabled = true
            state.orderedTrackIDs = ["track-1"]
        }

        #expect(PlaybackModeStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults).shuffleEnabled)

        PlaybackModeStore.clear(playerID: "main", musicPlaylistID: "playlist-1", from: defaults)

        #expect(!PlaybackModeStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults).shuffleEnabled)
    }

    @Test("rekeys stored mode state when playlist ID heals")
    func rekeysStoredModeStateWhenPlaylistIDHeals() throws {
        let suiteName = "OverplayTests.PlaybackModeStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PlaybackModeStore.update(playerID: "main", musicPlaylistID: "p.old", in: defaults) { state in
            state.shuffleEnabled = true
            state.orderedTrackIDs = ["track-1"]
        }

        PlaybackModeStore.rekeyMusicPlaylistID(from: "p.old", to: "p.new", from: defaults)

        #expect(PlaybackModeStore.state(playerID: "main", musicPlaylistID: "p.new", from: defaults).shuffleEnabled)
        #expect(PlaybackModeStore.state(playerID: "main", musicPlaylistID: "p.new", from: defaults).orderedTrackIDs == ["track-1"])
        #expect(!PlaybackModeStore.state(playerID: "main", musicPlaylistID: "p.old", from: defaults).shuffleEnabled)
    }
}
