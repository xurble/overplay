import Foundation
import SwiftData

@MainActor
struct SpotifyPlaylistSourceSync: PlaylistSourceSyncing {
    let source: PlaylistSource = .spotify

    private let authorizationService: SpotifyAuthorizationService
    private let apiClient: SpotifyAPIClient
    private let matcher: SpotifyToAppleMusicTrackMatcher

    init(
        authorizationService: SpotifyAuthorizationService = SpotifyAuthorizationService(),
        apiClient: SpotifyAPIClient = SpotifyAPIClient(),
        matcher: SpotifyToAppleMusicTrackMatcher = SpotifyToAppleMusicTrackMatcher()
    ) {
        self.authorizationService = authorizationService
        self.apiClient = apiClient
        self.matcher = matcher
    }

    func fetchLibraryPlaylists(in context: ModelContext) async throws -> [RemotePlaylistLink] {
        let accessToken = try await authorizationService.validAccessToken(in: context)
        let playlists = try await apiClient.fetchPlaylists(accessToken: accessToken)
        return playlists
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(RemotePlaylistLink.init)
    }

    func fetchTrackSnapshots(
        playlistID: String,
        playlistName: String?,
        playlistRecord: PlaylistRecord?,
        in context: ModelContext
    ) async throws -> PlaylistSourceFetchResult {
        let accessToken = try await authorizationService.validAccessToken(in: context)
        let spotifyTracks = try await apiClient.fetchPlaylistTracks(playlistID: playlistID, accessToken: accessToken)

        var snapshots: [TrackSnapshot] = []
        var skippedCount = 0

        for spotifyTrack in spotifyTracks {
            do {
                let snapshot = try await matcher.match(spotifyTrack, playlistID: playlistID)
                snapshots.append(snapshot)
            } catch {
                skippedCount += 1
            }
        }

        let skippedReason: String? = skippedCount > 0
            ? "\(skippedCount) Spotify tracks could not be matched to Apple Music."
            : nil

        return PlaylistSourceFetchResult(
            snapshots: snapshots,
            skippedCount: skippedCount,
            skippedReason: skippedReason
        )
    }
}
