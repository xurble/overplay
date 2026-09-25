import Foundation
@preconcurrency import MusicKit

/// A lightweight, persisted observation of Apple Music's library playback
/// metadata. Both fields are optional because MusicKit doesn't expose them
/// for every item or every listening-history configuration.
struct MusicLibraryPlaybackSnapshot: Codable, Equatable, Sendable {
    var musicItemID: String
    var playCount: Int?
    var lastPlayedDate: Date?
    /// Nil for existing track observations. Entry counters are diagnostic only.
    var playlistEntryEvidence: Bool? = nil
}

struct MusicLibraryPlaybackObservation: Equatable, Sendable {
    var aliases: [String]
    var snapshot: MusicLibraryPlaybackSnapshot
    /// A conservative metadata match applies only to this local track; it is
    /// not a new global alias for playback or identity merging.
    var matchedTrackID: UUID? = nil
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
    /// Available to reconciliation diagnostics, never substituted for library proof.
    var entryObservations: [PlaylistEntryProvenance] = []
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
    /// Scan the local library, including songs whose library ID was never
    /// present in a playlist response. Follow every page before matching so
    /// an unseen duplicate cannot make a metadata match look unique.
    func libraryEntries(matching title: String? = nil) async throws -> [ApplePlayCountLibraryEntry] {
        var request = MusicLibraryRequest<Song>()
        request.limit = 500
        if let title { request.filter(text: title) }
        var entries: [ApplePlayCountLibraryEntry] = []
        while true {
            try Task.checkCancellation()
            let songs = try await MusicKitActivityLog.shared.measure(
                .libraryTrackQuery, detail: "play-count discovery offset=\(request.offset)"
            ) { try await request.response().items }
            guard !songs.isEmpty else { break }
            entries += songs.map { song in
                let identity = MusicTrackIdentity.ids(fromRawID: song.id.rawValue, playParameters: song.playParameters)
                let aliases = [song.id.rawValue, identity.catalogID, identity.libraryID].compactMap { $0 }
                return ApplePlayCountLibraryEntry(
                    track: ApplePlayCountMatchTrack(aliases: aliases, title: song.title, artist: song.artistName,
                        album: song.albumTitle, duration: song.duration, isrc: song.isrc),
                    observation: MusicLibraryPlaybackObservation(aliases: aliases, snapshot:
                        MusicLibraryPlaybackSnapshot(musicItemID: identity.libraryID ?? song.id.rawValue,
                            playCount: song.playCount, lastPlayedDate: song.lastPlayedDate)))
            }
            request.offset += songs.count
            await Task.yield()
        }
        return entries
    }

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
        let observations = try await observations(for: requestedIDs)
        var snapshotsByLocalTrackID: [String: MusicLibraryPlaybackSnapshot] = [:]
        for observation in observations {
            let matchedLocalTrackIDs = observation.aliases.reduce(into: Set<String>()) { result, alias in
                result.formUnion(localTrackIDsByMusicItemID[alias] ?? [])
            }
            for localTrackID in matchedLocalTrackIDs {
                snapshotsByLocalTrackID[localTrackID] = observation.snapshot
            }
        }
        return snapshotsByLocalTrackID
    }

    /// Keep distinct library counters even when they share a catalog alias.
    func observations(for requestedIDs: [String]) async throws -> [MusicLibraryPlaybackObservation] {
        guard !requestedIDs.isEmpty else { return [] }

        var request = MusicLibraryRequest<Track>()
        request.filter(
            matching: \.id,
            memberOf: requestedIDs.map { MusicItemID($0) }
        )
        request.limit = requestedIDs.count

        let tracks = try await MusicKitActivityLog.shared.measure(
            .libraryTrackQuery,
            magnitude: Double(requestedIDs.count),
            detail: "requested \(requestedIDs.count) ids"
        ) {
            try await request.response().items
        }
        return tracks.map { track in
            let identity = MusicTrackIdentity.ids(for: track)
            let aliases = [
                track.id.rawValue,
                identity.catalogID,
                identity.libraryID
            ].compactMap { $0 }
            let snapshot = MusicLibraryPlaybackSnapshot(
                musicItemID: identity.libraryID ?? track.id.rawValue,
                playCount: track.playCount,
                lastPlayedDate: track.lastPlayedDate
            )
            return MusicLibraryPlaybackObservation(aliases: aliases, snapshot: snapshot)
        }
    }
}
