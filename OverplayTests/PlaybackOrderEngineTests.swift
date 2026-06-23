import Foundation
import Testing
@testable import Overplay

@Suite("Playback order engine")
struct PlaybackOrderEngineTests {
    @Test("reshuffle keeps avoided track out of the top five")
    func reshuffleKeepsAvoidedTrackOutOfTopFive() {
        let tracks = makeTracks(count: 8)

        let order = PlaybackOrderEngine.reshuffledOrder(
            for: tracks,
            avoiding: "track-3",
            randomize: { $0 }
        )

        #expect(order.firstIndex(of: "track-3") == 5)
    }

    @Test("small reshuffle keeps avoided track away from first")
    func smallReshuffleKeepsAvoidedTrackAwayFromFirst() {
        let tracks = makeTracks(count: 5)

        let order = PlaybackOrderEngine.reshuffledOrder(
            for: tracks,
            avoiding: "track-3",
            randomize: { $0 }
        )

        #expect(order.last == "track-3")
    }

    @Test("normal order seeds from creation date")
    func normalOrderSeedsFromCreationDate() {
        let tracks = [
            PlaybackOrderTrack(id: "third", createdAt: Date(timeIntervalSince1970: 30)),
            PlaybackOrderTrack(id: "first", createdAt: Date(timeIntervalSince1970: 10)),
            PlaybackOrderTrack(id: "second", createdAt: Date(timeIntervalSince1970: 20))
        ]

        #expect(PlaybackOrderEngine.normalOrder(for: tracks) == ["first", "second", "third"])
    }

    @Test("one-track reshuffle keeps the only track")
    func oneTrackReshuffleKeepsOnlyTrack() {
        let tracks = makeTracks(count: 1)

        let order = PlaybackOrderEngine.reshuffledOrder(
            for: tracks,
            avoiding: "track-1",
            randomize: { $0.reversed() }
        )

        #expect(order == ["track-1"])
    }

    @Test("two-track reshuffle keeps avoided track second")
    func twoTrackReshuffleKeepsAvoidedTrackSecond() {
        let tracks = makeTracks(count: 2)

        let order = PlaybackOrderEngine.reshuffledOrder(
            for: tracks,
            avoiding: "track-2",
            randomize: { $0.reversed() }
        )

        #expect(order == ["track-1", "track-2"])
    }

    @Test("reconcile appends synced in tracks")
    func reconcileAppendsSyncedInTracks() {
        let tracks = makeTracks(count: 4)

        let order = PlaybackOrderEngine.reconciledOrder(
            storedOrder: ["track-2", "track-1"],
            tracks: tracks,
            includeUnplayableTrackID: nil
        )

        #expect(order == ["track-2", "track-1", "track-3", "track-4"])
    }

    @Test("reconcile seeds normal order when stored order is empty")
    func reconcileSeedsNormalOrderWhenStoredOrderIsEmpty() {
        let tracks = makeTracks(count: 4)

        let order = PlaybackOrderEngine.reconciledOrder(
            storedOrder: [],
            tracks: tracks,
            includeUnplayableTrackID: nil
        )

        #expect(order == ["track-1", "track-2", "track-3", "track-4"])
    }

    @Test("reconcile removes unplayable tracks except current")
    func reconcileRemovesUnplayableTracksExceptCurrent() {
        var tracks = makeTracks(count: 4)
        tracks[1] = PlaybackOrderTrack(
            id: "track-2",
            createdAt: Date(timeIntervalSince1970: 1),
            isPlayable: false
        )

        let keptCurrent = PlaybackOrderEngine.reconciledOrder(
            storedOrder: ["track-2", "track-3", "track-1", "track-4"],
            tracks: tracks,
            includeUnplayableTrackID: "track-2"
        )
        let droppedAfterTransition = PlaybackOrderEngine.reconciledOrder(
            storedOrder: keptCurrent,
            tracks: tracks,
            includeUnplayableTrackID: "track-3"
        )

        #expect(keptCurrent == ["track-2", "track-3", "track-1", "track-4"])
        #expect(droppedAfterTransition == ["track-3", "track-1", "track-4"])
    }

    @Test("adjacent available ID uses ordered local IDs without falling back to the head")
    func adjacentAvailableIDUsesOrderedLocalIDs() {
        let orderedIDs = ["track-1", "track-2", "track-3", "track-4"]
        let availableIDs = Set(["track-1", "track-4"])

        #expect(PlaybackOrderEngine.adjacentAvailableID(
            to: "track-2",
            in: orderedIDs,
            availableIDs: availableIDs,
            movingForward: true
        ) == "track-4")
        #expect(PlaybackOrderEngine.adjacentAvailableID(
            to: "missing",
            in: orderedIDs,
            availableIDs: availableIDs,
            movingForward: true
        ) == nil)
        #expect(PlaybackOrderEngine.adjacentAvailableID(
            to: "track-2",
            in: orderedIDs,
            availableIDs: availableIDs,
            movingForward: false
        ) == "track-1")
    }

    private func makeTracks(count: Int) -> [PlaybackOrderTrack] {
        (1...count).map { index in
            PlaybackOrderTrack(
                id: "track-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }
}
