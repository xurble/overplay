import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query(sort: \HistoryEvent.createdAt, order: .reverse) private var events: [HistoryEvent]
    @State private var playlists: [PlaylistRecord] = []
    @State private var playlistItems: [PlaylistItemRecord] = []
    @State private var tracks: [TrackRecord] = []

    @State private var viewModel = HistoryViewModel()

    var body: some View {
        List {
            Section {
                Picker("History Filter", selection: $viewModel.selectedFilter) {
                    ForEach(HistoryEventFilter.allCases) { filter in
                        Text(filter.title)
                            .tag(filter)
                    }
                }
                .pickerStyle(.menu)
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Playback, promotion, removal, restore, and remote mutation events will appear here.")
                )
            }

            ForEach(rows) { row in
                HistoryEventRowView(row: row, canRestore: restorableItem(for: row) != nil) {
                    viewModel.restore(
                        row,
                        playlistItems: playlistItems,
                        playlists: playlists,
                        context: modelContext,
                        dependencies: dependencies
                    )
                }
            }

            if let message = viewModel.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("History")
        .task(id: historyDataKey) {
            reloadHistoryReferenceData()
        }
    }

    private var historyDataKey: String {
        "\(viewModel.selectedFilter.rawValue)-\(events.count)-\(events.first?.id.uuidString ?? "")"
    }

    private var rows: [HistoryEventRowModel] {
        viewModel.rows(
            events: events,
            playlists: playlists,
            tracks: tracks
        )
    }

    private var emptyTitle: String {
        viewModel.emptyTitle
    }

    private func restorableItem(for row: HistoryEventRowModel) -> PlaylistItemRecord? {
        viewModel.restorableItem(for: row, playlistItems: playlistItems)
    }

    private func reloadHistoryReferenceData() {
        let filteredEvents = events.filter { viewModel.selectedFilter.includes($0) }
        let playlistIDs = Array(Set(filteredEvents.compactMap(\.playlistID)))
        let trackIDs = Array(Set(filteredEvents.compactMap(\.trackID)))

        playlists = playlistIDs.compactMap { playlistID in
            try? PlaylistRepository.playlist(id: playlistID, in: modelContext)
        }
        tracks = (try? TrackRecordRepository.tracks(ids: trackIDs, in: modelContext)) ?? []
        playlistItems = (try? PlaylistItemRepository.items(forPlaylistIDs: playlistIDs, in: modelContext)) ?? []
    }

    private var dependencies: HistoryViewModel.Dependencies {
        .live(playbackController: playbackController)
    }
}

private struct HistoryEventRowView: View {
    var row: HistoryEventRowModel
    var canRestore: Bool
    var restore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(urlString: row.artworkURLTemplate, cornerRadius: 8)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(row.eventTitle, systemImage: row.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(row.createdAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(row.trackTitle)
                    .font(.headline)

                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HistoryEventBadgesView(row: row)

                if let message = row.message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if canRestore {
                Button("Restore", action: restore)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct HistoryEventBadgesView: View {
    var row: HistoryEventRowModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                badges
            }

            VStack(alignment: .leading, spacing: 4) {
                badges
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        HistoryBadgeView(text: row.sourceTitle)

        if let skipCountText = row.skipCountText {
            HistoryBadgeView(text: skipCountText)
        }

        if let remoteMutationStatusText = row.remoteMutationStatusText {
            HistoryBadgeView(text: remoteMutationStatusText)
        }
    }
}

private struct HistoryBadgeView: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
