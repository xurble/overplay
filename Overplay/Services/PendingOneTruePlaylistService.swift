import Foundation
import SwiftData

/// Makes the managed One True Playlist a Mac's setup asked for (`SETUP-002`).
/// MusicKit cannot create playlists on a Mac, so the request syncs through
/// iCloud and the first iPhone or iPad to open Overplay makes it.
@MainActor
struct PendingOneTruePlaylistService {
    var canCreatePlaylists: () -> Bool = { !ProcessInfo.processInfo.isMacCatalystApp }
    var createManagedOneTruePlaylist: (_ name: String, _ sourcePlaylistID: String?, _ context: ModelContext) async throws -> PlaylistRecord = {
        name, sourcePlaylistID, context in
        try await PlaylistSyncService().createManagedOneTruePlaylist(named: name, copyingTracksFrom: sourcePlaylistID, in: context)
    }

    /// One request at a time on this device: imports, startup, the alert and
    /// the dashboard's card all ask. A later caller waits for the one in
    /// flight and gets its playlist, so it never reports a failure or makes a
    /// second playlist while the first is still being made.
    private static var inFlight: Task<PersistentIdentifier?, Never>?
    static var isFulfilling: Bool { inFlight != nil }

    /// Asks a Mac to leave the One True Playlist for an iPhone or iPad.
    static func request(copying source: AppleMusicPlaylist?, in context: ModelContext) throws {
        guard let settings = try context.fetch(FetchDescriptor<OverplaySettings>()).first else { return }
        settings.pendingOneTruePlaylistRequestedAt = .now
        settings.pendingOneTruePlaylistSourceID = source?.id
        settings.pendingOneTruePlaylistSourceName = source?.name
        settings.updatedAt = .now
        try context.save()
    }

    /// The new One True Playlist, or nil when nothing was asked for, this
    /// device cannot make it, or making it failed (it is asked again at the
    /// next launch or import). A One True Playlist chosen meanwhile, on any
    /// device, answers the request.
    func fulfilIfNeeded(in context: ModelContext) async -> PlaylistRecord? {
        if let inFlight = Self.inFlight { return await inFlight.value.flatMap { context.model(for: $0) as? PlaylistRecord } }
        guard canCreatePlaylists(),
              let settings = try? context.fetch(FetchDescriptor<OverplaySettings>()).first,
              settings.pendingOneTruePlaylistRequestedAt != nil else { return nil }
        guard settings.selectedPlaylistID == nil else {
            Self.clear(settings)
            try? context.save()
            return nil
        }
        let task = Task { await make(for: settings, in: context)?.persistentModelID }
        Self.inFlight = task
        defer { Self.inFlight = nil }
        return await task.value.flatMap { context.model(for: $0) as? PlaylistRecord }
    }

    private func make(for settings: OverplaySettings, in context: ModelContext) async -> PlaylistRecord? {
        do {
            let sourceID = settings.pendingOneTruePlaylistSourceID
            let playlist = try await createManagedOneTruePlaylist(SetupViewModel.oneTruePlaylistName, sourceID, context)
            try SettingsRepository.selectPlaylist(
                AppleMusicPlaylist(id: playlist.musicPlaylistID, name: playlist.name),
                writePolicy: .managed,
                in: context
            )
            Self.clear(settings)
            try context.save()
            StartupProfiler.mark("Made the One True Playlist a Mac asked for")
            return playlist
        } catch {
            StartupProfiler.mark("Pending One True Playlist failed: \(UserFacingError.message(for: error))")
            return nil
        }
    }

    private static func clear(_ settings: OverplaySettings) {
        settings.pendingOneTruePlaylistRequestedAt = nil
        settings.pendingOneTruePlaylistSourceID = nil
        settings.pendingOneTruePlaylistSourceName = nil
        settings.updatedAt = .now
    }
}
