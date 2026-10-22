import Foundation
import Observation
import SwiftData

/// First-run setup: the One True Playlist and Triage's first sources. The
/// library itself is created by the first choice that needs it, so swiping
/// through the cards writes nothing.
@MainActor
@Observable
final class SetupViewModel {
    struct Dependencies {
        var createLibrary: (_ context: ModelContext) throws -> Void
        var fetchLibraryPlaylists: () async throws -> [AppleMusicPlaylist]
        var createManagedOneTruePlaylist: (_ name: String, _ sourcePlaylistID: String?, _ context: ModelContext) async throws -> PlaylistRecord
        var reconcileSelection: (_ playlist: PlaylistRecord, _ context: ModelContext) -> Void
        var syncPlaylist: (_ playlist: PlaylistRecord, _ context: ModelContext) async throws -> Void
        /// MusicKit cannot create playlists on a Mac.
        var canCreatePlaylists: () -> Bool = { !ProcessInfo.processInfo.isMacCatalystApp }

        static func live(runtime: AppRuntime, playbackController: PlaybackController) -> Dependencies {
            Dependencies { context in
                guard !runtime.libraryRestoration.isReady else { return }
                try runtime.libraryRestoration.createLibrary(in: context)
            } fetchLibraryPlaylists: {
                try await PlaylistSyncService().fetchLibraryPlaylists()
            } createManagedOneTruePlaylist: { name, sourcePlaylistID, context in
                try await PlaylistSyncService().createManagedOneTruePlaylist(
                    named: name, copyingTracksFrom: sourcePlaylistID, in: context
                )
            } reconcileSelection: { playlist, context in
                playbackController.reconcilePlaylistSelection(context: context)
                playbackController.reconcileStoredOrder(for: playlist, context: context)
            } syncPlaylist: { playlist, context in
                _ = try await PlaylistSyncService().syncPlaylist(playlist, in: context)
            }
        }
    }

    /// The managed playlist setup creates, copied into or empty.
    static let oneTruePlaylistName = "Overplay"
    /// Playlists Apple Music fills by itself, suggested as Triage sources.
    static let suggestedSourceNames = ["tiktok", "shazam"]

    var playlists: [AppleMusicPlaylist] = []
    var isLoading = false
    var isCreatingOneTruePlaylist = false
    /// What the One True Playlist was copied from; nil when it started empty.
    private(set) var copiedFrom: String?
    private(set) var oneTruePlaylistID: String?
    /// On a Mac: an iPhone or iPad will make the One True Playlist (`SETUP-002`).
    private(set) var isOneTruePlaylistRequested = false
    /// A library arrived from iCloud while setup was open: setup ends and
    /// startup restores it.
    private(set) var foundExistingLibrary = false
    private(set) var triageSourceIDs = Set<String>()
    /// The person chose to add Triage sources later.
    private(set) var skipsTriage = false
    var message: String?

    var hasOneTruePlaylist: Bool { oneTruePlaylistID != nil }
    /// The One True Playlist card has its answer, made or asked for.
    var hasChosenOneTruePlaylist: Bool { hasOneTruePlaylist || isOneTruePlaylistRequested }
    /// Triage has sources, or the person chose to add them later.
    var hasChosenTriage: Bool { skipsTriage || !triageSourceIDs.isEmpty }

    func skipTriage() { skipsTriage = true }

    /// Whether the person may move past `page`: the One True Playlist and
    /// Triage cards each need a choice.
    func isDecided(_ page: SetupPage) -> Bool {
        switch page {
        case .oneTruePlaylist: hasChosenOneTruePlaylist
        case .triage: hasChosenTriage
        default: true
        }
    }

    /// The cards up to the first choice still to make, so swiping cannot skip
    /// the One True Playlist or Triage.
    var reachablePages: [SetupPage] {
        var pages: [SetupPage] = []
        for page in SetupPage.allCases {
            pages.append(page)
            if !isDecided(page) { break }
        }
        return pages
    }

    var suggestedSources: [AppleMusicPlaylist] {
        triageCandidates.filter(Self.isSuggested)
    }

    var otherSources: [AppleMusicPlaylist] {
        triageCandidates.filter { !Self.isSuggested($0) }
    }

    private var triageCandidates: [AppleMusicPlaylist] {
        playlists.filter { $0.id != oneTruePlaylistID }
    }

