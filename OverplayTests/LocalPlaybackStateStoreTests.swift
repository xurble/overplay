import Foundation
import Testing
@testable import Overplay

@Suite("Local playback state store")
struct LocalPlaybackStateStoreTests {
    @Test("saves loads and clears playback state in local defaults")
    func savesLoadsAndClearsPlaybackState() throws {
        let suiteName = "OverplayTests.LocalPlaybackStateStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let state = LocalPlaybackState(
            playlistID: "playlist-1",
            musicItemID: "track-1",
            elapsedSeconds: 42,
            wasPlaying: true,
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        LocalPlaybackStateStore.save(state, to: defaults)
        #expect(LocalPlaybackStateStore.load(from: defaults) == state)

        LocalPlaybackStateStore.clear(from: defaults)
        #expect(LocalPlaybackStateStore.load(from: defaults) == nil)
    }
}
