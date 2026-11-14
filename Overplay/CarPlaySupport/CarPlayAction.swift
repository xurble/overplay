import Foundation
import SwiftData

/// What the templates do once a `CarPlayAction` has run.
enum CarPlayActionFollowUp: Equatable, Sendable {
    /// What the row pointed at has gone; the controller was not called.
    case staleLists
    /// The action could not be set up; the controller was not called.
    case blocked(title: String, message: String)
    case nowPlaying
    /// Nothing started and no shared failure says why.
    case playbackFailed
    case couldNotAdd(String)
    /// Promote, Retire or Restore reached the controller and did not happen.
    case trackActionFailed(String)
    /// A shared failure presents its own alert, or there is nothing to show.
    case nothing

    var reachedController: Bool {
        switch self {
        case .staleLists, .blocked: false
        case .nowPlaying, .playbackFailed, .couldNotAdd, .trackActionFailed, .nothing: true
        }
    }
}

/// Every CarPlay action that reaches the shared playback controller, and the
/// one entry point each calls (`SURFACE-001`). `CarPlayCoordinator` keeps the
/// templates and navigation; the routing lives here so it can be tested
/// without any CarPlay object.
@MainActor
enum CarPlayAction {
    case selectTrack(trackID: UUID?, in: PlaylistRecord, scope: PlaylistPlaybackScope)
    case shuffleAndPlay(PlaylistRecord, scope: PlaylistPlaybackScope)
    /// The root list's Resume row, offered before the library is restored.
    case resumeBeforeRestoration
    /// Try Again on the shared failure alert.
    case tryAgainAfterFailure
    case playRecent(id: UUID, startingAt: String?)
    case playLibraryItem(LibraryBrowser.Item, entries: [LibraryBrowser.Entry], startingAt: String?)
    case playMadeForYou(MadeForYouLibrary.Item, entries: [LibraryBrowser.Entry], startingAt: String?)
    case playCurrentCollection(PlaybackCollection.Request)
    case promote
    case retire
    case restore
    case addToTriage
    case addToOneTruePlaylist
    case toggleShuffle
    case toggleRepeat

    /// A playlist's list: Shuffle and Play, then one row per track shown.
    static func playlistRows(
        _ tracks: some Sequence<TrackSummaryPresentation>, in playlist: PlaylistRecord, scope: PlaylistPlaybackScope
    ) -> [String: CarPlayAction] {
        var rows: [String: CarPlayAction] = ["shuffle": .shuffleAndPlay(playlist, scope: scope)]
        for track in tracks {
            rows[track.id.uuidString] = .selectTrack(trackID: track.trackID, in: playlist, scope: scope)
        }
        return rows
    }

    /// A Recents entry's list: Shuffle and Play, then one row per song shown.
    static func recentRows(recentID: UUID, catalogSongIDs: some Sequence<String>) -> [String: CarPlayAction] {
        var rows: [String: CarPlayAction] = ["shuffle": .playRecent(id: recentID, startingAt: nil)]
        for songID in catalogSongIDs {
            rows[songID] = .playRecent(id: recentID, startingAt: songID)
        }
        return rows
    }

