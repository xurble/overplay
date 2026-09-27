import MediaPlayer
import MusicKit
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Remote command service", .serialized)
struct RemoteCommandServiceTests {
    @Test("unchanged reconciliations do not write any remote-command properties")
    func unchangedStateIsNotRepublished() {
        let defaults = PlaybackTestDefaults()
        defer { defaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: defaults.defaults)
        var writes: [RemoteCommandPublication] = []
        let service = RemoteCommandService(publish: { writes.append($0) })
        service.syncPlaybackState(from: controller)
        #expect(writes.count == 7)
        #expect(!writes.contains(.shuffle(.off)))
        writes.removeAll()
        for _ in 0..<10 { service.syncPlaybackState(from: controller) }
        #expect(writes.isEmpty)
        controller.currentPlaylistID = "restorable"
        controller.currentTrack = CurrentPlaybackTrack(id: "track", title: "Track", artistName: "Artist")
        service.syncPlaybackState(from: controller)
        #expect(writes == [.availability(.play, true), .availability(.toggle, true)])
        writes.removeAll()
        controller.currentTrack?.playthroughCount += 1
        controller.elapsedSeconds = 20
        service.syncPlaybackState(from: controller)
        #expect(writes.isEmpty)
    }

    @Test("reconnection republishes availability without duplicating command handlers")
    func reconnectionForcesPublication() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let defaults = PlaybackTestDefaults()
        defer { defaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: defaults.defaults)
        var writes: [RemoteCommandPublication] = []
        let service = RemoteCommandService(publish: { writes.append($0) })
        defer { service.deactivate() }
        service.activate(playbackController: controller, context: container.mainContext)
        let initial = writes
        #expect(initial.count == 7)
        writes.removeAll()
        service.update(playbackController: controller, context: container.mainContext)
        #expect(writes.isEmpty)
        service.activate(playbackController: controller, context: container.mainContext)
        #expect(writes == initial)
        #expect(service.registeredTargetCount == 7)
    }

    @Test("a paused queue the player is holding keeps its remote commands")
    func pausedHeldQueueKeepsItsRemoteCommands() {
        // The exact case the availability guard used to drop: the player is
        // holding a queue, Overplay has lost correlation so it has nothing
        // restorable to describe, and nothing is playing. Next, Previous,
        // shuffle and repeat were disabled on the Lock Screen, Control
        // Center, CarPlay and AirPods for a queue that could still be
        // resumed and skipped.
        #expect(PlaybackRemoteCommandAvailability.make(
            canSkipTracks: true,
            hasRestorablePlayback: false,
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

        // Mode commands can be deferred while transport confirmation is pending.
        #expect(PlaybackRemoteCommandAvailability.make(
            canSkipTracks: true,
            hasRestorablePlayback: false,
            isPlaying: false,
            isTransitionInFlight: true,
            isDeliveryStalled: false
        ).canShuffle)
    }

    @Test("availability follows queue, playback, transition, restore, and delivery state")
    func availabilityFollowsAuthoritativePlaybackState() {
        #expect(PlaybackRemoteCommandAvailability.make(
            canSkipTracks: false,
            hasRestorablePlayback: false,
            isPlaying: false,
            isTransitionInFlight: false,
            isDeliveryStalled: false
        ) == .unavailable)

        #expect(PlaybackRemoteCommandAvailability.make(
            canSkipTracks: true,
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
            canSkipTracks: true,
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
            canSkipTracks: false,
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
            canSkipTracks: true,
            hasRestorablePlayback: true,
            isPlaying: true,
            isTransitionInFlight: true,
            isDeliveryStalled: false
        ).canShuffle)

        let deliveryFailure = PlaybackRemoteCommandAvailability.make(
            canSkipTracks: true,
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
            canSkipTracks: false,
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
            canSkipTracks: false,
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
            canSkipTracks: false,
            hasRestorablePlayback: false,
            isPlaying: false,
            isTransitionInFlight: false,
            isDeliveryStalled: false
        ) == .unavailable)
    }

    @Test("pause remains available during a transition")
    func pauseRemainsAvailableDuringTransition() {
        #expect(PlaybackRemoteCommandAvailability.make(
            canSkipTracks: false,
            hasRestorablePlayback: false,
            isPlaying: true,
            isTransitionInFlight: true,
            isDeliveryStalled: false
        ).canPause)
    }

    @Test("activate update and deactivate manage lifecycle state")
    func activateUpdateAndDeactivateManageLifecycleState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let firstContext = ModelContext(container)
        let secondContext = ModelContext(container)
        let playbackDefaults = PlaybackTestDefaults()
        defer { playbackDefaults.cleanUp() }
        let playbackController = PlaybackController(localPlaybackDefaults: playbackDefaults.defaults)
        let service = RemoteCommandService()

        service.activate(playbackController: playbackController, context: firstContext)
        let initialTargetCount = service.registeredTargetCount

        #expect(service.isActive)
        // Shuffle and repeat are both real commands under PLAY-004.
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
        let playbackDefaults = PlaybackTestDefaults()
        defer { playbackDefaults.cleanUp() }
        let playbackController = PlaybackController(localPlaybackDefaults: playbackDefaults.defaults)
        let service = RemoteCommandService()

        service.activate(playbackController: playbackController, context: firstContext)
        let initialTargetCount = service.registeredTargetCount

        service.activate(playbackController: playbackController, context: carPlayContext)

        #expect(service.isActive)
        #expect(service.registeredTargetCount == initialTargetCount)
        #expect(service.context === carPlayContext)

        service.deactivate()
    }

    @Test("unknown initial modes preserve the command center's existing values")
    func unknownModesDoNotPublishDefaults() {
        let defaults = PlaybackTestDefaults()
        defer { defaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: defaults.defaults)
        let service = RemoteCommandService()
        let center = MPRemoteCommandCenter.shared()
        let previousShuffle = center.changeShuffleModeCommand.currentShuffleType
        let previousRepeat = center.changeRepeatModeCommand.currentRepeatType
        defer {
            center.changeShuffleModeCommand.currentShuffleType = previousShuffle
            center.changeRepeatModeCommand.currentRepeatType = previousRepeat
        }
        center.changeShuffleModeCommand.currentShuffleType = .items
        center.changeRepeatModeCommand.currentRepeatType = .all
        service.syncPlaybackModes(from: controller)
        #expect(center.changeShuffleModeCommand.currentShuffleType == .items)
        #expect(center.changeRepeatModeCommand.currentRepeatType == .all)
    }

    @Test("activation disables repeat until there is a live queue")
    func activationDisablesRepeatWithoutAQueue() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)
        let playbackDefaults = PlaybackTestDefaults()
        defer { playbackDefaults.cleanUp() }
        let playbackController = PlaybackController(localPlaybackDefaults: playbackDefaults.defaults)
        let service = RemoteCommandService()
        let commandCenter = MPRemoteCommandCenter.shared()
        defer {
            service.deactivate()
        }

        service.activate(playbackController: playbackController, context: context)

        // Mode commands require a live queue; retained display state is insufficient.
        #expect(!commandCenter.changeRepeatModeCommand.isEnabled)
    }

    @Test("command center disables empty state, permits display restore, and disables after reset")
    func commandCenterTracksControllerState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)
        let playbackDefaults = PlaybackTestDefaults()
        defer { playbackDefaults.cleanUp() }
        let playbackController = PlaybackController(localPlaybackDefaults: playbackDefaults.defaults)
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
