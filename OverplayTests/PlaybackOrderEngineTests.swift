import Foundation
import Testing
@testable import Overplay

@Suite("Playback order engine")
struct PlaybackOrderEngineTests {
    @Test("shuffle promotes the current track and shuffles the rest")
    func shufflePromotesCurrentTrack() {
        let tracks = makeTracks(count: 5)

        let order = PlaybackOrderEngine.shuffleOrder(
            for: tracks,
            currentTrackID: "track-3",
            randomize: { $0.reversed() }
        )

        #expect(order == ["track-3", "track-5", "track-4", "track-2", "track-1"])
    }

    @Test("normal order restores playlist position")
    func normalOrderRestoresPlaylistPosition() {
        let tracks = [
            PlaybackOrderTrack(id: "third", sortOrder: 2, createdAt: Date(timeIntervalSince1970: 30)),
            PlaybackOrderTrack(id: "first", sortOrder: 0, createdAt: Date(timeIntervalSince1970: 10)),
            PlaybackOrderTrack(id: "second", sortOrder: 1, createdAt: Date(timeIntervalSince1970: 20))
        ]

        #expect(PlaybackOrderEngine.normalOrder(for: tracks) == ["first", "second", "third"])
    }

    @Test("tiny playlists keep normal order when shuffle is enabled")
    func tinyPlaylistsKeepNormalOrder() {
        let tracks = makeTracks(count: 2)

        let order = PlaybackOrderEngine.shuffleOrder(
            for: tracks,
            currentTrackID: "track-2",
            randomize: { $0.reversed() }
        )

        #expect(order == ["track-1", "track-2"])
    }

    @Test("reconcile appends synced in tracks")
    func reconcileAppendsSyncedInTracks() {
        let tracks = makeTracks(count: 4)

        let order = PlaybackOrderEngine.reconciledShuffleOrder(
            storedOrder: ["track-2", "track-1"],
            tracks: tracks,
            currentTrackID: nil
        )

        #expect(order == ["track-2", "track-1", "track-3", "track-4"])
    }

    @Test("reconcile removes unplayable tracks except current")
    func reconcileRemovesUnplayableTracksExceptCurrent() {
        var tracks = makeTracks(count: 4)
        tracks[1] = PlaybackOrderTrack(
            id: "track-2",
            sortOrder: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            isPlayable: false
        )

        let keptCurrent = PlaybackOrderEngine.reconciledShuffleOrder(
            storedOrder: ["track-2", "track-3", "track-1", "track-4"],
            tracks: tracks,
            currentTrackID: "track-2"
        )
        let droppedAfterTransition = PlaybackOrderEngine.reconciledShuffleOrder(
            storedOrder: keptCurrent,
            tracks: tracks,
            currentTrackID: "track-3"
        )

        #expect(keptCurrent == ["track-2", "track-3", "track-1", "track-4"])
        #expect(droppedAfterTransition == ["track-3", "track-1", "track-4"])
    }

    @Test("repeat shuffle keeps last played out of top five")
    func repeatShuffleKeepsLastPlayedOutOfTopFive() {
        let tracks = makeTracks(count: 8)

        let order = PlaybackOrderEngine.repeatShuffleOrder(
            for: tracks,
            lastPlayedTrackID: "track-3",
            randomize: { $0 }
        )

        #expect(order.firstIndex(of: "track-3") == 5)
    }

    @Test("repeat shuffle keeps last played last for five or fewer tracks")
    func repeatShuffleKeepsLastPlayedLastForSmallLists() {
        let tracks = makeTracks(count: 5)

        let order = PlaybackOrderEngine.repeatShuffleOrder(
            for: tracks,
            lastPlayedTrackID: "track-2",
            randomize: { $0 }
        )

        #expect(order.last == "track-2")
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
                sortOrder: index,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }
}
