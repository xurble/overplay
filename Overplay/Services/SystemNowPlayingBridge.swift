import Foundation
import MediaPlayer
import Observation
import SwiftData

#if canImport(UIKit)
import UIKit
#endif

/// System Now Playing belongs to `ApplicationMusicPlayer`'s host (`PLAY-016`).
///
/// By default this does nothing: Lock Screen, Control Center, headset and
/// CarPlay transport act on the player directly, and the controller observes
/// the result. The device-local diagnostic mirror exists only to verify CarPlay
/// behaviour on new iOS releases. It publishes metadata derived solely from the
/// controller's observed player state, and forwards transport commands to the
/// controller's single-call actions with no gating. See History H-7 in the spec
/// before enabling it by default.
@MainActor
final class SystemNowPlayingBridge {
    static let mirrorDefaultsKey = "overplay.diagnostics.mirrorNowPlaying"

    private let defaults: UserDefaults
    private weak var playbackController: PlaybackController?
    private var context: ModelContext?
    private var targetTokens: [(MPRemoteCommand, Any)] = []
    private var observationGeneration = 0
    private(set) var isMirroring = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isMirrorEnabled: Bool {
        get { defaults.bool(forKey: Self.mirrorDefaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.mirrorDefaultsKey)
            if let playbackController, let context {
                activate(playbackController: playbackController, context: context)
            }
        }
    }

    func activate(playbackController: PlaybackController, context: ModelContext) {
        self.playbackController = playbackController
        self.context = context
        if isMirrorEnabled {
            startMirroring()
        } else {
            stopMirroring()
        }
    }

    private func startMirroring() {
        guard !isMirroring, let playbackController else { return }
        isMirroring = true
        #if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        let center = MPRemoteCommandCenter.shared()
        addTarget(center.playCommand) { controller, context in await controller.play(context: context) }
        addTarget(center.pauseCommand) { controller, _ in controller.pause() }
        addTarget(center.togglePlayPauseCommand) { controller, context in await controller.togglePlayPause(context: context) }
        addTarget(center.nextTrackCommand) { controller, context in
            guard let settings = try? SettingsRepository.settings(in: context) else { return }
            await controller.next(settings: settings, context: context)
        }
        addTarget(center.previousTrackCommand) { controller, context in await controller.previous(context: context) }
        observationGeneration += 1
        publish(from: playbackController, generation: observationGeneration)
    }

    private func stopMirroring() {
        guard isMirroring else { return }
        isMirroring = false
        observationGeneration += 1
        for (command, token) in targetTokens { command.removeTarget(token) }
        targetTokens.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if canImport(UIKit)
        UIApplication.shared.endReceivingRemoteControlEvents()
        #endif
    }

    private func addTarget(
        _ command: MPRemoteCommand,
        action: @escaping @MainActor (PlaybackController, ModelContext) async -> Void
    ) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] _ in
            guard let self, let controller = self.playbackController, let context = self.context else {
                return .commandFailed
            }
            Task { @MainActor in
                await MusicKitActivityLog.shared.withOrigin(.remoteCommand) {
                    await action(controller, context)
                }
            }
            return .success
        }
        targetTokens.append((command, token))
    }

    /// Re-publishes when the observed track or play state changes; the system
    /// extrapolates position from elapsed time and rate in between.
    private func publish(from controller: PlaybackController, generation: Int) {
        guard isMirroring, generation == observationGeneration else { return }
        // Track only identity and play state; elapsed time is read untracked
        // so the mirror does not rewrite Now Playing every second.
        let (track, isPlaying) = withObservationTracking {
            (controller.currentTrack, controller.isPlaying)
        } onChange: { [weak self, weak controller] in
            Task { @MainActor in
                guard let self, let controller else { return }
                self.publish(from: controller, generation: generation)
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.info(
            track: track, elapsed: controller.elapsedSeconds, isPlaying: isPlaying
        )
    }

    static func info(track: CurrentPlaybackTrack?, elapsed: Double, isPlaying: Bool) -> [String: Any]? {
        guard let track else { return nil }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let album = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = track.durationSeconds { info[MPMediaItemPropertyPlaybackDuration] = duration }
        return info
    }
}
