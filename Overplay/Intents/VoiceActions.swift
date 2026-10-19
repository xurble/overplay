import Foundation
import SwiftData

/// What each Siri action does (`SIRI-001`). The App Intents only wrap these.
/// Every action is one shared controller entry point, the same one the app
/// and CarPlay use, and decides nothing itself (`SURFACE-001`).
@MainActor
enum VoiceActions {
    enum Playlist: Sendable {
        case oneTruePlaylist
        case triage
    }

    enum Curation: Sendable {
        case promote
        case retire
        case undo
    }

    static let notReadyMessage = "Overplay is still restoring your library. Open Overplay to finish."

    /// Shuffle and Play, which carries on with a playlist already playing
    /// (`PLAY-020`). Nil once it plays: the music answers for itself.
    static func play(_ target: Playlist, controller: PlaybackController, context: ModelContext) async -> String? {
        let playlist: PlaylistRecord
        let settings: OverplaySettings
        do {
            switch target {
            case .oneTruePlaylist:
                guard let otp = try PlaylistRepository.oneTruePlaylist(in: context) else {
                    return "Choose a One True Playlist in Overplay first."
                }
                playlist = otp
            case .triage:
                playlist = try PlaylistRepository.triageBucket(in: context)
            }
            settings = try SettingsRepository.settings(in: context)
        } catch {
            return UserFacingError.message(for: error)
        }
        await MusicKitActivityLog.shared.withOrigin(.siri) {
            await controller.playPlaylist(playlist, scope: .active, settings: settings, context: context)
        }
        switch CarPlayPlaybackOutcome.decide(
            hasPlaybackFailure: controller.playbackFailure != nil,
            current: controller.currentPlaylistContext,
            requested: playlist.playbackContext(.active)
        ) {
        case .nowPlaying: return nil
        case .sharedFailure: return controller.playbackFailure?.message ?? "Apple Music didn't start playing."
        case .notStarted: return controller.statusMessage ?? "Overplay couldn't start \(playlist.name)."
        }
    }

    static func curate(_ action: Curation, controller: PlaybackController, context: ModelContext) async -> CurationOutcome {
        let settings: OverplaySettings
        do {
            settings = try SettingsRepository.settings(in: context)
        } catch {
            return .failed(UserFacingError.message(for: error))
        }
        return await MusicKitActivityLog.shared.withOrigin(.siri) {
            switch action {
            case .promote: await controller.promoteCurrent(settings: settings, context: context)
            case .retire: await controller.evictCurrent(settings: settings, context: context)
            case .undo: await controller.undoLastCuration(context: context)
            }
        }
    }
}
