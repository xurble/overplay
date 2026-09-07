import Foundation
import Testing
@testable import Overplay

@Suite("CarPlay Now Playing actions")
struct CarPlayNowPlayingActionPolicyTests {
    @Test("a triage track offers promote and retire")
    func triageOffersPromoteAndRetire() {
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .triage, isRetired: false)
            == [.promote, .retire])
    }

    @Test("a retired triage track still offers promote")
    func retiredTriageStillOffersPromote() {
        // Retirement in triage is local and reversible, and this is the case
        // where promote used to disappear.
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .triage, isRetired: true)
            == [.promote, .restore])
    }

    @Test("the One True Playlist never offers promote")
    func oneTruePlaylistNeverOffersPromote() {
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .oneTruePlaylist, isRetired: false)
            == [.retire])
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .oneTruePlaylist, isRetired: true)
            == [.restore])
    }

    @Test("no known playlist offers nothing")
    func noKnownPlaylistOffersNothing() {
        #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: nil, isRetired: false).isEmpty)
    }

    @Test("promote is offered for every triage state")
    func promoteIsOfferedForEveryTriageState() {
        for isRetired in [true, false] {
            #expect(CarPlayNowPlayingActionPolicy.actions(playlistRole: .triage, isRetired: isRetired)
                .contains(.promote))
        }
    }
}
