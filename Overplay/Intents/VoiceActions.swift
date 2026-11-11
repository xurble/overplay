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
    static let storeUnavailableMessage = "Overplay can't open your library. Open Overplay for details."
    static let notAuthorizedMessage = "Overplay isn't connected to Apple Music. Open Overplay to connect it."
    static let setupUnfinishedMessage = "Overplay isn't set up yet. Open Overplay to finish setting it up."

    /// Where the library stands for an intent launched with no window (`SIRI-002`).
    enum LibraryState: Equatable, Sendable {
        case ready
        /// Only this can still become ready while an intent waits.
        case restoring
        case notAuthorized
        case setupUnfinished
        case preparationFailed
    }

    static func libraryState(
        isLibraryReady: Bool, readiness: AppleMusicReadiness, isSettingUp: Bool, preparationFailed: Bool
    ) -> LibraryState {
        if isLibraryReady { return .ready }
        if !readiness.isReady { return .notAuthorized }
        if isSettingUp { return .setupUnfinished }
        return preparationFailed ? .preparationFailed : .restoring
    }

    /// Waits while the library is restoring, for `attempts` pauses at most.
    static func awaitLibrary(
        attempts: Int,
        state: () -> LibraryState,
        pause: () async -> Void = { try? await Task.sleep(for: libraryPollInterval) }
    ) async -> LibraryState {
        for _ in 0..<attempts {
            let current = state()
            guard current == .restoring else { return current }
            await pause()
        }
        return state()
    }

    static let libraryPollInterval = Duration.milliseconds(100)

    /// What Siri says when the library is not ready; nil when it is.
    static func spokenReason(for state: LibraryState) -> String? {
        switch state {
        case .ready: nil
        case .notAuthorized: notAuthorizedMessage
        case .setupUnfinished: setupUnfinishedMessage
        case .restoring, .preparationFailed: notReadyMessage
        }
    }

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
