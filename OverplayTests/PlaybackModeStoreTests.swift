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

    @MainActor
    @Test("moving tracks between active and retired scopes appends to destination")
    func movingTracksBetweenActiveAndRetiredScopesAppendsToDestination() throws {
        let suiteName = "OverplayTests.PlaybackOrderStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let playlistID = UUID()
        let activeFirstTrackID = UUID()
        let activeSecondTrackID = UUID()
        let changedTrackID = UUID()
        let retiredTrackID = UUID()
        let changedItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: changedTrackID,
            evictedAt: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let items = [
            PlaylistItemRecord(
                playlistID: playlistID,
                trackID: activeFirstTrackID,
                createdAt: Date(timeIntervalSince1970: 10)
            ),
            PlaylistItemRecord(
                playlistID: playlistID,
                trackID: activeSecondTrackID,
                createdAt: Date(timeIntervalSince1970: 20)
            ),
            changedItem,
            PlaylistItemRecord(
                playlistID: playlistID,
                trackID: retiredTrackID,
                evictedAt: Date(timeIntervalSince1970: 90),
                createdAt: Date(timeIntervalSince1970: 5)
            )
        ]
        let activeFirstID = activeFirstTrackID.uuidString
        let activeSecondID = activeSecondTrackID.uuidString
        let changedID = changedTrackID.uuidString
        let retiredID = retiredTrackID.uuidString
        let playlistMusicID = "playlist-1"
        let retiredPlaylistMusicID = PlaylistPlaybackScope.retired.playbackOrderPlaylistID(for: playlistMusicID)

        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: "main",
                musicPlaylistID: playlistMusicID,
                orderedTrackIDs: [changedID, activeSecondID, activeFirstID]
            ),
            to: defaults
        )

        PlaybackOrderCoordinator.moveTrackIDToBottom(
            changedID,
            playerID: "main",
            playlistID: playlistMusicID,
            items: items,
            targetScope: .retired,
            defaults: defaults
        )

        #expect(PlaybackOrderStore.state(playerID: "main", musicPlaylistID: playlistMusicID, from: defaults).orderedTrackIDs == [
            activeSecondID,
            activeFirstID
        ])
        #expect(PlaybackOrderStore.state(playerID: "main", musicPlaylistID: retiredPlaylistMusicID, from: defaults).orderedTrackIDs == [
            retiredID,
            changedID
        ])

        changedItem.evictedAt = nil
        PlaybackOrderCoordinator.moveTrackIDToBottom(
            changedID,
            playerID: "main",
            playlistID: playlistMusicID,
            items: items,
            targetScope: .active,
            defaults: defaults
        )

        #expect(PlaybackOrderStore.state(playerID: "main", musicPlaylistID: playlistMusicID, from: defaults).orderedTrackIDs == [
            activeSecondID,
            activeFirstID,
            changedID
        ])
        #expect(PlaybackOrderStore.state(playerID: "main", musicPlaylistID: retiredPlaylistMusicID, from: defaults).orderedTrackIDs == [
            retiredID
        ])
    }

    @MainActor
    @Test("playback order state reconciles and persists selected scope order")
    func playbackOrderStateReconcilesAndPersistsSelectedScopeOrder() {
        let playerID = "test-\(UUID().uuidString)"
        let playlistMusicID = "playlist-\(UUID().uuidString)"
        let retiredPlaylistMusicID = PlaylistPlaybackScope.retired.playbackOrderPlaylistID(for: playlistMusicID)
        let controller = PlaybackController(playerID: playerID)
        let playlistID = UUID()
        let firstTrackID = UUID()
        let secondTrackID = UUID()
        let items = [
            PlaylistItemRecord(
                playlistID: playlistID,
                trackID: firstTrackID,
                evictedAt: Date(timeIntervalSince1970: 100),
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            PlaylistItemRecord(
                playlistID: playlistID,
                trackID: secondTrackID,
                evictedAt: Date(timeIntervalSince1970: 200),
                createdAt: Date(timeIntervalSince1970: 2)
            )
        ]
        defer {
            PlaybackOrderStore.clear(playerID: playerID, musicPlaylistID: retiredPlaylistMusicID)
        }

        let state = controller.playbackOrderState(
            for: playlistMusicID,
            scope: .retired,
            items: items
        )

        #expect(state.orderedTrackIDs == [
            firstTrackID.uuidString,
            secondTrackID.uuidString
        ])
        #expect(PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: retiredPlaylistMusicID).orderedTrackIDs == state.orderedTrackIDs)
    }
}
