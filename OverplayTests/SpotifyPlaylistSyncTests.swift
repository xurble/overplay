import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Spotify credentials repository")
struct SpotifyCredentialsRepositoryTests {
    @Test("upsert stores and updates credentials")
    func upsertStoresAndUpdatesCredentials() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let expiresAt = Date(timeIntervalSince1970: 1_000)

        let created = try SpotifyCredentialsRepository.upsert(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: expiresAt,
            scope: "playlist-read-private",
            spotifyUserID: "user-1",
            displayName: "Listener",
            in: context
        )

        let updated = try SpotifyCredentialsRepository.upsert(
            accessToken: "access-2",
            refreshToken: nil,
            expiresAt: expiresAt.addingTimeInterval(3600),
            scope: "playlist-read-private",
            spotifyUserID: "user-1",
            displayName: "Listener",
            in: context
        )

        #expect(created.id == updated.id)
        #expect(updated.accessToken == "access-2")
        #expect(updated.refreshToken == "refresh-1")
        #expect(updated.displayName == "Listener")
    }

    @Test("delete removes stored credentials")
    func deleteRemovesStoredCredentials() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        _ = try SpotifyCredentialsRepository.upsert(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: .distantFuture,
            scope: "playlist-read-private",
            spotifyUserID: "user-1",
            displayName: "Listener",
            in: context
        )

        try SpotifyCredentialsRepository.delete(in: context)

        #expect(try SpotifyCredentialsRepository.credentials(in: context) == nil)
    }
}

@MainActor
@Suite("Playlist source repository rules")
struct PlaylistSourceRepositoryTests {
    @Test("spotify playlists can only be added as triage")
    func spotifyPlaylistsCanOnlyBeAddedAsTriage() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let triage = try PlaylistRepository.addTriagePlaylist(
            RemotePlaylistLink(id: "spotify-1", name: "Discover Weekly", source: .spotify),
            in: context
        )

        #expect(triage.role == .triage)
        #expect(triage.source == .spotify)
        #expect(triage.writePolicy == .incomingOnly)
    }

    @Test("one true playlist rejects spotify source")
    func oneTruePlaylistRejectsSpotifySource() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        #expect(throws: PlaylistSyncError.unsupportedSourceForOneTruePlaylist) {
            try PlaylistRepository.upsert(
                remotePlaylist: RemotePlaylistLink(id: "spotify-1", name: "Main", source: .spotify),
                role: .oneTruePlaylist,
                in: context
            )
        }
    }

    @Test("playlist lookup distinguishes source by remote id")
    func playlistLookupDistinguishesSourceByRemoteID() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        _ = try PlaylistRepository.upsert(
            remotePlaylist: RemotePlaylistLink(id: "shared-id", name: "Apple", source: .appleMusic),
            role: .triage,
            in: context
        )
        _ = try PlaylistRepository.upsert(
            remotePlaylist: RemotePlaylistLink(id: "shared-id", name: "Spotify", source: .spotify),
            role: .triage,
            in: context
        )

        let apple = try #require(try PlaylistRepository.playlist(remotePlaylistID: "shared-id", source: .appleMusic, in: context))
        let spotify = try #require(try PlaylistRepository.playlist(remotePlaylistID: "shared-id", source: .spotify, in: context))

        #expect(apple.name == "Apple")
        #expect(spotify.name == "Spotify")
    }
}