    static func isSuggested(_ playlist: AppleMusicPlaylist) -> Bool {
        let name = playlist.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: " ", with: "")
        return suggestedSourceNames.contains { name.contains($0) }
    }

    /// Picks up what an earlier setup screen already chose, from the store,
    /// so a screen rebuilt mid-setup never makes a second playlist.
    func restoreProgress(context: ModelContext) {
        guard let settings = try? context.fetch(FetchDescriptor<OverplaySettings>()).first else { return }
        if let selected = settings.selectedPlaylistID {
            oneTruePlaylistID = selected
        } else if settings.pendingOneTruePlaylistRequestedAt != nil {
            isOneTruePlaylistRequested = true
            copiedFrom = settings.pendingOneTruePlaylistSourceName
        }
        if let sources = try? PlaylistRepository.triageSources(in: context) {
            triageSourceIDs = Set(sources.map(\.musicPlaylistID))
        }
    }

    func loadPlaylists(dependencies: Dependencies) async {
        guard playlists.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await dependencies.fetchLibraryPlaylists()
        } catch {
            message = UserFacingError.message(for: error)
        }
    }

    /// Creates a managed "Overplay" playlist in Apple Music, empty or with a
    /// copy of `source`'s songs, and makes it the One True Playlist.
    func createOneTruePlaylist(
        copying source: AppleMusicPlaylist?,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        guard !hasChosenOneTruePlaylist, !isCreatingOneTruePlaylist else { return }
        isCreatingOneTruePlaylist = true
        defer { isCreatingOneTruePlaylist = false }
        do {
            try dependencies.createLibrary(context)
            // Never replace a One True Playlist the store already has.
            restoreProgress(context: context)
            guard !hasChosenOneTruePlaylist else { return }
            guard dependencies.canCreatePlaylists() else {
                try PendingOneTruePlaylistService.request(copying: source, in: context)
                isOneTruePlaylistRequested = true
                copiedFrom = source?.name
                return
            }
            let playlist = try await dependencies.createManagedOneTruePlaylist(Self.oneTruePlaylistName, source?.id, context)
            try SettingsRepository.selectPlaylist(
                AppleMusicPlaylist(id: playlist.musicPlaylistID, name: playlist.name, trackCount: source?.trackCount ?? 0),
                writePolicy: .managed,
                in: context
            )
            dependencies.reconcileSelection(playlist, context)
            oneTruePlaylistID = playlist.musicPlaylistID
            copiedFrom = source?.name
        } catch LibraryRestorationService.RestorationError.existingLibrary {
            foundExistingLibrary = true
        } catch {
            message = UserFacingError.message(for: error)
        }
    }

    func setTriageSource(_ playlist: AppleMusicPlaylist, isOn: Bool, context: ModelContext, dependencies: Dependencies) {
        do {
            try dependencies.createLibrary(context)
            if isOn {
                try PlaylistRepository.addTriageSource(playlist, in: context)
                try context.save()
                triageSourceIDs.insert(playlist.id)
            } else if let record = try PlaylistRepository.playlist(musicPlaylistID: playlist.id, in: context) {
                try PlaylistRepository.removeTriageSource(record, in: context)
                triageSourceIDs.remove(playlist.id)
            }
        } catch LibraryRestorationService.RestorationError.existingLibrary {
            foundExistingLibrary = true
        } catch {
            message = UserFacingError.message(for: error)
        }
    }

    /// Creates the library if no choice did, and starts the first sync of the
    /// chosen sources so Triage is not empty until the next periodic sync.
    func finish(context: ModelContext, dependencies: Dependencies) -> Bool {
        do {
            try dependencies.createLibrary(context)
        } catch LibraryRestorationService.RestorationError.existingLibrary {
            // A library arrived from iCloud meanwhile: startup restores it.
            return true
        } catch {
            message = UserFacingError.message(for: error)
            return false
        }
        let sources = triageSourceIDs.compactMap { try? PlaylistRepository.playlist(musicPlaylistID: $0, in: context) }
        if !sources.isEmpty {
            Task {
                for source in sources {
                    do {
                        try await dependencies.syncPlaylist(source, context)
                    } catch {
                        source.lastSyncError = UserFacingError.message(for: error)
                        try? context.save()
                    }
                }
            }
        }
        return true
    }
}
