import MediaPlayer
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Remote command service", .serialized)
struct RemoteCommandServiceTests {
    @Test("availability follows queue, playback, transition, restore, and delivery state")
    func availabilityFollowsAuthoritativePlaybackState() {
        #expect(PlaybackRemoteCommandAvailability.make(
            canControlPlayback: false,
            hasRestorablePlayback: false,
            isPlaying: false,
            isTransitionInFlight: false,
            isDeliveryStalled: false
        ) == .unavailable)

        #expect(PlaybackRemoteCommandAvailability.make(
            canControlPlayback: true,
            hasRestorablePlayback: true,
            isPlaying: true,
            isTransitionInFlight: false,
            isDeliveryStalled: false
        ) == PlaybackRemoteCommandAvailability(
            canPlay: false,
            canPause: true,
            canTogglePlayPause: true,
            canSkipToNext: true,
            canSkipToPrevious: true,
            canShuffle: true
        ))

        #expect(PlaybackRemoteCommandAvailability.make(
            canControlPlayback: true,
            hasRestorablePlayback: true,
            isPlaying: false,
            isTransitionInFlight: false,
            isDeliveryStalled: false
        ) == PlaybackRemoteCommandAvailability(
            canPlay: true,
            canPause: false,
            canTogglePlayPause: true,
            canSkipToNext: true,
            canSkipToPrevious: true,
            canShuffle: true
        ))

        let restoredDisplay = PlaybackRemoteCommandAvailability.make(
            canControlPlayback: false,
            hasRestorablePlayback: true,
            isPlaying: false,
            isTransitionInFlight: false,
            isDeliveryStalled: false
        )
        #expect(restoredDisplay.canPlay)
        #expect(restoredDisplay.canTogglePlayPause)
        #expect(!restoredDisplay.canPause)
        #expect(!restoredDisplay.canSkipToNext)
        #expect(!restoredDisplay.canSkipToPrevious)
        #expect(!restoredDisplay.canShuffle)

        #expect(PlaybackRemoteCommandAvailability.make(
            canControlPlayback: true,
            hasRestorablePlayback: true,
            isPlaying: true,
            isTransitionInFlight: true,
            isDeliveryStalled: false
        ) == .unavailable)

        let deliveryFailure = PlaybackRemoteCommandAvailability.make(
            canControlPlayback: true,
            hasRestorablePlayback: true,
            isPlaying: true,
            isTransitionInFlight: false,
            isDeliveryStalled: true
        )
        #expect(deliveryFailure.canPlay)
        #expect(!deliveryFailure.canPause)
        #expect(deliveryFailure.canSkipToNext)
        #expect(deliveryFailure.canSkipToPrevious)
    }

    @Test("pause stays available when playback is running but correlation is lost")
    func pauseStaysAvailableWhenPlaybackIsRunningButCorrelationIsLost() {
        // Regression: an un-hydrated player entry used to clear playlist and
        // track state, which made this exact combination return .unavailable
        // and disabled pause on the Lock Screen, Control Center, CarPlay and
        // AirPods at once while audio kept playing.
        let lostCorrelation = PlaybackRemoteCommandAvailability.make(
            canControlPlayback: false,
            hasRestorablePlayback: false,
            isPlaying: true,
            isTransitionInFlight: false,
            isDeliveryStalled: false
        )

        #expect(lostCorrelation != .unavailable)
        #expect(lostCorrelation.canPause)
        #expect(lostCorrelation.canTogglePlayPause)
        #expect(!lostCorrelation.canPlay)
        // Queue-dependent commands still need correlation.
        #expect(!lostCorrelation.canSkipToNext)
        #expect(!lostCorrelation.canSkipToPrevious)
        #expect(!lostCorrelation.canShuffle)
    }

    @Test("pause is available with correlation lost but restorable playback known")
    func pauseIsAvailableWithCorrelationLostButRestorablePlaybackKnown() {
        let availability = PlaybackRemoteCommandAvailability.make(
            canControlPlayback: false,
            hasRestorablePlayback: true,
            isPlaying: true,
            isTransitionInFlight: false,
            isDeliveryStalled: false
        )

        #expect(availability.canPause)
    }

    @Test("nothing is offered while nothing is playing and nothing is restorable")
    func nothingIsOfferedWhileNothingIsPlayingAndNothingIsRestorable() {
        #expect(PlaybackRemoteCommandAvailability.make(
            canControlPlayback: false,
            hasRestorablePlayback: false,
            isPlaying: false,
            isTransitionInFlight: false,
            isDeliveryStalled: false
        ) == .unavailable)
    }

    @Test("a transition in flight still suppresses everything")
    func aTransitionInFlightStillSuppressesEverything() {
        #expect(PlaybackRemoteCommandAvailability.make(
            canControlPlayback: false,
            hasRestorablePlayback: false,
            isPlaying: true,
            isTransitionInFlight: true,
            isDeliveryStalled: false
        ) == .unavailable)
    }

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

    @Test("command center disables empty state, permits display restore, and disables after reset")
    func commandCenterTracksControllerState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)
        let playbackController = PlaybackController()
        let service = RemoteCommandService()
        let commandCenter = MPRemoteCommandCenter.shared()
        defer { service.deactivate() }

        service.activate(playbackController: playbackController, context: context)

        #expect(!commandCenter.playCommand.isEnabled)
        #expect(!commandCenter.pauseCommand.isEnabled)
        #expect(!commandCenter.togglePlayPauseCommand.isEnabled)
        #expect(!commandCenter.nextTrackCommand.isEnabled)
        #expect(!commandCenter.previousTrackCommand.isEnabled)
        #expect(!commandCenter.changeShuffleModeCommand.isEnabled)

        playbackController.currentPlaylistID = "restored-playlist"
        playbackController.currentTrack = CurrentPlaybackTrack(
            id: "restored-track",
            title: "Restored",
            artistName: "Artist"
        )
        service.syncPlaybackState(from: playbackController)

        #expect(commandCenter.playCommand.isEnabled)
        #expect(commandCenter.togglePlayPauseCommand.isEnabled)
        #expect(!commandCenter.pauseCommand.isEnabled)
        #expect(!commandCenter.nextTrackCommand.isEnabled)
        #expect(!commandCenter.previousTrackCommand.isEnabled)
        #expect(!commandCenter.changeShuffleModeCommand.isEnabled)

        playbackController.clearLocalStateAfterDatabaseReset()
        service.syncPlaybackState(from: playbackController)

        #expect(!commandCenter.playCommand.isEnabled)
        #expect(!commandCenter.togglePlayPauseCommand.isEnabled)
        #expect(!commandCenter.nextTrackCommand.isEnabled)
    }
}
