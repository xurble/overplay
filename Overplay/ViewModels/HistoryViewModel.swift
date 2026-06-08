import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class HistoryViewModel {
    struct Dependencies {
        var restoreTrack: (PlaylistItemRecord, PlaylistRecord?, ModelContext) throws -> Void

        static let live = Self { item, playlist, context in
            try TrackHealthActionService.restoreTrack(item, playlist: playlist, in: context)
        }
    }

    var selectedFilter = HistoryEventFilter.all
    var message: String?

    func rows(
        events: [HistoryEvent],
        playlists: [PlaylistRecord],
        tracks: [TrackRecord]
    ) -> [HistoryEventRowModel] {
        HistoryTimeline.rows(
            events: events,
            playlists: playlists,
            tracks: tracks,
            filter: selectedFilter
        )
    }

    var emptyTitle: String {
        selectedFilter == .all ? "No History" : "No \(selectedFilter.title)"
    }

    func restorableItem(
        for row: HistoryEventRowModel,
        playlistItems: [PlaylistItemRecord]
    ) -> PlaylistItemRecord? {
        guard let playlistID = row.playlistID, let trackID = row.trackID else {
            return nil
        }

        return playlistItems.first {
            $0.playlistID == playlistID
                && $0.trackID == trackID
                && $0.evictedAt != nil
        }
    }

    func restore(
        _ row: HistoryEventRowModel,
        playlistItems: [PlaylistItemRecord],
        playlists: [PlaylistRecord],
        context: ModelContext,
        dependencies: Dependencies = .live
    ) {
        guard let item = restorableItem(for: row, playlistItems: playlistItems) else { return }

        do {
            try dependencies.restoreTrack(item, playlist(for: item, playlists: playlists), context)
            message = "Restored \(row.trackTitle)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func playlist(
        for item: PlaylistItemRecord,
        playlists: [PlaylistRecord]
    ) -> PlaylistRecord? {
        playlists.first { $0.id == item.playlistID }
    }
}
