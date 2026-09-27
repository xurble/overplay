import Foundation
import SwiftData

/// Deliberately contains configuration only. No track/counter/history decoder
/// exists at the reset boundary, so old graph corruption cannot be migrated.
struct LibraryRebuildConfiguration: Codable, Equatable, Sendable {
    struct Playlist: Codable, Equatable, Sendable {
        var musicPlaylistID: String
        var name: String
        var role: String
        var writePolicy: String
        var sortOrder: Int
    }
    var version: Int = 2
    var rebuildID: UUID
    var playlists: [Playlist]

    func validate() throws {
        guard version == 2,
              playlists.filter({ $0.role == "oneTruePlaylist" }).count == 1,
              Set(playlists.map(\.musicPlaylistID)).count == playlists.count,
              playlists.allSatisfy({
                  !$0.musicPlaylistID.isEmpty && !$0.name.isEmpty &&
                  $0.musicPlaylistID != "overplay.triage-bucket" &&
                  ["oneTruePlaylist", "triageSource"].contains($0.role) &&
                  ["managed", "incomingOnly"].contains($0.writePolicy)
              }) else { throw LibraryRebuildService.RebuildError.invalidConfiguration }
    }
}

@MainActor
enum LibraryRebuildService {
    enum RebuildError: LocalizedError {
        case invalidConfiguration, incompleteSource(String), storeNotEmpty
        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: "The saved playlist configuration is invalid. No songs were imported."
            case .incompleteSource(let name): "Apple Music did not provide a complete, verified snapshot of \(name). No songs were imported."
            case .storeNotEmpty: "The replacement library already contains data from another import. It was left unchanged."
            }
        }
    }

    static var configurationURL: URL {
        URL.documentsDirectory.appendingPathComponent("overplay-library-rebuild-v2.json")
    }

    static func performIfNeeded(in context: ModelContext) async throws {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else { return }
        let configuration = try JSONDecoder().decode(LibraryRebuildConfiguration.self, from: Data(contentsOf: configurationURL))
        try await rebuild(configuration, in: context) { link in
            try await AppleMusicPlaylistSourceSync().fetchTrackSnapshots(
                playlistID: link.musicPlaylistID, playlistName: link.name,
                playlistRecord: nil, skipWhenRemoteUnchanged: false, in: context
            )
        }
    }

    /// Read/resolve first; the private staging context is created only after
    /// every source succeeds. A single save publishes graph and receipt.
    @discardableResult
    static func rebuild(
        _ configuration: LibraryRebuildConfiguration,
        in context: ModelContext,
        fetch: (LibraryRebuildConfiguration.Playlist) async throws -> PlaylistSourceFetchResult
    ) async throws -> Bool {
        try configuration.validate()
        if try completed(configuration.rebuildID, in: context) { return false }
        try requireEmptyGraph(in: context)
        var fetched: [(LibraryRebuildConfiguration.Playlist, PlaylistSourceFetchResult)] = []
        for link in configuration.playlists.sorted(by: { $0.musicPlaylistID < $1.musicPlaylistID }) {
            let result = try await fetch(link)
            try Task.checkCancellation()
            guard result.didFetchTracks, result.didFetchEntries,
                  result.snapshots.allSatisfy({ $0.hasDocumentedIdentity && ($0.libraryID != nil || $0.catalogID != nil) }) else {
                throw RebuildError.incompleteSource(link.name)
            }
            fetched.append((link, result))
        }
        // Cloud delivery or another task may have populated the store while
        // MusicKit was suspended. Never overwrite it based on the earlier read.
        let staging = ModelContext(context.container)
        staging.autosaveEnabled = false
        if try completed(configuration.rebuildID, in: staging) { return false }
        try requireEmptyGraph(in: staging)
        do {
            let settings = try staging.fetch(FetchDescriptor<OverplaySettings>()).first ?? OverplaySettings()
            if settings.modelContext == nil { staging.insert(settings) }
            let bucket = PlaylistRecord(musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
                                        name: PlaylistRecord.triageBucketName, role: .triageBucket,
                                        writePolicy: .incomingOnly)
            staging.insert(bucket)
            let now = Date.now
            // OTP goes first. Shared repository identity matching then attaches
            // all later source occurrences to the already-owned membership.
            fetched.sort {
                if ($0.0.role == "oneTruePlaylist") != ($1.0.role == "oneTruePlaylist") {
                    return $0.0.role == "oneTruePlaylist"
                }
                return $0.0.musicPlaylistID < $1.0.musicPlaylistID
            }
            for (link, result) in fetched {
                let isOTP = link.role == "oneTruePlaylist"
                let playlist = PlaylistRecord(musicPlaylistID: link.musicPlaylistID, name: link.name,
                    role: isOTP ? .oneTruePlaylist : .triageSource,
                    writePolicy: link.writePolicy == "managed" ? .managed : .incomingOnly,
                    lastSyncedAt: now, remoteLastModifiedAt: result.remoteLastModifiedAt, sortOrder: link.sortOrder)
                playlist.hasSyncedPlaylistEntries = true
                playlist.triageLinkedAt = isOTP ? nil : now
                staging.insert(playlist)
                if isOTP {
                    settings.selectedPlaylistID = link.musicPlaylistID
                    settings.selectedPlaylistName = link.name
                }
                for (position, snapshot) in result.snapshots.enumerated() {
                    let track = try TrackRecordRepository.upsert(snapshot, in: staging)
                    let item: PlaylistItemRecord
                    if let existing = try PlaylistItemRepository.item(trackID: track.id, in: staging) {
                        item = existing
                    } else {
                        item = PlaylistItemRecord(playlistID: isOTP ? playlist.id : bucket.id, trackID: track.id)
                        item.sortOrder = position
                        staging.insert(item)
                    }
                    if !isOTP, !item.sourceMusicPlaylistIDs.contains(link.musicPlaylistID) {
                        item.sourceMusicPlaylistIDs.append(link.musicPlaylistID)
                    }
                    item.entryProvenance = PlaylistEntryProvenance.merging(item.entryProvenance + [
                        PlaylistEntryProvenance(snapshot: snapshot, playlistID: link.musicPlaylistID, observedAt: now)
                    ])
                    item.lastSeenInPlaylistAt = now
                    if item.musicPlaylistEntryID == nil { item.musicPlaylistEntryID = snapshot.playlistEntryID }
                }
            }
            settings.completedRebuildID = configuration.rebuildID
            try staging.save()
            StartupProfiler.mark("Library rebuild completed: \(configuration.playlists.count) sources")
            return true
        } catch {
            staging.rollback()
            throw error
        }
    }

    private static func completed(_ id: UUID, in context: ModelContext) throws -> Bool {
        try context.fetch(FetchDescriptor<OverplaySettings>()).contains { $0.completedRebuildID == id }
    }

    private static func requireEmptyGraph(in context: ModelContext) throws {
        guard try context.fetchCount(FetchDescriptor<PlaylistRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<TrackRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<PlaylistItemRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<HistoryEvent>()) == 0,
              try context.fetchCount(FetchDescriptor<ApplePlayCountRecord>()) == 0 else {
            throw RebuildError.storeNotEmpty
        }
    }
}
