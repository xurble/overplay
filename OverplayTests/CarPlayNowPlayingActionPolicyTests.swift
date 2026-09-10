import Foundation
import Testing
@testable import Overplay

@Suite("CarPlay Now Playing actions")
struct CarPlayNowPlayingActionPolicyTests {
    @Test("a triage track offers promote and retire")
    func triageOffersPromoteAndRetire() {
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .triageBucket, isRetired: false)
            == [.shuffle, .repeatMode, .promote, .retire])
    }

    @Test("a retired triage track still offers promote")
    func retiredTriageStillOffersPromote() {
        // Retirement in triage is local and reversible, and this is the case
        // where promote used to disappear.
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .triageBucket, isRetired: true)
            == [.shuffle, .repeatMode, .promote, .restore])
    }

    @Test("active OTP offers retirement and retired songs offer both destinations")
    func retiredTracksOfferBothDestinations() {
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .oneTruePlaylist, isRetired: false)
            == [.shuffle, .repeatMode, .retire])
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .oneTruePlaylist, isRetired: true)
            == [.shuffle, .repeatMode, .promote, .restore])
    }

    @Test("with no known playlist the playback modes are still offered")
    func noKnownPlaylistStillOffersModes() {
        // The modes apply to whatever plays next, and there is no track to act
        // on, so offering them alone is the honest set.
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: nil, isRetired: false)
            == [.shuffle, .repeatMode])
    }

    @Test("shuffle and repeat come first in every state")
    func shuffleAndRepeatComeFirst() {
        for role in [PlaylistRole.triageBucket, .oneTruePlaylist] {
            for isRetired in [true, false] {
                let actions = CarPlayNowPlayingActionPolicy.actions(playlistRole: role, isRetired: isRetired)
                #expect(actions.prefix(2) == [.shuffle, .repeatMode])
            }
        }
    }

    @Test("promote is offered for every triage state")
    func promoteIsOfferedForEveryTriageState() {
        for isRetired in [true, false] {
            #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .triageBucket, isRetired: isRetired)
                .contains(.promote))
        }
    }
}
