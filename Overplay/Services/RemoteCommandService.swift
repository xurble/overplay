import Foundation
import MediaPlayer
import SwiftData

@MainActor
final class RemoteCommandService {
    private var isInstalled = false

    func install(playbackController: PlaybackController, context: ModelContext) {
        guard !isInstalled else { return }
        isInstalled = true

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changeRepeatModeCommand.isEnabled = true
        syncPlaybackModes(from: playbackController)

        commandCenter.playCommand.addTarget { _ in
            Task { await playbackController.play() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in playbackController.pause() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { await playbackController.togglePlayPause() }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { _ in
            Task { @MainActor in
                guard let settings = try? SettingsRepository.settings(in: context) else { return }
                await playbackController.next(settings: settings, context: context)
            }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { _ in
            Task { await playbackController.previous(context: context) }
            return .success
        }
        commandCenter.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor in
                playbackController.setRepeatMode(RemotePlaybackModeMapper.repeatMode(for: event.repeatType))
                self?.syncPlaybackModes(from: playbackController)
            }
            return .success
        }
    }

    func syncPlaybackModes(from playbackController: PlaybackController) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.changeRepeatModeCommand.currentRepeatType = RemotePlaybackModeMapper.repeatType(for: playbackController.repeatMode)
    }
}
