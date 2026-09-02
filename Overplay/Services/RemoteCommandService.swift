import Foundation
import MediaPlayer
import Observation
import OSLog
import SwiftData

#if canImport(UIKit)
import UIKit
#endif

struct PlaybackRemoteCommandAvailability: Equatable, Sendable {
    var canPlay: Bool
    var canPause: Bool
    var canTogglePlayPause: Bool
    var canSkipToNext: Bool
    var canSkipToPrevious: Bool
    var canShuffle: Bool

    static let unavailable = PlaybackRemoteCommandAvailability(
        canPlay: false,
        canPause: false,
        canTogglePlayPause: false,
        canSkipToNext: false,
        canSkipToPrevious: false,
        canShuffle: false
    )

    static func make(
        canControlPlayback: Bool,
        hasRestorablePlayback: Bool,
        isPlaying: Bool,
        isTransitionInFlight: Bool,
        isDeliveryStalled: Bool
    ) -> PlaybackRemoteCommandAvailability {
        guard !isTransitionInFlight, hasRestorablePlayback else {
            return .unavailable
        }

        return PlaybackRemoteCommandAvailability(
            canPlay: !isPlaying || isDeliveryStalled,
            canPause: canControlPlayback && isPlaying && !isDeliveryStalled,
            canTogglePlayPause: true,
            canSkipToNext: canControlPlayback,
            canSkipToPrevious: canControlPlayback,
            canShuffle: canControlPlayback
        )
    }
}

