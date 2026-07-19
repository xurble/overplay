import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("History view model")
struct HistoryViewModelTests {
    @Test("rows use selected filter and empty title reflects filter")
    func rowsUseSelectedFilterAndEmptyTitleReflectsFilter() {
        let playlistID = UUID()
        let trackID = UUID()
        let viewModel = HistoryViewModel()
        viewModel.selectedFilter = .evictions
        let events = [
            HistoryEvent(playlistID: playlistID, trackID: trackID, eventType: .evicted, source: .playback),
            HistoryEvent(playlistID: playlistID, trackID: trackID, eventType: .promoted, source: .user)
        ]

        let rows = viewModel.rows(events: events, playlists: [], tracks: [])

        #expect(rows.map(\.eventType) == [.evicted])
        #expect(viewModel.emptyTitle == "No Retired")
    }

    @Test("reconciliation summary is independent of timeline filter")
    func reconciliationSummaryIsIndependentOfTimelineFilter() {
        let viewModel = HistoryViewModel()
        viewModel.selectedFilter = .evictions
        let event = HistoryEvent(
            eventType: .playthrough,
            source: .reconciled,
            reconciliationMechanism: .musicKitPlayCount
        )

        let summary = viewModel.reconciliationSummary(events: [event])

        #expect(summary.totalRecoveredPlaythroughs == 1)
        #expect(summary.mechanismCounts.first { $0.mechanism == .musicKitPlayCount }?.count == 1)
    }

    @Test("restorable item requires matching evicted playlist item")
    func restorableItemRequiresMatchingEvictedPlaylistItem() {
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let track = TrackRecord(title: "Track", artistName: "Artist")
        let evictedItem = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, evictedAt: .now)
        let activeItem = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID())
        let event = HistoryEvent(playlistID: playlist.id, trackID: track.id, eventType: .evicted, source: .playback)
        let row = HistoryTimeline.rows(events: [event], playlists: [playlist], tracks: [track]).first!
        let viewModel = HistoryViewModel()

        let item = viewModel.restorableItem(for: row, playlistItems: [activeItem, evictedItem])

        #expect(item?.id == evictedItem.id)
    }

    @Test("restore invokes dependency and reports success")
    func restoreInvokesDependencyAndReportsSuccess() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let track = TrackRecord(title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, evictedAt: .now)
        let event = HistoryEvent(playlistID: playlist.id, trackID: track.id, eventType: .evicted, source: .playback)
        let row = HistoryTimeline.rows(events: [event], playlists: [playlist], tracks: [track]).first!
        let viewModel = HistoryViewModel()
        var restoredItemID: UUID?
        var restoredPlaylistID: UUID?
        let dependencies = HistoryViewModel.Dependencies { item, playlist, _ in
            restoredItemID = item.id
            restoredPlaylistID = playlist?.id
        }

        viewModel.restore(
            row,
            playlistItems: [item],
            playlists: [playlist],
            context: context,
            dependencies: dependencies
        )

        #expect(restoredItemID == item.id)
        #expect(restoredPlaylistID == playlist.id)
        #expect(viewModel.message == "Restored Track.")
    }

    @Test("restore failure reports error")
    func restoreFailureReportsError() throws {
        struct Failure: LocalizedError {
            var errorDescription: String? { "Restore failed." }
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let track = TrackRecord(title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, evictedAt: .now)
        let event = HistoryEvent(playlistID: playlist.id, trackID: track.id, eventType: .evicted, source: .playback)
        let row = HistoryTimeline.rows(events: [event], playlists: [playlist], tracks: [track]).first!
        let viewModel = HistoryViewModel()
        let dependencies = HistoryViewModel.Dependencies { _, _, _ in
            throw Failure()
        }

        viewModel.restore(
            row,
            playlistItems: [item],
            playlists: [playlist],
            context: context,
            dependencies: dependencies
        )

        #expect(viewModel.message == "Restore failed.")
    }
}
