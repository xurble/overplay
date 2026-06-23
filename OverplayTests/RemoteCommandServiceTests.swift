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
        #expect(initialTargetCount == 6)
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

    @Test("sync publishes shuffle off and repeat all to remote command center")
    func syncPublishesPlaybackModesToRemoteCommandCenter() throws {
        let playlistID = "playlist-\(UUID().uuidString)"
        let playerID = "player-\(UUID().uuidString)"
        let playbackController = PlaybackController(playerID: playerID)
        let service = RemoteCommandService()
        let commandCenter = MPRemoteCommandCenter.shared()
        defer {
            PlaybackOrderStore.clear(playerID: playerID, musicPlaylistID: playlistID, flushImmediately: true)
            commandCenter.changeShuffleModeCommand.currentShuffleType = .off
            commandCenter.changeRepeatModeCommand.currentRepeatType = .off
        }

        playbackController.currentPlaylistID = playlistID
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: playerID,
                musicPlaylistID: playlistID
            ),
            flushImmediately: true
        )

        service.syncPlaybackModes(from: playbackController)

        #expect(commandCenter.changeShuffleModeCommand.currentShuffleType == .off)
        #expect(commandCenter.changeRepeatModeCommand.currentRepeatType == .all)
    }

    @Test("activation disables repeat command")
    func activationDisablesRepeatCommand() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)
        let playbackController = PlaybackController()
        let service = RemoteCommandService()
        let commandCenter = MPRemoteCommandCenter.shared()
        defer {
            service.deactivate()
        }

        service.activate(playbackController: playbackController, context: context)

        #expect(!commandCenter.changeRepeatModeCommand.isEnabled)
        #expect(commandCenter.changeRepeatModeCommand.currentRepeatType == .all)
    }
}
