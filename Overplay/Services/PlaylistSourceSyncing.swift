import Foundation
import SwiftData

struct PlaylistSourceFetchResult: Equatable, Sendable {
    var snapshots: [TrackSnapshot]
    var skippedCount: Int
    var skippedReason: String?
    /// The remote modification fingerprint to store, so a later automatic
    /// cycle can tell whether the playlist changed. Nil when the source
    /// does not report one.
    var remoteLastModifiedAt: Date?
    /// False when the adapter deliberately returned no snapshots because the
    /// remote playlist was unchanged, so the caller must keep the tracks it
    /// already has rather than reconciling against an empty list.
    var didFetchTracks: Bool = true
}

protocol PlaylistSourceSyncing {
    var source: PlaylistSource { get }

    func fetchLibraryPlaylists() async throws -> [RemotePlaylistLink]

    /// - Parameter skipWhenRemoteUnchanged: When true, the adapter may
    ///   return `didFetchTracks == false` instead of paging the playlist's
    ///   tracks, if the source can prove nothing changed. Automatic cycles
    ///   pass true; user-initiated syncs pass false so an explicit sync
    ///   always reads the real remote state.
    func fetchTrackSnapshots(
        playlistID: String,
        playlistName: String?,
        playlistRecord: PlaylistRecord?,
        skipWhenRemoteUnchanged: Bool,
        in context: ModelContext
    ) async throws -> PlaylistSourceFetchResult
}

@MainActor
struct PlaylistSourceSyncRegistry {
    private let adapters: [PlaylistSource: any PlaylistSourceSyncing]

    init(
        appleMusic: AppleMusicPlaylistSourceSync = AppleMusicPlaylistSourceSync()
    ) {
        adapters = [
            .appleMusic: appleMusic
        ]
    }

    func adapter(for source: PlaylistSource) -> any PlaylistSourceSyncing {
        guard let adapter = adapters[source] else {
            preconditionFailure("Missing playlist source adapter for \(source.rawValue)")
        }
        return adapter
    }

    func adapter(for playlist: PlaylistRecord) -> any PlaylistSourceSyncing {
        adapter(for: playlist.source)
    }
}
