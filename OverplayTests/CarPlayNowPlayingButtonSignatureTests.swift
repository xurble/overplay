import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("CarPlay now playing button signature", .serialized)
struct CarPlayNowPlayingButtonSignatureTests {
    @Test func unresolvedTrackRetainsLayoutOnlyWithinItsPlaylist() {
        let known = CarPlayNowPlayingButtonSignature(hasCurrentTrack: true, playlistRole: .triageBucket, isEvicted: true)
        let unresolved = CarPlayNowPlayingButtonSignature(hasCurrentTrack: true, playlistRole: nil, isEvicted: false)
        #expect(unresolved.resolvingLayout(previous: known, samePlaylist: true) == known)
        #expect(unresolved.resolvingLayout(previous: known, samePlaylist: false) == unresolved)
        let resolved = CarPlayNowPlayingButtonSignature(hasCurrentTrack: true, playlistRole: .oneTruePlaylist, isEvicted: false)
        #expect(resolved.resolvingLayout(previous: known, samePlaylist: true) == resolved)
    }

    @Test("changes when retired presentation state changes")
    func changesWithRetiredPresentation() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        let active = CarPlayNowPlayingButtonSignature.make(playbackController: fixture.controller, context: fixture.context)
        let activeBadge = NowPlayingPresentationFactory.trackStateBadgePresentation(
            playbackController: fixture.controller, settings: fixture.settings, context: fixture.context
        )
        #expect(activeBadge.title == "Active")
        #expect(!active.isEvicted)

        try fixture.item(0).evictedAt = Date.now
        fixture.controller.reconcileTrackMembership(context: fixture.context)
        let evicted = CarPlayNowPlayingButtonSignature.make(playbackController: fixture.controller, context: fixture.context)
        let evictedBadge = NowPlayingPresentationFactory.trackStateBadgePresentation(
            playbackController: fixture.controller, settings: fixture.settings, context: fixture.context
        )
        #expect(evicted.isEvicted)
        #expect(evictedBadge.title == "Retired")
        #expect(evicted != active)
    }

    @Test("factory reflects triage playlist role for direct CarPlay actions")
    func factoryReflectsTriagePlaylistRoleForDirectCarPlayActions() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket)
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        let signature = CarPlayNowPlayingButtonSignature.make(playbackController: fixture.controller, context: fixture.context)
        #expect(signature.playlistRole == .triageBucket)
    }

    @Test("changes when the current playlist role changes")
    func changesWithCurrentPlaylistRole() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        let main = CarPlayNowPlayingButtonSignature.make(playbackController: fixture.controller, context: fixture.context)
        fixture.playlist.role = .triageSource
        try fixture.context.save()
        let source = CarPlayNowPlayingButtonSignature.make(playbackController: fixture.controller, context: fixture.context)
        #expect(main.playlistRole == .oneTruePlaylist)
        #expect(source.playlistRole == .triageSource)
        #expect(source != main)
    }

    @Test("does not change when only track identity and skip count change")
    func ignoresTrackIdentityAndSkipCount() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        let first = CarPlayNowPlayingButtonSignature.make(playbackController: fixture.controller, context: fixture.context)
        await fixture.listen(seconds: 20)
        await fixture.player.externallyAdvance()
        let second = CarPlayNowPlayingButtonSignature.make(playbackController: fixture.controller, context: fixture.context)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(second == first)
    }

    @Test("changes when track availability changes")
    func changesWithTrackAvailability() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let empty = CarPlayNowPlayingButtonSignature.make(playbackController: fixture.controller, context: fixture.context)
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        let playing = CarPlayNowPlayingButtonSignature.make(playbackController: fixture.controller, context: fixture.context)
        #expect(!empty.hasCurrentTrack)
        #expect(playing.hasCurrentTrack)
        #expect(playing != empty)
    }
}
