import Foundation
@preconcurrency import MusicKit

/// Every MusicKit write to an Apple Music playlist. Mac Catalyst has none
/// (add, create and edit are unavailable there), so on a Mac each throws and
/// the change waits for an iPhone or iPad.
@MainActor
enum AppleMusicPlaylistWrites {
    struct UnavailableOnMac: LocalizedError {
        var errorDescription: String? {
            "Apple Music playlists can only be changed from Overplay on an iPhone or iPad."
        }
    }

    static func add(_ song: Song, to playlist: Playlist) async throws {
#if targetEnvironment(macCatalyst)
        throw UnavailableOnMac()
#else
        try await MusicLibrary.shared.add(song, to: playlist)
#endif
    }

    static func createPlaylist(name: String, description: String) async throws -> Playlist {
#if targetEnvironment(macCatalyst)
        throw UnavailableOnMac()
#else
        try await MusicLibrary.shared.createPlaylist(name: name, description: description)
#endif
    }

    static func createPlaylist(name: String, description: String, items: [Track]) async throws -> Playlist {
#if targetEnvironment(macCatalyst)
        throw UnavailableOnMac()
#else
        try await MusicLibrary.shared.createPlaylist(name: name, description: description, items: items)
#endif
    }

    static func edit(_ playlist: Playlist, items: [Track]) async throws {
#if targetEnvironment(macCatalyst)
        throw UnavailableOnMac()
#else
        _ = try await MusicLibrary.shared.edit(playlist, items: items)
#endif
    }
}
