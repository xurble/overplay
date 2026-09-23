import Foundation
@preconcurrency import MusicKit
import SwiftData

enum VideoTrackPolicy {
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
    @discardableResult
    static func removeVideos(
        knownVideoIDs: Set<String> = [],
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws -> Int {
        let videos = try TrackRecordRepository.allTracks(in: context).filter { track in
            VideoTrackPolicy.isVideo(playbackData: track.musicKitPlaybackData)
                || !knownVideoIDs.isDisjoint(with:
                    [track.catalogID, track.libraryID].compactMap { $0 } + track.identityAliases)
        }
        guard !videos.isEmpty else { return 0 }
        let trackIDs = Set(videos.map(\.id))
        let localIDs = Set(trackIDs.map(\.uuidString))
        let musicIDs = Set(videos.flatMap {
            [$0.catalogID, $0.libraryID].compactMap { $0 } + $0.identityAliases
        })
        // UUID references are not SwiftData relationships, so remove dependents explicitly.
        for item in try PlaylistItemRepository.allItems(in: context) where trackIDs.contains(item.trackID) {
            context.delete(item)
        }
        for event in try context.fetch(FetchDescriptor<HistoryEvent>()) {
            if let trackID = event.trackID, trackIDs.contains(trackID) { context.delete(event) }
        }
        for video in videos { context.delete(video) }
        try context.save()

        if let state = LocalPlaybackStateStore.load(from: defaults),
           localIDs.contains(state.localTrackID ?? "") || musicIDs.contains(state.musicItemID) {
            LocalPlaybackStateStore.clear(from: defaults, flushImmediately: true)
        }
        if let waypoint = PlaybackWaypointStore.load(from: defaults), localIDs.contains(waypoint.localTrackID) {
            PlaybackWaypointStore.clear(from: defaults, flushImmediately: true)
        }
        return videos.count
    }
}
