import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// `COUNT-003` (owner request, 2026-10-30): starting something else, or
/// ending a song after a long pause, is not a skip.
@MainActor
@Suite("Skips not counted", .serialized)
struct PlaybackSkipExceptionTests {
    private func start(_ fixture: PlaybackFixture, at index: Int) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    /// Paused, then playing again after `seconds`.
    private func pause(_ fixture: PlaybackFixture, for seconds: TimeInterval) async {
        fixture.controller.pause()
        await fixture.controller.samplePlayback()
        fixture.player.playbackStatus = .playing
        await fixture.controller.samplePlayback(now: .now.addingTimeInterval(seconds))
    }

    @Test func skippingWithinTheQueueStillCounts() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        await fixture.player.externallyAdvance()
        #expect(try fixture.item(0).skipCount == 1)
    }

    @Test func startingAnotherQueueIsNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        // Play Now from Search: a new queue.
        let started = await fixture.controller.playCollection(
            PlaybackCollection(kind: .searchSong, catalogID: "alb-1", title: "Album Song 1"),
            songs: [PlaybackCollectionSong(catalogID: "alb-1", title: "Album Song 1", artistName: "Artist 0")],
            startingAt: "alb-1", recordsRecent: false, context: fixture.context
        )
        #expect(started)
        #expect(fixture.controller.currentTrack?.title == "Album Song 1")
        #expect(try fixture.item(0).skipCount == 0)
    }

    @Test func endingASongAfterALongPauseIsNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        await pause(fixture, for: PlaybackController.longPauseSeconds + 1)
        await fixture.listen(seconds: 5)
        await fixture.player.externallyAdvance()
        #expect(try fixture.item(0).skipCount == 0)
    }

    @Test func aShortPauseStillCountsTheSkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        await pause(fixture, for: PlaybackController.longPauseSeconds - 30)
        await fixture.listen(seconds: 5)
        await fixture.player.externallyAdvance()
        #expect(try fixture.item(0).skipCount == 1)
    }

    @Test func aLongPauseIsOneMinute() {
        #expect(PlaybackController.longPauseSeconds == 60)
    }
}
