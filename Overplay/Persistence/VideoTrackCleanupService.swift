import Foundation
@preconcurrency import MusicKit
import SwiftData

nonisolated enum VideoTrackPolicy {
    static func isSong(_ track: Track) -> Bool {
        if case .song = track { return true }
        return false
    }

    static func isVideo(playbackData: Data?) -> Bool {
        guard let playbackData,
              let track = try? JSONDecoder().decode(Track.self, from: playbackData) else { return false }
        if case .musicVideo = track { return true }
        return false
    }
}

enum TrackImportError: LocalizedError {
    case videoNotSupported

    var errorDescription: String? { "Video tracks cannot be imported into Overplay." }
}

/// Repeatable rather than version-gated: older devices can deliver legacy rows later.
/// This only deletes Overplay data, never the original Apple Music library items.
enum VideoTrackCleanupService {
    /// Decoding every track's playback data is the slow part, so it runs on a
    /// low-priority background task; only the deletions touch the main context.
    @discardableResult
    static func removeVideos(
        knownVideoIDs: Set<String> = [],
        inspectPlaybackData: Bool = true,
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) async throws -> Int {
        let span = PerformanceSpan(.videoCleanup)
        defer { span.finish(detail: inspectPlaybackData ? "full scan" : "known IDs") }
        guard inspectPlaybackData || !knownVideoIDs.isEmpty else { return 0 }
        var videoIDs = Set(try TrackRecordRepository.allTracks(in: context).filter { track in
            !knownVideoIDs.isDisjoint(with: [track.catalogID, track.libraryID].compactMap { $0 } + track.identityAliases)
        }.map(\.id))
        if inspectPlaybackData {
            let trackIDs = try TrackRecordRepository.allTracks(in: context).map(\.id)
            videoIDs.formUnion(await Task.detached(priority: .utility) { videoTrackIDs(among: trackIDs) }.value)
        }
        guard !videoIDs.isEmpty else { return 0 }
        // Re-read after the await: a sync or merge may have changed the store.
        let videos = try TrackRecordRepository.allTracks(in: context).filter { videoIDs.contains($0.id) }
        guard !videos.isEmpty else { return 0 }
        let trackIDs = Set(videos.map(\.id))
        let localIDs = Set(trackIDs.map(\.uuidString))
        var absorbed: Set<UUID> = []
        for video in videos { absorbed.formUnion(try ListenLedger.identities(for: video.id, in: context)) }
        absorbed.subtract(trackIDs)
        // UUID references are not SwiftData relationships, so remove dependents explicitly.
        for item in try PlaylistItemRepository.allItems(in: context) where trackIDs.contains(item.trackID) {
            context.delete(item)
        }
        for event in try context.fetch(FetchDescriptor<HistoryEvent>()) {
            if let trackID = event.trackID, trackIDs.contains(trackID) { context.delete(event) }
        }
        for video in videos { context.delete(video) }
        try context.save()
        try removeRowsOfAbsorbedTracks(absorbed, in: context)

        if let waypoint = PlaybackWaypointStore.load(from: defaults), localIDs.contains(waypoint.localTrackID) {
            PlaybackWaypointStore.clear(from: defaults, flushImmediately: true)
        }
        return videos.count
    }

    /// Tracks a removed video had absorbed by merging went with it. A
    /// membership or history event of one, left over or written again,
    /// would wait for a survivor that is gone (`LOC-002`), so it goes too,
    /// unless another merge kept that track.
    private static func removeRowsOfAbsorbedTracks(_ absorbed: Set<UUID>, in context: ModelContext) throws {
        var orphaned: Set<UUID> = []
        for trackID in absorbed
        where try TrackRecordRepository.track(id: trackID, in: context) == nil
            && ListenLedger.keeper(absorbing: trackID, in: context) == nil {
            orphaned.insert(trackID)
        }
        guard !orphaned.isEmpty else { return }
        for item in try PlaylistItemRepository.items(forTrackIDs: Array(orphaned), in: context) {
            context.delete(item)
        }
        let eventTrackIDs: [UUID?] = Array(orphaned)
        for event in try context.fetch(FetchDescriptor<HistoryEvent>(predicate: #Predicate { eventTrackIDs.contains($0.trackID) })) {
            context.delete(event)
        }
        try context.save()
    }

    nonisolated private static func videoTrackIDs(among trackIDs: [UUID]) -> Set<UUID> {
        Set(trackIDs.filter { VideoTrackPolicy.isVideo(playbackData: DevicePlaybackCache.shared.data(for: $0)) })
    }
}
