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
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: "local-track-1"
        )

        LocalPlaybackStateStore.save(state, to: defaults, flushImmediately: true)
        #expect(LocalPlaybackStateStore.load(from: defaults) == state)

        LocalPlaybackStateStore.clear(from: defaults, flushImmediately: true)
        #expect(LocalPlaybackStateStore.load(from: defaults) == nil)
    }

    @Test("flush policy writes through on transitions and throttles playback ticks")
    func flushPolicyWritesThroughOnTransitionsAndThrottlesPlaybackTicks() {
        let now = Date(timeIntervalSince1970: 100)
        let recentFlush = Date(timeIntervalSince1970: 86)
        let oldFlush = Date(timeIntervalSince1970: 85)

        #expect(LocalPlaybackStateFlushPolicy.shouldFlush(
            now: now,
            lastFlushAt: recentFlush,
            isPlaying: true,
            didChangePlaybackIdentity: false,
            force: true
        ))
        #expect(LocalPlaybackStateFlushPolicy.shouldFlush(
            now: now,
            lastFlushAt: recentFlush,
            isPlaying: true,
            didChangePlaybackIdentity: true,
            force: false
        ))
        #expect(!LocalPlaybackStateFlushPolicy.shouldFlush(
            now: now,
            lastFlushAt: recentFlush,
            isPlaying: true,
            didChangePlaybackIdentity: false,
            force: false
        ))
        #expect(LocalPlaybackStateFlushPolicy.shouldFlush(
            now: now,
            lastFlushAt: oldFlush,
            isPlaying: true,
            didChangePlaybackIdentity: false,
            force: false
        ))
        #expect(!LocalPlaybackStateFlushPolicy.shouldFlush(
            now: now,
            lastFlushAt: nil,
            isPlaying: false,
            didChangePlaybackIdentity: false,
            force: false
        ))
    }

    @Test("loads legacy playback state without local track ID")
    func loadsLegacyPlaybackStateWithoutLocalTrackID() throws {
        struct LegacyLocalPlaybackState: Codable {
            var playlistID: String
            var musicItemID: String
            var elapsedSeconds: Double
            var wasPlaying: Bool
            var updatedAt: Date
        }

        let suiteName = "OverplayTests.LocalPlaybackStateStore.Legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let legacyState = LegacyLocalPlaybackState(
            playlistID: "playlist-1",
            musicItemID: "track-1",
            elapsedSeconds: 42,
            wasPlaying: true,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        defaults.set(try JSONEncoder().encode(legacyState), forKey: "overplay.localPlaybackState")

        let loadedState = try #require(LocalPlaybackStateStore.load(from: defaults))

        #expect(loadedState.playlistID == legacyState.playlistID)
        #expect(loadedState.musicItemID == legacyState.musicItemID)
        #expect(loadedState.elapsedSeconds == legacyState.elapsedSeconds)
        #expect(loadedState.wasPlaying == legacyState.wasPlaying)
        #expect(loadedState.updatedAt == legacyState.updatedAt)
        #expect(loadedState.localTrackID == nil)
    }
}
