import Foundation
import SwiftData

/// The alert before Overplay makes the One True Playlist's Apple Music
/// playlist (`SETUP-002`, `SETUP-003`): when to ask, and what a yes does.
@MainActor
@Observable
final class OneTruePlaylistPromptController {
    struct Dependencies {
        var presence = OneTruePlaylistPresenceService()
        var isFulfilling: () -> Bool = { PendingOneTruePlaylistService.isFulfilling }
        var fulfilPending: (ModelContext) async -> Void = { await AppRuntime.shared.fulfilPendingOneTruePlaylist(in: $0) }
        var rebuild: (ModelContext) async throws -> OneTruePlaylistRebuildService.Result = {
            try await AppRuntime.shared.playbackController.rebuildOneTruePlaylist(context: $0)
        }
        var show: (String) -> Void = { StatusToast.shared.show($0) }
    }

    private(set) var prompt: OneTruePlaylistPrompt?
    /// "Not Now", or a Mac's request this device failed to make, holds
    /// until the next launch.
    @ObservationIgnored private var declined = false
    @ObservationIgnored private var isMaking = false
    private let dependencies: Dependencies

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    private var canAsk: Bool {
        !declined && !isMaking && !dependencies.isFulfilling() && prompt == nil
    }

    /// `checksPresence`: a sync could not find the playlist, so look it up.
    func check(in context: ModelContext, checksPresence: Bool = false) async {
        guard canAsk else { return }
        let found = await dependencies.presence.prompt(in: context, checksPresence: checksPresence)
        // The user may have answered another prompt during the lookup.
        guard canAsk else { return }
        prompt = found
    }

    func decline() {
        prompt = nil
        declined = true
    }

    /// The user agreed: make the playlist the prompt described.
    func make(_ prompt: OneTruePlaylistPrompt, in context: ModelContext) async {
        self.prompt = nil
        isMaking = true
        defer { isMaking = false }
        switch prompt {
        case .requestedByMac:
            await dependencies.fulfilPending(context)
            if (try? context.fetch(FetchDescriptor<OverplaySettings>()).first?.selectedPlaylistID) == nil {
                // As the message says: not again at every iCloud import.
                declined = true
                dependencies.show("Overplay couldn’t make the playlist. It will ask again next time it starts.")
            }
        case .missing(_, let playlistID):
            // The alert may have waited while another device made it again
            // or the library caught up: check once more before making it.
            switch await dependencies.presence.isStillMissing(playlistID, in: context) {
            case true?:
                break
            case false?:
                dependencies.show("Your Overplay playlist is in Apple Music, so nothing was made.")
                return
            case nil:
                dependencies.show("Overplay couldn’t check Apple Music, so nothing was made. It will ask again if the playlist is still missing.")
                return
            }
            do {
                dependencies.show(OneTruePlaylistPrompt.remadeMessage(try await dependencies.rebuild(context)))
            } catch {
                dependencies.show(UserFacingError.message(for: error))
            }
        }
    }
}
