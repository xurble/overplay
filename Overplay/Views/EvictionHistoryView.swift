import SwiftData
import SwiftUI

typealias EvictionHistoryView = HistoryView

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var events: [HistoryEvent]
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \TrackRecord.title) private var tracks: [TrackRecord]

    @State private var selectedFilter = HistoryEventFilter.all
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Picker("History Filter", selection: $selectedFilter) {
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
                    restore(row)
                }
            }

            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("History")
    }

    private var rows: [HistoryEventRowModel] {
        HistoryTimeline.rows(
            events: events,
            playlists: playlists,
            tracks: tracks,
            filter: selectedFilter
        )
    }

    private var emptyTitle: String {
        selectedFilter == .all ? "No History" : "No \(selectedFilter.title)"
    }

    private func restorableItem(for row: HistoryEventRowModel) -> PlaylistItemRecord? {
        guard let playlistID = row.playlistID, let trackID = row.trackID else {
            return nil
        }

        return playlistItems.first {
            $0.playlistID == playlistID
                && $0.trackID == trackID
                && ($0.evictedAt != nil || $0.removedFromRemoteAt != nil)
        }
    }

    private func playlist(for item: PlaylistItemRecord) -> PlaylistRecord? {
        playlists.first { $0.id == item.playlistID }
    }

    private func restore(_ row: HistoryEventRowModel) {
        guard let item = restorableItem(for: row) else { return }
        EvictionEngine.restore(item, playlist: playlist(for: item), context: modelContext)

        do {
            try modelContext.save()
            message = "Restored \(row.trackTitle)."
        } catch {
            message = error.localizedDescription
        }
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
    .modelContainer(PreviewContainer.make())
}
