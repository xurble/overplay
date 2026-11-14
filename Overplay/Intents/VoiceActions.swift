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
        /// A retired song back to the Inbox.
        case restore
        /// A song Overplay does not track, playing from an album or artist,
        /// to the Inbox.
        case add
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
            case .restore: restore(controller: controller, context: context)
            case .add: await add(controller: controller, context: context)
            }
        }
    }

    /// Restore, as the app's and CarPlay's button. The controller decides;
    /// this only words the result.
    private static func restore(controller: PlaybackController, context: ModelContext) -> CurationOutcome {
        guard controller.displayedPlaylistItem(context: context) != nil else {
            return .unavailable(controller.nothingToCurateMessage)
        }
        let title = controller.currentTrack?.title ?? "This song"
        guard controller.restoreCurrent(context: context) else {
            return .unavailable(controller.statusMessage ?? "Overplay couldn't restore \(title).")
        }
        return .moved(title: title, to: .triage)
    }

    /// Add to the Inbox, as the app's and CarPlay's button. Success is read
    /// as CarPlay reads it: the song is no longer one Overplay could add.
    private static func add(controller: PlaybackController, context: ModelContext) async -> CurationOutcome {
        guard let title = controller.currentTrack?.title else { return .unavailable("Nothing is playing.") }
        guard controller.canAddCurrentToOverplay else {
            if controller.displayedPlaylistItem(context: context) != nil {
                return .unavailable("\(title) is already in Overplay.")
            }
            return .unavailable("Overplay can add a song only while it plays an album or artist.")
        }
        await controller.addCurrentToTriage(context: context)
        guard !controller.canAddCurrentToOverplay else {
            return .failed(controller.statusMessage ?? "Overplay couldn't add \(title).")
        }
        return .added(title: title)
    }

    /// Play Album or Play Artist for the current song (`PLAY-018`), as Now
    /// Playing's Dive Deeper. Nil once it plays, as `play`.
    static func diveDeeper(
        _ request: PlaybackCollection.Request, controller: PlaybackController, context: ModelContext
    ) async -> String? {
        guard controller.currentTrack != nil else { return "Nothing is playing." }
        let started = await MusicKitActivityLog.shared.withOrigin(.siri) {
            await controller.playCurrentCollection(request, context: context)
        }
        if started { return nil }
        return controller.playbackFailure?.message ?? controller.statusMessage
            ?? "Overplay couldn't start this \(request.rawValue)."
    }

    /// What's playing and where it lives. It changes nothing; the counts are
    /// Overplay's own and best-effort.
    static func describeCurrent(controller: PlaybackController, context: ModelContext) -> String {
        guard let track = controller.currentTrack else { return "Nothing is playing." }
        let song = "This is \(track.title) by \(track.artistName)."
        guard let item = controller.displayedPlaylistItem(context: context) else {
            return "\(song) It isn't in Overplay."
        }
        let place: String = if item.evictedAt != nil {
            "It's retired."
        } else if controller.currentPlaylistRole(context: context) == .oneTruePlaylist {
            "It's in your One True Playlist."
        } else {
            "It's in the Inbox."
        }
        return "\(song) \(place) \(countsSentence(plays: item.playthroughCount, skips: item.skipCount))"
    }

    static func countsSentence(plays: Int, skips: Int) -> String {
        func times(_ count: Int) -> String {
            switch count {
            case 1: "once"
            case 2: "twice"
            default: "\(count) times"
            }
        }
        switch (plays, skips) {
        case (0, 0): return "You haven't played or skipped it yet."
        case (_, 0): return "You've played it \(times(plays)) and never skipped it."
        case (0, _): return "You've skipped it \(times(skips)) and never played it through."
        default: return "You've played it \(times(plays)) and skipped it \(times(skips))."
        }
    }
}
