import Foundation
import SwiftData

/// The Apple Music playlist behind the One True Playlist is not there: a Mac
/// asked for it and could not make it (`SETUP-002`), or it was deleted from
/// Apple Music (`SETUP-003`). Overplay asks before making it.
enum OneTruePlaylistPrompt: Equatable, Identifiable {
    case requestedByMac(sourceName: String?)
    case missing(name: String)

    var id: String {
        switch self {
        case .requestedByMac: "requested"
        case .missing(let name): "missing-\(name)"
        }
    }

    var title: String {
        switch self {
        case .requestedByMac: "Make Your Overplay Playlist?"
        case .missing: "Overplay Playlist Missing"
        }
    }

    var message: String {
        switch self {
        case .requestedByMac(let sourceName):
            let contents = sourceName.map { "with the songs from \($0)" } ?? "empty to start"
            return "Your Mac asked for a new Apple Music playlist called Overplay, \(contents). A Mac can’t create playlists, so this device will."
        case .missing(let name):
            return "“\(name)” isn’t in your Apple Music library any more. Overplay can make it again with the songs in your One True Playlist."
        }
    }

    var actionTitle: String {
        switch self {
        case .requestedByMac: "Make Playlist"
        case .missing: "Make It Again"
        }
    }
}

@MainActor
struct OneTruePlaylistPresenceService {
    var canCreatePlaylists: () -> Bool = { !ProcessInfo.processInfo.isMacCatalystApp }
    /// Whether the library has this playlist; nil when it cannot tell, which
    /// never prompts.
    var playlistExists: (_ musicPlaylistID: String) async -> Bool? = { id in
        do {
            return try await CachingMusicLibraryPlaylistFetcher.shared.fetchPlaylist(id: id) != nil
        } catch {
            return nil
        }
    }

    /// What to ask, or nil when nothing needs making or this device cannot.
    /// `checksPresence` looks the playlist up in Apple Music; only a sync
    /// that could not find it asks, so launch adds no Apple Music call
    /// (`LOAD-001`).
    func prompt(in context: ModelContext, checksPresence: Bool) async -> OneTruePlaylistPrompt? {
        guard canCreatePlaylists(),
              let settings = try? context.fetch(FetchDescriptor<OverplaySettings>()).first else { return nil }
        guard settings.selectedPlaylistID != nil else {
            guard settings.pendingOneTruePlaylistRequestedAt != nil else { return nil }
            return .requestedByMac(sourceName: settings.pendingOneTruePlaylistSourceName)
        }
        guard checksPresence, let playlist = try? PlaylistRepository.oneTruePlaylist(in: context),
              await playlistExists(playlist.musicPlaylistID) == false else { return nil }
        return .missing(name: playlist.name)
    }
}
