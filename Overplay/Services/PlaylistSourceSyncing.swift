import Foundation
import SwiftData

struct PlaylistSourceFetchResult: Equatable, Sendable {
    var snapshots: [TrackSnapshot]
    var skippedCount: Int
    var skippedReason: String?
}

protocol PlaylistSourceSyncing {
    var source: PlaylistSource { get }

    func fetchLibraryPlaylists(in context: ModelContext) async throws -> [RemotePlaylistLink]
    func fetchTrackSnapshots(
        playlistID: String,
        playlistName: String?,
        playlistRecord: PlaylistRecord?,
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
