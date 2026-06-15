import MediaPlayer
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Remote command service")
struct RemoteCommandServiceTests {
    @Test("activate update and deactivate manage lifecycle state")
    func activateUpdateAndDeactivateManageLifecycleState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let firstContext = ModelContext(container)
        let secondContext = ModelContext(container)
        let playbackController = PlaybackController()
        let service = RemoteCommandService()

        service.activate(playbackController: playbackController, context: firstContext)
        let initialTargetCount = service.registeredTargetCount

        #expect(service.isActive)
        #expect(initialTargetCount == 7)
        #expect(service.context === firstContext)

        service.update(playbackController: playbackController, context: secondContext)

        #expect(service.isActive)
        #expect(service.registeredTargetCount == initialTargetCount)
        #expect(service.context === secondContext)

        service.deactivate()

        #expect(!service.isActive)
        #expect(service.registeredTargetCount == 0)
        #expect(service.context == nil)
        #expect(service.playbackController == nil)
    }

    @Test("repeated activation updates context without duplicate remote targets")
    func repeatedActivationUpdatesContextWithoutDuplicateRemoteTargets() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let firstContext = ModelContext(container)
        let carPlayContext = ModelContext(container)
        let playbackController = PlaybackController()
        let service = RemoteCommandService()

        service.activate(playbackController: playbackController, context: firstContext)
        let initialTargetCount = service.registeredTargetCount

        service.activate(playbackController: playbackController, context: carPlayContext)

        #expect(service.isActive)
        #expect(service.registeredTargetCount == initialTargetCount)
        #expect(service.context === carPlayContext)

        service.deactivate()
    }

    @Test("sync publishes Overplay playback modes to remote command center")
    func syncPublishesOverplayPlaybackModesToRemoteCommandCenter() throws {
        let playlistID = "playlist-\(UUID().uuidString)"
        let playerID = "player-\(UUID().uuidString)"
        let playbackController = PlaybackController(playerID: playerID)
        let service = RemoteCommandService()
        let commandCenter = MPRemoteCommandCenter.shared()
        defer {
            PlaybackModeStore.clear(playerID: playerID, musicPlaylistID: playlistID, flushImmediately: true)
            commandCenter.changeShuffleModeCommand.currentShuffleType = .off
            commandCenter.changeRepeatModeCommand.currentRepeatType = .off
        }

        playbackController.currentPlaylistID = playlistID
        PlaybackModeStore.save(
            PlaybackModeState(
                playerID: playerID,
                musicPlaylistID: playlistID,
                shuffleEnabled: true,
                repeatEnabled: true
            ),
            flushImmediately: true
        )

        service.syncPlaybackModes(from: playbackController)

        #expect(commandCenter.changeShuffleModeCommand.currentShuffleType == .items)
        #expect(commandCenter.changeRepeatModeCommand.currentRepeatType == .all)
    }

    @Test("repeat one remote command collapses to unsupported off state")
    func repeatOneRemoteCommandCollapsesToUnsupportedOffState() throws {
        let playlistID = "playlist-\(UUID().uuidString)"
        let playerID = "player-\(UUID().uuidString)"
        let playbackController = PlaybackController(playerID: playerID)
        let service = RemoteCommandService()
        let commandCenter = MPRemoteCommandCenter.shared()
        defer {
            PlaybackModeStore.clear(playerID: playerID, musicPlaylistID: playlistID, flushImmediately: true)
            commandCenter.changeShuffleModeCommand.currentShuffleType = .off
            commandCenter.changeRepeatModeCommand.currentRepeatType = .off
        }

        playbackController.currentPlaylistID = playlistID
        PlaybackModeStore.save(
            PlaybackModeState(
                playerID: playerID,
                musicPlaylistID: playlistID,
                repeatEnabled: true
            ),
            flushImmediately: true
        )

        let result = service.applyRepeatModeCommand(
            .one,
            source: "Test",
            playbackController: playbackController
        )

        #expect(result == .success)
        #expect(!playbackController.repeatEnabled)
        #expect(commandCenter.changeRepeatModeCommand.currentRepeatType == .off)
    }
}