@MainActor
final class RemoteCommandService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "RemoteCommands"
    )

    private(set) var isActive = false
    private(set) var playbackController: PlaybackController?
    private(set) var context: ModelContext?
    private var targetTokens = [Any]()
    private var playbackStateObservationGeneration = 0

    var registeredTargetCount: Int {
        targetTokens.count
    }

    func activate(playbackController: PlaybackController, context: ModelContext) {
        update(playbackController: playbackController, context: context)
        guard !isActive else { return }
        isActive = true

        #if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        syncPlaybackState(from: playbackController)

        targetTokens.append(commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
            }
            guard playbackController.remoteCommandAvailability.canPlay else {
                return .noActionableNowPlayingItem
            }
            Task { @MainActor in
                if let settings = try? SettingsRepository.settings(in: context) {
                    await playbackController.playCurrentOrDefault(settings: settings, context: context)
                } else {
                    await playbackController.play(context: context)
                }
            }
            return .success
        })
        targetTokens.append(commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let playbackController = self?.playbackController else {
                return .commandFailed
            }
            guard playbackController.remoteCommandAvailability.canPause else {
                return .noActionableNowPlayingItem
            }
            Task { @MainActor in playbackController.pause() }
            return .success
        })
        targetTokens.append(commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
            }
            guard playbackController.remoteCommandAvailability.canTogglePlayPause else {
                return .noActionableNowPlayingItem
            }
            Task { @MainActor in
                if playbackController.canControlPlayback {
                    await playbackController.togglePlayPause(context: context)
                    return
                }

                if let settings = try? SettingsRepository.settings(in: context) {
                    await playbackController.performPrimaryPlaybackAction(settings: settings, context: context)
                } else {
                    await playbackController.togglePlayPause(context: context)
                }
            }
            return .success
        })
        targetTokens.append(commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
            }
            guard playbackController.remoteCommandAvailability.canSkipToNext else {
                return .noActionableNowPlayingItem
            }
            Task { @MainActor in
                guard let settings = try? SettingsRepository.settings(in: context) else { return }
                let previousTrackID = playbackController.currentTrack?.id
                await playbackController.next(settings: settings, context: context)
                Self.logger.info(
                    "Remote next track command changed track from \(previousTrackID ?? "nil", privacy: .public) to \(playbackController.currentTrack?.id ?? "nil", privacy: .public)"
                )
            }
            return .success
        })
        targetTokens.append(commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
            }
            guard playbackController.remoteCommandAvailability.canSkipToPrevious else {
                return .noActionableNowPlayingItem
            }
            Task { @MainActor in
                let previousTrackID = playbackController.currentTrack?.id
                await playbackController.previous(context: context)
                Self.logger.info(
                    "Remote previous track command changed track from \(previousTrackID ?? "nil", privacy: .public) to \(playbackController.currentTrack?.id ?? "nil", privacy: .public)"
                )
            }
            return .success
        })
        targetTokens.append(commandCenter.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
            }
            guard playbackController.remoteCommandAvailability.canShuffle else {
                self.syncPlaybackState(from: playbackController)
                return .noActionableNowPlayingItem
            }

            let requestedShuffleType = event.shuffleType
            Task { @MainActor in
                _ = await self.applyShuffleModeCommand(
                    requestedShuffleType,
                    source: "MPRemoteCommandCenter",
                    playbackController: playbackController,
                    context: context
                )
            }
            return .success
        })
        startPlaybackStateObservation()
    }

    func update(playbackController: PlaybackController, context: ModelContext) {
        self.playbackController = playbackController
        self.context = context

        if isActive {
            syncPlaybackState(from: playbackController)
            startPlaybackStateObservation()
        }
    }

    func deactivate() {
        stopPlaybackStateObservation()
        let commandCenter = MPRemoteCommandCenter.shared()
        for token in targetTokens {
            commandCenter.playCommand.removeTarget(token)
            commandCenter.pauseCommand.removeTarget(token)
            commandCenter.nextTrackCommand.removeTarget(token)
            commandCenter.previousTrackCommand.removeTarget(token)
            commandCenter.togglePlayPauseCommand.removeTarget(token)
            commandCenter.changeShuffleModeCommand.removeTarget(token)
        }
        targetTokens.removeAll()
        playbackController = nil
        context = nil
        isActive = false
        publishAvailability(.unavailable)

        #if canImport(UIKit)
        UIApplication.shared.endReceivingRemoteControlEvents()
        #endif
    }

    func syncPlaybackModes(from playbackController: PlaybackController) {
        syncPlaybackState(from: playbackController)
    }

    func syncPlaybackState(from playbackController: PlaybackController) {
        publishAvailability(playbackController.remoteCommandAvailability)
        publishPlaybackModes(shuffleEnabled: playbackController.shuffleEnabled)
    }

    @discardableResult
    func applyShuffleModeCommand(
        _ shuffleType: MPShuffleType,
        source: String,
        playbackController: PlaybackController? = nil,
        context: ModelContext? = nil
    ) async -> MPRemoteCommandHandlerStatus {
        guard let playbackController = playbackController ?? self.playbackController,
              let context = context ?? self.context else {
            return .commandFailed
        }
        guard playbackController.remoteCommandAvailability.canShuffle else {
            syncPlaybackState(from: playbackController)
            return .noActionableNowPlayingItem
        }

        _ = shuffleType
        let didReshuffle = await playbackController.reshuffleCurrentPlaylist(context: context)
        syncPlaybackState(from: playbackController)
        guard didReshuffle else {
            return .commandFailed
        }
        Self.logger.info(
            "\(source, privacy: .public) shuffle command requested; reshuffled current playlist"
        )
        return .success
    }

    private func publishAvailability(_ availability: PlaybackRemoteCommandAvailability) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = availability.canPlay
        commandCenter.pauseCommand.isEnabled = availability.canPause
        commandCenter.togglePlayPauseCommand.isEnabled = availability.canTogglePlayPause
        commandCenter.nextTrackCommand.isEnabled = availability.canSkipToNext
        commandCenter.previousTrackCommand.isEnabled = availability.canSkipToPrevious
        commandCenter.changeShuffleModeCommand.isEnabled = availability.canShuffle
    }

    private func publishPlaybackModes(shuffleEnabled: Bool) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.changeShuffleModeCommand.currentShuffleType = RemotePlaybackModeMapper.shuffleType(
            for: shuffleEnabled
        )
        commandCenter.changeRepeatModeCommand.currentRepeatType = .all
    }

    private func startPlaybackStateObservation() {
        playbackStateObservationGeneration += 1
        observePlaybackState(generation: playbackStateObservationGeneration)
    }

    private func stopPlaybackStateObservation() {
        playbackStateObservationGeneration += 1
    }

    private func observePlaybackState(generation: Int) {
        guard generation == playbackStateObservationGeneration,
              let playbackController else {
            return
        }

        withObservationTracking {
            _ = playbackController.remoteCommandAvailability
            _ = playbackController.shuffleEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackStateObservationGeneration else { return }
                if let playbackController = self.playbackController {
                    self.syncPlaybackState(from: playbackController)
                }
                self.observePlaybackState(generation: generation)
            }
        }
    }
}
