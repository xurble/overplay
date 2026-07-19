import Foundation
@preconcurrency import MusicKit

/// A lightweight, persisted observation of Apple Music's library playback
/// metadata. Both fields are optional because MusicKit doesn't expose them
/// for every item or every listening-history configuration.
struct MusicLibraryPlaybackSnapshot: Codable, Equatable, Sendable {
    var musicItemID: String
    var playCount: Int?
    var lastPlayedDate: Date?
}

struct MusicLibraryPlaybackBaseline: Codable, Equatable, Sendable {
    var playlistID: String
    var localTrackID: String
    var recordedAt: Date
    var snapshot: MusicLibraryPlaybackSnapshot
}

struct MusicLibraryPlaybackCandidate: Equatable, Sendable {
    var localTrackID: String
    var musicItemIDs: [String]
}

@MainActor
protocol MusicLibraryPlaybackHistoryFetching {
    func snapshots(
        for candidates: [MusicLibraryPlaybackCandidate]
    ) async throws -> [String: MusicLibraryPlaybackSnapshot]
}

/// Fetches the two Apple Music library counters used as corroborating
/// evidence during suspended-playback reconciliation. A wake queries the
/// current track and a bounded set of unresolved baselines in one request.
@MainActor
struct MusicKitLibraryPlaybackHistoryFetcher: MusicLibraryPlaybackHistoryFetching {
    func snapshots(
        for candidates: [MusicLibraryPlaybackCandidate]
    ) async throws -> [String: MusicLibraryPlaybackSnapshot] {
        let localTrackIDsByMusicItemID = candidates.reduce(
            into: [String: Set<String>]()
        ) { result, candidate in
            for musicItemID in candidate.musicItemIDs where !musicItemID.isEmpty {
                result[musicItemID, default: []].insert(candidate.localTrackID)
            }
        }
        let requestedIDs = localTrackIDsByMusicItemID.keys.sorted()
        guard !requestedIDs.isEmpty else { return [:] }

        var request = MusicLibraryRequest<Track>()
        request.filter(
            matching: \.id,
            memberOf: requestedIDs.map { MusicItemID($0) }
        )
        request.limit = requestedIDs.count

        let tracks = try await request.response().items
        var snapshotsByLocalTrackID: [String: MusicLibraryPlaybackSnapshot] = [:]
        for track in tracks {
            let identity = MusicTrackIdentity.ids(for: track)
            let aliases = [
                track.id.rawValue,
                identity.catalogID,
                identity.libraryID
            ].compactMap { $0 }
            let matchedLocalTrackIDs = aliases.reduce(into: Set<String>()) { result, alias in
                result.formUnion(localTrackIDsByMusicItemID[alias] ?? [])
            }
            let snapshot = MusicLibraryPlaybackSnapshot(
                musicItemID: identity.libraryID ?? track.id.rawValue,
                playCount: track.playCount,
                lastPlayedDate: track.lastPlayedDate
            )
            for localTrackID in matchedLocalTrackIDs {
                snapshotsByLocalTrackID[localTrackID] = snapshot
            }
        }
        return snapshotsByLocalTrackID
    }
}
