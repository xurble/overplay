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
        case .missing:
            return "Overplay can’t find its playlist in your Apple Music library. If you deleted it, Overplay can make it again with the songs in your One True Playlist. If it’s still there, choose Not Now."
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
    /// Whether iCloud's complete library playlist list contains this ID; nil when it
    /// cannot tell, which never prompts. The sync that could not find it read
    /// this device's library, which can lag iCloud (a playlist made on
    /// another device, or a library still catching up), so this asks the web
    /// library instead of asking the device again.
    var playlistExists: (_ musicPlaylistID: String) async -> Bool? = { id in
        do {
            return try await AppleMusicLibraryPlaylistResources.exists(playlistID: id)
        } catch {
            MusicKitActivityLog.shared.record(.diagnosticNote, detail: "OTP presence result=unknown after web library membership check")
            return nil
        }
    }

    /// What to ask, or nil when nothing needs making or this device cannot.
    /// `checksPresence` looks the playlist up in Apple Music. Callers either
    /// saw a missing playlist during sync or waited for quiet playback after
    /// the launch grace period (`LOAD-001`).
    func prompt(in context: ModelContext, checksPresence: Bool) async -> OneTruePlaylistPrompt? {
        guard canCreatePlaylists() else {
            MusicKitActivityLog.shared.record(.diagnosticNote, detail: "OTP prompt suppressed: device cannot create playlists")
            return nil
        }
        guard let settings = try? context.fetch(FetchDescriptor<OverplaySettings>()).first else {
            MusicKitActivityLog.shared.record(.diagnosticNote, detail: "OTP prompt suppressed: settings unavailable")
            return nil
        }
        guard settings.selectedPlaylistID != nil else {
            guard settings.pendingOneTruePlaylistRequestedAt != nil else {
                MusicKitActivityLog.shared.record(.diagnosticNote, detail: "OTP prompt suppressed: no selected playlist or pending request")
                return nil
            }
            MusicKitActivityLog.shared.record(.diagnosticNote, detail: "OTP prompt candidate: pending Mac request")
            return .requestedByMac(sourceName: settings.pendingOneTruePlaylistSourceName)
        }
        guard checksPresence else {
            MusicKitActivityLog.shared.record(.diagnosticNote, detail: "OTP prompt suppressed: presence check not requested")
            return nil
        }
        guard let playlist = try? PlaylistRepository.oneTruePlaylist(in: context) else {
            MusicKitActivityLog.shared.record(.diagnosticNote, detail: "OTP prompt suppressed: local playlist unavailable")
            return nil
        }
        let exists = await playlistExists(playlist.musicPlaylistID)
        guard exists == false else {
            MusicKitActivityLog.shared.record(.diagnosticNote, detail: "OTP prompt suppressed: web presence \(exists == true ? "present" : "unknown")")
            return nil
        }
        MusicKitActivityLog.shared.record(.diagnosticNote, detail: "OTP prompt candidate: web presence missing")
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
