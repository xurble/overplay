import Foundation
import SwiftData

/// The Apple Music playlist behind the One True Playlist is not there: a Mac
/// asked for it and could not make it (`SETUP-002`), or it was deleted from
/// Apple Music (`SETUP-003`). Overplay asks before making it.
enum OneTruePlaylistPrompt: Equatable, Identifiable {
    case requestedByMac(sourceName: String?)
    case missing(name: String, playlistID: String)

    var id: String {
        switch self {
        case .requestedByMac: "requested"
        case .missing(_, let playlistID): "missing-\(playlistID)"
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
        case .missing(let name, _):
            return "Overplay can’t find “\(name)” in your Apple Music library. If you deleted it, Overplay can make it again with the songs in your One True Playlist. If it’s still there, choose Not Now."
        }
    }

    /// What "Make It Again" reports, including songs this device could not
    /// add, as Settings' rebuild does.
    static func remadeMessage(_ result: OneTruePlaylistRebuildService.Result) -> String {
        ["Made “\(result.name)” again in Apple Music with \(result.addedCount) songs.", result.skippedNote]
            .compactMap { $0 }.joined(separator: " ")
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
    /// Whether iCloud's copy of the library has this playlist; nil when it
    /// cannot tell, which never prompts. The sync that could not find it read
    /// this device's library, which can lag iCloud (a playlist made on
    /// another device, or a library still catching up), so this asks the web
    /// library instead of asking the device again.
    var playlistExists: (_ musicPlaylistID: String) async -> Bool? = { id in
        do {
            return try await AppleMusicLibraryPlaylistResources.exists(playlistID: id)
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
        return .missing(name: playlist.name, playlistID: playlist.musicPlaylistID)
    }

    /// Whether a "missing" answer still holds when the user says yes: the
    /// alert may have waited while another device made the playlist again
    /// (the One True Playlist now has another ID) or the library caught up.
    /// Nil when Apple Music could not be asked; only true makes anything.
    func isStillMissing(_ playlistID: String, in context: ModelContext) async -> Bool? {
        guard let playlist = try? PlaylistRepository.oneTruePlaylist(in: context),
              playlist.musicPlaylistID == playlistID else { return false }
        return await playlistExists(playlistID).map { !$0 }
    }
}
