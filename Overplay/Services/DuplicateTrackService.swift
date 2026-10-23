import Foundation
@preconcurrency import MusicKit
import SwiftData

@MainActor
enum DuplicateTrackService {
    enum Destination: String, CaseIterable, Identifiable {
        case otp = "One True Playlist", triage = "Inbox", retired = "Retired"
        var id: String { rawValue }
    }
    struct Candidate: Identifiable, Equatable {
        var id: UUID
        var itemID: UUID
        var title: String
        var artist: String
        var album: String?
        var destination: Destination
        var playlistID: UUID
        var locationChangedAt: Date?
        var catalogID: String?
        var libraryID: String?
        var isrc: String?
        var aliases: [String]
        var equivalents: [String]
        var plays: Int
        var applePlays: Int? = nil
        var skips: Int
        /// What says two songs are the same recording.
        var identityKeys: Set<String> {
            var values = Set(([catalogID, libraryID].compactMap { $0 } + aliases).map { "id:" + $0 })
            if let isrc, !isrc.isEmpty { values.insert("isrc:" + isrc) }
            values.formUnion(equivalents.map { "id:" + $0 })
            return values
        }
        /// Identity, and a near-identical title and artist.
        var keys: Set<String> {
            var values = identityKeys
            if let name = DuplicateNameKey.make(title: title, artist: artist) { values.insert(name) }
            return values
        }
        // Counts can increase during review; merge reads live values. Location
        // and identity changes require a new review.
        func stillMatches(_ other: Candidate) -> Bool {
            id == other.id && itemID == other.itemID && destination == other.destination
                && playlistID == other.playlistID && locationChangedAt == other.locationChangedAt
                && catalogID == other.catalogID && libraryID == other.libraryID
                && isrc == other.isrc && aliases == other.aliases && equivalents == other.equivalents
        }
    }
    struct Group: Identifiable {
        enum Reason { case sameRecording, sameNameAndArtist }
        var candidates: [Candidate]
        /// Same recording when the songs' IDs or ISRCs alone join them;
        /// otherwise only their names do, and they may be different recordings.
        var reason: Reason = .sameRecording
        var id: UUID { candidates[0].id }
    }
    struct Result {
        var trackID: UUID
        var itemID: UUID
        var mapping: [String: String]
        var remoteRemovalIDs: [String]
        var previousOTP: PlaylistRecord?
    }
    enum MergeError: LocalizedError {
        case stale, selection, destinationRequired, missingOTP
        var errorDescription: String? {
            switch self {
            case .stale: "These tracks changed since the scan. Scan again before merging."
            case .selection: "Select at least two related tracks to merge."
            case .destinationRequired: "Choose where to keep the merged track."
            case .missingOTP: "Choose a One True Playlist first."
            }
        }
    }

