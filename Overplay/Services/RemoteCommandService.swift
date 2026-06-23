import Foundation
import MediaPlayer
import Observation
import OSLog
import SwiftData

#if canImport(UIKit)
import UIKit
#endif

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
    private var playbackModeObservationGeneration = 0

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
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = true
        commandCenter.changeRepeatModeCommand.isEnabled = false
        syncPlaybackModes(from: playbackController)

        targetTokens.append(commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
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
            Task { @MainActor in playbackController.pause() }
            return .success
        })
        targetTokens.append(commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
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
            guard playbackController.currentPlaylistID != nil else {
                self.syncPlaybackModes(from: playbackController)
                return .noActionableNowPlayingItem
            }

            let requestedShuffleType = event.shuffleType
            let targetShuffleType = RemotePlaybackModeMapper.canonicalShuffleType(for: requestedShuffleType)
            self.publishPlaybackModes(
                shuffleEnabled: RemotePlaybackModeMapper.shuffleEnabled(for: targetShuffleType)
            )
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
        startPlaybackModeObservation()
    }

    func update(playbackController: PlaybackController, context: ModelContext) {
        self.playbackController = playbackController
        self.context = context

        if isActive {
            syncPlaybackModes(from: playbackController)
            startPlaybackModeObservation()
        }
    }

    func deactivate() {
        stopPlaybackModeObservation()
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

        #if canImport(UIKit)
        UIApplication.shared.endReceivingRemoteControlEvents()
        #endif
    }

    func syncPlaybackModes(from playbackController: PlaybackController) {
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
        guard playbackController.currentPlaylistID != nil else {
            syncPlaybackModes(from: playbackController)
            return .noActionableNowPlayingItem
        }

        _ = shuffleType
        publishPlaybackModes(shuffleEnabled: true)

        await playbackController.reshuffleCurrentPlaylist(context: context)
        syncPlaybackModes(from: playbackController)
        Self.logger.info(
            "\(source, privacy: .public) shuffle command requested; reshuffled current playlist"
        )
        return .success
    }

    private func publishPlaybackModes(shuffleEnabled: Bool) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.changeShuffleModeCommand.currentShuffleType = RemotePlaybackModeMapper.shuffleType(
            for: shuffleEnabled
        )
        commandCenter.changeRepeatModeCommand.currentRepeatType = .all
    }

    private func startPlaybackModeObservation() {
        playbackModeObservationGeneration += 1
        observePlaybackModes(generation: playbackModeObservationGeneration)
    }

    private func stopPlaybackModeObservation() {
        playbackModeObservationGeneration += 1
    }

    private func observePlaybackModes(generation: Int) {
        guard generation == playbackModeObservationGeneration,
              let playbackController else {
            return
        }

        withObservationTracking {
            _ = playbackController.currentPlaylistID
            _ = playbackController.shuffleEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackModeObservationGeneration else { return }
                if let playbackController = self.playbackController {
                    self.syncPlaybackModes(from: playbackController)
                }
                self.observePlaybackModes(generation: generation)
            }
        }
    }
}
