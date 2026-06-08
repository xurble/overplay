import Foundation
import MediaPlayer
import SwiftData

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class RemoteCommandService {
    private(set) var isActive = false
    private(set) var playbackController: PlaybackController?
    private(set) var context: ModelContext?
    private var targetTokens = [Any]()

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
        commandCenter.changeShuffleModeCommand.isEnabled = true
        commandCenter.changeRepeatModeCommand.isEnabled = true
        syncPlaybackModes(from: playbackController)

        targetTokens.append(commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
            }
            Task { await playbackController.play(context: context) }
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
            Task { await playbackController.togglePlayPause(context: context) }
            return .success
        })
        targetTokens.append(commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let settings = try? SettingsRepository.settings(in: context) else { return }
                await playbackController.next(settings: settings, context: context)
            }
            return .success
        })
        targetTokens.append(commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
            }
            Task { await playbackController.previous(context: context) }
            return .success
        })
        targetTokens.append(commandCenter.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }
            guard let self, let playbackController = self.playbackController, let context = self.context else {
                return .commandFailed
            }

            Task { @MainActor in
                await playbackController.setShuffleEnabled(
                    RemotePlaybackModeMapper.shuffleEnabled(for: event.shuffleType),
                    context: context
                )
                self.syncPlaybackModes(from: playbackController)
            }
            return .success
        })
        targetTokens.append(commandCenter.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            guard let self, let playbackController = self.playbackController else {
                return .commandFailed
            }

            Task { @MainActor in
                playbackController.setRepeatEnabled(RemotePlaybackModeMapper.repeatEnabled(for: event.repeatType))
                self.syncPlaybackModes(from: playbackController)
            }
            return .success
        })
    }

    func update(playbackController: PlaybackController, context: ModelContext) {
        self.playbackController = playbackController
        self.context = context

        if isActive {
            syncPlaybackModes(from: playbackController)
        }
    }

    func deactivate() {
        let commandCenter = MPRemoteCommandCenter.shared()
        for token in targetTokens {
            commandCenter.playCommand.removeTarget(token)
            commandCenter.pauseCommand.removeTarget(token)
            commandCenter.nextTrackCommand.removeTarget(token)
            commandCenter.previousTrackCommand.removeTarget(token)
            commandCenter.togglePlayPauseCommand.removeTarget(token)
            commandCenter.changeShuffleModeCommand.removeTarget(token)
            commandCenter.changeRepeatModeCommand.removeTarget(token)
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
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.changeShuffleModeCommand.currentShuffleType = RemotePlaybackModeMapper.shuffleType(
            for: playbackController.shuffleEnabled
        )
        commandCenter.changeRepeatModeCommand.currentRepeatType = RemotePlaybackModeMapper.repeatType(
            for: playbackController.repeatEnabled
        )
    }
}