    static func candidates(in context: ModelContext) throws -> [Candidate] {
        let tracks = try TrackRecordRepository.allTracks(in: context).firstValueDictionary(keyedBy: \.id)
        let playlists = try PlaylistRepository.allPlaylists(in: context).firstValueDictionary(keyedBy: \.id)
        return try PlaylistItemRepository.allItems(in: context).compactMap { item in
            guard let track = tracks[item.trackID], let playlist = playlists[item.playlistID],
                  playlist.role.isPlaybackContext else { return nil }
            let destination: Destination = item.evictedAt != nil ? .retired : playlist.isTriageBucket ? .triage : .otp
            return Candidate(id: track.id, itemID: item.id, title: track.title, artist: track.artistName,
                             album: track.albumTitle, destination: destination, playlistID: item.playlistID,
                             locationChangedAt: item.locationChangedAt, catalogID: track.catalogID,
                             libraryID: track.libraryID, isrc: track.isrc, aliases: track.identityAliases,
                             equivalents: track.equivalentCatalogIDs, plays: item.playthroughCount, applePlays: item.applePlayCount, skips: item.skipCount)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Index keys rather than compare every pair in a large library. A connected
    /// group is a suggestion only; the user selects the actual recordings.
    static func groups(_ candidates: [Candidate]) -> [Group] {
        let byKeys = components(candidates, keys: \.keys)
        let byIdentity = components(candidates, keys: \.identityKeys)
        return byKeys.groups.filter { $0.count > 1 }.map { indices in
            // One identity component covering the whole group: same recording.
            let sameRecording = Set(indices.map { byIdentity.root[$0] }).count == 1
            return Group(candidates: indices.map { candidates[$0] }, reason: sameRecording ? .sameRecording : .sameNameAndArtist)
        }
    }

    /// Connected candidates by shared key, in one pass (union-find): a large
    /// library groups in a blink rather than re-scanning every key on a join.
    private static func components(
        _ candidates: [Candidate], keys: (Candidate) -> Set<String>
    ) -> (groups: [[Int]], root: [Int]) {
        var parent = Array(candidates.indices)
        func find(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
            return index
        }
        var owner: [String: Int] = [:]
        for index in candidates.indices {
            for key in keys(candidates[index]) {
                if let other = owner[key] {
                    let a = find(index), b = find(other)
                    if a != b { parent[max(a, b)] = min(a, b) }
                } else {
                    owner[key] = index
                }
            }
        }
        let roots = candidates.indices.map(find)
        var members: [Int: [Int]] = [:]
        var order: [Int] = []
        for index in candidates.indices {
            if members[roots[index]] == nil { order.append(roots[index]) }
            members[roots[index], default: []].append(index)
        }
        return (order.map { members[$0]! }, roots)
    }

    static func isUnanswered(_ error: Error) -> Bool {
        if case MusicIdentityResolver.ResolutionError.incompleteResponse = error { return true }
        if let request = error as? MusicDataRequest.Error { return isUnansweredStatus(request.status) }
        return false
    }

    /// A request Apple Music refused for what it asked about (400 Bad Request,
    /// 404, 422), not for who asked or when (401, 403, 429) or a server fault.
    static func isUnansweredStatus(_ status: Int) -> Bool {
        (400..<500).contains(status) && ![401, 403, 429].contains(status)
    }

    struct ScanResult {
        var groups: [Group]
        /// Songs sent to Apple Music: only those matched by name alone.
        var checkedCount: Int
        /// Songs Apple Music could not answer for, matched on what Overplay
        /// already knew about them.
        var uncheckedCount: Int
    }

    /// At once, from what Overplay already knows: shared IDs and ISRCs, and
    /// near-identical titles and artists. No Apple Music call.
    static func localScan(in context: ModelContext) throws -> [Group] {
        groups(try candidates(in: context))
    }

    /// Asks Apple Music only about songs grouped by name alone, which may be
    /// the same recording or not; songs already joined by ID or ISRC, and
    /// songs with no near match, are never sent.
    static func confirmNameMatches(
        _ local: [Group], in context: ModelContext, resolver: MusicIdentityResolver = .shared
    ) async throws -> ScanResult {
        let ids = Set(local.filter { $0.reason == .sameNameAndArtist }.flatMap { $0.candidates.map(\.id) })
        let tracks = try TrackRecordRepository.allTracks(in: context).filter { ids.contains($0.id) }
        guard !tracks.isEmpty else { return ScanResult(groups: local, checkedCount: 0, uncheckedCount: 0) }
        let snapshots = tracks.map { track in
            var snapshot = TrackSnapshot(id: track.catalogID ?? track.libraryID ?? track.id.uuidString,
                catalogID: track.catalogID, libraryID: track.libraryID, playlistEntryID: nil, playlistID: nil,
                title: track.title, artistName: track.artistName, albumTitle: track.albumTitle,
                artworkURLTemplate: track.artworkURLTemplate, durationSeconds: track.durationSeconds)
            snapshot.isrc = track.isrc
            return snapshot
        }
        let (enriched, checked) = try await enrichSkippingUnanswered(snapshots, resolver: resolver)
        try Task.checkCancellation()
        for (index, track) in tracks.enumerated() where !track.isDeleted && checked[index] {
            let snapshot = enriched[index]
            // Do not replace a newer sync's identity while the scan was awaiting.
            if track.catalogID == snapshots[index].catalogID, track.libraryID == snapshots[index].libraryID {
                TrackRecordRepository.applyIdentity(snapshot, to: track)
            }
        }
        try context.save()
        return ScanResult(groups: groups(try candidates(in: context)), checkedCount: tracks.count,
                          uncheckedCount: checked.count { !$0 })
    }

    static func scan(in context: ModelContext, resolver: MusicIdentityResolver = .shared) async throws -> ScanResult {
        try await confirmNameMatches(try localScan(in: context), in: context, resolver: resolver)
    }

    /// Apple Music may not answer for some songs (one removed from the
    /// library, or an ID it rejects as malformed), and one such song fails the
    /// whole request. Imports stop there; a scan only suggests, so it halves
    /// the request until it finds the song and goes on without it. Answers
    /// already fetched are cached, so only the failing part is asked again.
    /// Access, rate-limit, server and network failures still end the scan.
    static func enrichSkippingUnanswered(
        _ snapshots: [TrackSnapshot], resolver: MusicIdentityResolver
    ) async throws -> (snapshots: [TrackSnapshot], checked: [Bool]) {
        guard !snapshots.isEmpty else { return ([], []) }
        do {
            return (try await resolver.enrich(snapshots), Array(repeating: true, count: snapshots.count))
        } catch where isUnanswered(error) {
            guard snapshots.count > 1 else { return (snapshots, [false]) }
            let middle = snapshots.count / 2
            let first = try await enrichSkippingUnanswered(Array(snapshots[..<middle]), resolver: resolver)
            let second = try await enrichSkippingUnanswered(Array(snapshots[middle...]), resolver: resolver)
            return (first.snapshots + second.snapshots, first.checked + second.checked)
        }
    }

    static func validate(_ selected: [Candidate], destination: Destination?, in context: ModelContext) throws -> Destination {
        guard Set(selected.map(\.id)).count == selected.count, selected.count >= 2,
              groups(selected).count == 1, groups(selected).first?.candidates.count == selected.count else { throw MergeError.selection }
        // CloudKit cannot enforce a unique statistics row. A row arriving
        // after review must not be hidden by the dictionary below and orphaned
        // when its track is deleted. Include all owners, even inactive sources.
        let itemsByTrack = Dictionary(grouping: try PlaylistItemRepository.items(
            forTrackIDs: selected.map(\.id), in: context
        ), by: \.trackID)
        guard selected.allSatisfy({ candidate in
            let items = itemsByTrack[candidate.id] ?? []
            return items.count == 1 && items.first?.id == candidate.itemID
        }) else { throw MergeError.stale }
        let live = try candidates(in: context).firstValueDictionary(keyedBy: \.id)
        guard selected.allSatisfy({ old in live[old.id].map { old.stillMatches($0) } == true }) else { throw MergeError.stale }
        let destinations = Set(selected.map(\.destination))
        if destinations.count == 1 { return selected[0].destination }
        guard let destination else { throw MergeError.destinationRequired }
        if destination == .otp, try PlaylistRepository.oneTruePlaylist(in: context) == nil { throw MergeError.missingOTP }
        return destination
    }

    /// Validate both row intent and the configured OTP again inside the remote
    /// gate. Suppression survives a failed/stale completion, just as promotion
    /// does, so subsequent incoming sync cannot undo a newer local decision.
    static func prepareOTPMembership(
        _ selected: [Candidate], in context: ModelContext,
        mutation: PlaylistMutationService = PlaylistMutationService()
    ) async throws {
        guard let otp = try PlaylistRepository.oneTruePlaylist(in: context),
              let first = selected.sorted(by: { $0.id.uuidString < $1.id.uuidString }).first,
              let track = try TrackRecordRepository.track(id: first.id, in: context),
              let item = try PlaylistItemRepository.item(id: first.itemID, in: context) else { throw MergeError.missingOTP }
        let otpID = otp.id
        try await mutation.ensureRemoteMembership(track: track, playlist: otp, isCurrent: {
            guard try PlaylistRepository.oneTruePlaylist(in: context)?.id == otpID else { return false }
            _ = try validate(selected, destination: .otp, in: context)
            return true
        }, beforeAdd: {
            if !item.suppressedOTPMusicPlaylistIDs.contains(otp.musicPlaylistID) {
                item.suppressedOTPMusicPlaylistIDs.append(otp.musicPlaylistID)
            }
            try context.save()
        }, in: context)
    }

    /// Synchronous commit after remote preflight; no await between validation,
    /// reading live counts and deleting donor rows.
    static func merge(_ selected: [Candidate], destination: Destination?, in context: ModelContext,
                      defaults: UserDefaults = .standard) throws -> Result {
        let destination = try validate(selected, destination: destination, in: context)
        let ordered = selected.sorted {
            if ($0.destination == destination) != ($1.destination == destination) { return $0.destination == destination }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard let track = try TrackRecordRepository.track(id: ordered[0].id, in: context),
              let item = try PlaylistItemRepository.item(id: ordered[0].itemID, in: context) else { throw MergeError.stale }
        let otp = try PlaylistRepository.oneTruePlaylist(in: context)
        if destination == .otp, otp == nil { throw MergeError.missingOTP }
        let bucket = try PlaylistRepository.triageBucket(in: context)
        // Each identity's pre-ledger counts must become baselines before the
        // lineage joins them, or a donor's legacy counts could be shadowed.
        try ListenLedger.migrateLegacyCounts(forTrackIDs: Set(ordered.map(\.id)), in: context)
        var mapping: [String: String] = [:]
        var removals: [String] = []
        for candidate in ordered {
            if candidate.destination == .otp, destination != .otp {
                removals += [candidate.catalogID, candidate.libraryID].compactMap { $0 } + candidate.aliases
            }
        }
        for candidate in ordered.dropFirst() {
            guard let donor = try TrackRecordRepository.track(id: candidate.id, in: context),
                  let donorItem = try PlaylistItemRepository.item(id: candidate.itemID, in: context) else { throw MergeError.stale }
            TrackIdentityMergeService.absorb(donor, into: track, confirmed: true)
            PlaylistItemRepository.mergeStats(from: donorItem, into: item,
                adoptEvictionStateIfNewer: Set(selected.map(\.destination)).count == 1)
            try TrackIdentityMergeService.repointHistoryEvents(from: donor, to: track, in: context)
            mapping[donor.id.uuidString] = track.id.uuidString
            context.delete(donorItem)
            context.delete(donor)
        }
        // Also keep the canonical identifiers before future enrichment changes them.
        track.confirmedAliases = Array(track.identityReferences).sorted { ($0.domain.rawValue, $0.scope, $0.value) < ($1.domain.rawValue, $1.scope, $1.value) }
        if !removals.isEmpty, let otp { item.suppressedOTPMusicPlaylistIDs = Array(Set(item.suppressedOTPMusicPlaylistIDs + [otp.musicPlaylistID])) }
        if Set(selected.map(\.destination)).count > 1 {
            switch destination {
            case .otp:
                TrackLocationService.moveToOTP(item, playlist: otp!, source: .user, in: context)
            case .triage:
                try TrackLocationService.moveToTriage(item, explicitKeep: true, in: context)
            case .retired:
                try TrackLocationService.retire(item, playlist: otp ?? bucket, reason: .manual, source: .user,
                    message: "Retired by duplicate merge", preserveForMerge: true, in: context)
            }
        }
        item.pendingRetentionCleanup = false
        track.updatedAt = .now
        for playlist in try PlaylistRepository.allPlaylists(in: context) {
            playlist.triageExcludedTrackIDs = Array(Set(playlist.triageExcludedTrackIDs.map { mapping[$0] ?? $0 }))
        }
        try context.save()
        TrackRetentionPolicy.rekeyPlaybackTracks(mapping)
        return Result(trackID: track.id, itemID: item.id, mapping: mapping,
                      remoteRemovalIDs: Array(Set(removals)), previousOTP: otp)
    }
}
