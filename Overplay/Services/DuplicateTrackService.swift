import Foundation
import SwiftData

@MainActor
enum DuplicateTrackService {
    enum Destination: String, CaseIterable, Identifiable {
        case otp = "One True Playlist", triage = "Triage", retired = "Retired"
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
        var skips: Int
        var keys: Set<String> {
            var values = Set(([catalogID, libraryID].compactMap { $0 } + aliases).map { "id:" + $0 })
            if let isrc, !isrc.isEmpty { values.insert("isrc:" + isrc) }
            values.formUnion(equivalents.map { "id:" + $0 })
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
        var candidates: [Candidate]
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
                             equivalents: track.equivalentCatalogIDs, plays: item.playthroughCount, skips: item.skipCount)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Index keys rather than compare every pair in a large library. A connected
    /// group is a suggestion only; the user selects the actual recordings.
    static func groups(_ candidates: [Candidate]) -> [Group] {
        var groups: [Set<UUID>] = []
        var groupByKey: [String: Int] = [:]
        for candidate in candidates {
            let existing = Set(candidate.keys.compactMap { groupByKey[$0] })
            let index = existing.min() ?? groups.count
            if index == groups.count { groups.append([]) }
            groups[index].insert(candidate.id)
            for other in existing where other != index {
                groups[index].formUnion(groups[other]); groups[other].removeAll()
                for key in Array(groupByKey.keys) where groupByKey[key] == other { groupByKey[key] = index }
            }
            for key in candidate.keys { groupByKey[key] = index }
        }
        return groups.filter { $0.count > 1 }.map { ids in Group(candidates: candidates.filter { ids.contains($0.id) }) }
    }

    static func scan(in context: ModelContext, resolver: MusicIdentityResolver = .shared) async throws -> [Group] {
        let tracks = try TrackRecordRepository.allTracks(in: context)
        let snapshots = tracks.map { track in
            var snapshot = TrackSnapshot(id: track.catalogID ?? track.libraryID ?? track.id.uuidString,
                catalogID: track.catalogID, libraryID: track.libraryID, playlistEntryID: nil, playlistID: nil,
                title: track.title, artistName: track.artistName, albumTitle: track.albumTitle,
                artworkURLTemplate: track.artworkURLTemplate, durationSeconds: track.durationSeconds)
            snapshot.isrc = track.isrc
            return snapshot
        }
        let enriched = try await resolver.enrich(snapshots)
        try Task.checkCancellation()
        for (index, track) in tracks.enumerated() where !track.isDeleted {
            let snapshot = enriched[index]
            // Do not replace a newer sync's identity while the scan was awaiting.
            if track.catalogID == snapshots[index].catalogID, track.libraryID == snapshots[index].libraryID {
                TrackRecordRepository.applyIdentity(snapshot, to: track)
            }
        }
        try context.save()
        return groups(try candidates(in: context))
    }

    static func validate(_ selected: [Candidate], destination: Destination?, in context: ModelContext) throws -> Destination {
        guard Set(selected.map(\.id)).count == selected.count, selected.count >= 2,
              groups(selected).count == 1, groups(selected).first?.candidates.count == selected.count else { throw MergeError.selection }
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
        track.identityAliases = Array(Set(track.identityAliases + [track.catalogID, track.libraryID].compactMap { $0 })).sorted()
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
        PlaybackOrderStore.rekeyLocalTrackIDs(mapping, from: defaults, flushImmediately: true)
        PlaybackIdentityStore.rekeyLocalTrackIDs(mapping, from: defaults, flushImmediately: true)
        LocalPlaybackStateStore.rekeyLocalTrackIDs(mapping, from: defaults, flushImmediately: true)
        return Result(trackID: track.id, itemID: item.id, mapping: mapping,
                      remoteRemovalIDs: Array(Set(removals)), previousOTP: otp)
    }
}