    func perform(controller: PlaybackController, context: ModelContext) async -> CarPlayActionFollowUp {
        do {
            switch self {
            case .selectTrack(let trackID, let playlist, let scope):
                guard let trackID, let track = try TrackRecordRepository.track(id: trackID, in: context) else {
                    return .staleLists
                }
                let settings = try SettingsRepository.settings(in: context)
                await fromCarPlay {
                    await controller.playPlaylist(playlist, startingAt: track, scope: scope, settings: settings, context: context)
                }
                return Self.playlistFollowUp(playlist, scope: scope, controller: controller)

            case .shuffleAndPlay(let playlist, let scope):
                let settings = try SettingsRepository.settings(in: context)
                await fromCarPlay {
                    await controller.playPlaylist(playlist, scope: scope, settings: settings, context: context)
                }
                return Self.playlistFollowUp(playlist, scope: scope, controller: controller)

            case .resumeBeforeRestoration:
                // PA-6: `play(context:)`, where the app's primary button calls
                // `performPrimaryPlaybackAction`.
                await fromCarPlay { await controller.play(context: context) }
                return controller.playbackFailure == nil ? .nowPlaying : .nothing

            case .tryAgainAfterFailure:
                await fromCarPlay { await controller.play(context: context) }
                return .nothing

            case .playRecent(let id, let catalogSongID):
                guard let recent = try? RecentCollectionRepository.recent(id: id, in: context) else { return .staleLists }
                let started = await fromCarPlay {
                    await controller.playRecent(recent, startingAt: catalogSongID, context: context)
                }
                return Self.startFollowUp(started: started, controller: controller)

            case .playLibraryItem(let item, let entries, let catalogSongID):
                let started = await fromCarPlay {
                    await LibraryBrowser.play(item, entries: entries, startingAt: catalogSongID,
                                              controller: controller, context: context)
                }
                return Self.startFollowUp(started: started, controller: controller)

            case .playMadeForYou(let item, let entries, let catalogSongID):
                let started = await fromCarPlay {
                    await MadeForYouLibrary.play(item, entries: entries, startingAt: catalogSongID,
                                                 controller: controller, context: context)
                }
                return Self.startFollowUp(started: started, controller: controller)

            case .playCurrentCollection(let request):
                let started = await fromCarPlay {
                    await controller.playCurrentCollection(request, context: context)
                }
                // Started, it is already on its way to Now Playing.
                return !started && controller.playbackFailure == nil ? .playbackFailed : .nothing

            case .promote:
                let settings = try SettingsRepository.settings(in: context)
                let outcome = await fromCarPlay { await controller.promoteCurrent(settings: settings, context: context) }
                return Self.curationFollowUp(outcome)

            case .retire:
                let settings = try SettingsRepository.settings(in: context)
                let outcome = await fromCarPlay { await controller.evictCurrent(settings: settings, context: context) }
                return Self.curationFollowUp(outcome)

            case .restore:
                let restored = await fromCarPlay { controller.restoreCurrent(context: context) }
                return restored ? .nothing : .trackActionFailed(controller.statusMessage ?? "Overplay couldn't restore this song.")

            case .addToTriage:
                await fromCarPlay { await controller.addCurrentToTriage(context: context) }
                return Self.addFollowUp(controller: controller)

            case .addToOneTruePlaylist:
                await fromCarPlay { await controller.addCurrentToOneTruePlaylist(context: context) }
                return Self.addFollowUp(controller: controller)

            case .toggleShuffle:
                await fromCarPlay { await controller.toggleShuffle(context: context) }
                return .nothing

            case .toggleRepeat:
                await fromCarPlay { await controller.toggleRepeatAll(context: context) }
                return .nothing
            }
        } catch {
            return .blocked(title: failureTitle, message: UserFacingError.message(for: error))
        }
    }

    private var failureTitle: String {
        switch self {
        case .promote, .retire: "Track action failed"
        default: "Playback failed"
        }
    }

    private func fromCarPlay<T>(_ body: () async -> T) async -> T {
        await MusicKitActivityLog.shared.withOrigin(.carPlay) { await body() }
    }

    /// The controller decides success (`SURFACE-003`): a shared failure shows
    /// its own alert with Try Again; a start that never happened reports why;
    /// anything else, including a non-blocking note, goes to Now Playing.
    private static func playlistFollowUp(
        _ playlist: PlaylistRecord, scope: PlaylistPlaybackScope, controller: PlaybackController
    ) -> CarPlayActionFollowUp {
        switch CarPlayPlaybackOutcome.decide(
            hasPlaybackFailure: controller.playbackFailure != nil,
            current: controller.currentPlaylistContext,
            requested: playlist.playbackContext(scope)
        ) {
        case .nowPlaying: .nowPlaying
        case .sharedFailure: .nothing
        case .notStarted: .playbackFailed
        }
    }

    private static func startFollowUp(started: Bool, controller: PlaybackController) -> CarPlayActionFollowUp {
        if started { return .nowPlaying }
        return controller.playbackFailure == nil ? .playbackFailed : .nothing
    }

    /// A move shows itself on Now Playing; anything else would be silent in
    /// the car, so it reports the reason Siri speaks.
    private static func curationFollowUp(_ outcome: CurationOutcome) -> CarPlayActionFollowUp {
        switch outcome {
        case .moved, .added: .nothing
        case .unavailable, .failed: .trackActionFailed(outcome.message)
        }
    }

    /// PA-4: success is inferred from the song current by now, which may not
    /// be the song that was added.
    private static func addFollowUp(controller: PlaybackController) -> CarPlayActionFollowUp {
        guard controller.canAddCurrentToOverplay else { return .nothing }
        return .couldNotAdd(controller.statusMessage ?? "Apple Music didn't respond.")
    }
}
