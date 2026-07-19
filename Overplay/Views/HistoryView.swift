import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    // Events are loaded in bounded, predicate-filtered pages — the event
    // log grows with every playback transition, so the view must never
    // materialize all of it (an unbounded @Query did exactly that).
    @State private var events: [HistoryEvent] = []
    @State private var hasMoreEvents = false
    @State private var eventLimit = EventRepository.historyPageSize
    @State private var recoveredEvents: [HistoryEvent] = []
    @State private var reloadToken = 0
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

            Section {
                ReconciliationEffectivenessView(summary: reconciliationSummary)
            } header: {
                Text("Suspended Playback Recovery")
            } footer: {
                Text("These are playthroughs completed while Overplay was suspended and written when reconciliation next ran. Each playthrough is attributed to the evidence that made the recovery possible.")
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
                    reloadToken += 1
                }
            }

            if hasMoreEvents {
                Button("Show More") {
                    eventLimit += EventRepository.historyPageSize
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
            reloadHistoryData()
        }
        .onChange(of: viewModel.selectedFilter) {
            eventLimit = EventRepository.historyPageSize
        }
    }

    private var historyDataKey: String {
        "\(viewModel.selectedFilter.rawValue)-\(eventLimit)-\(reloadToken)-\(playbackController.playbackItemMetadataVersion)"
    }

    private var rows: [HistoryEventRowModel] {
        viewModel.rows(
            events: events,
            playlists: playlists,
            tracks: tracks
        )
    }

    private var reconciliationSummary: HistoryReconciliationSummary {
        viewModel.reconciliationSummary(events: recoveredEvents)
    }

    private var emptyTitle: String {
        viewModel.emptyTitle
    }

    private func restorableItem(for row: HistoryEventRowModel) -> PlaylistItemRecord? {
        viewModel.restorableItem(for: row, playlistItems: playlistItems)
    }

    private func reloadHistoryData() {
        let page = try? EventRepository.recentEvents(
            matching: viewModel.selectedFilter,
            limit: eventLimit,
            in: modelContext
        )
        events = page?.events ?? []
        hasMoreEvents = page?.hasMore ?? false
        recoveredEvents = (try? EventRepository.recoveredPlaythroughEvents(in: modelContext)) ?? []

        let playlistIDs = Array(Set(events.compactMap(\.playlistID)))
        let trackIDs = Array(Set(events.compactMap(\.trackID)))

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

        if let reconciliationMechanismTitle = row.reconciliationMechanismTitle {
            HistoryBadgeView(text: reconciliationMechanismTitle)
        }

        if let skipCountText = row.skipCountText {
            HistoryBadgeView(text: skipCountText)
        }

        if let remoteMutationStatusText = row.remoteMutationStatusText {
            HistoryBadgeView(text: remoteMutationStatusText)
        }
    }
}

private struct ReconciliationEffectivenessView: View {
    var summary: HistoryReconciliationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                ReconciliationMetricView(
                    value: summary.totalRecoveredPlaythroughs,
                    label: "Recovered total"
                )
                ReconciliationMetricView(
                    value: summary.recoveredLastSevenDays,
                    label: "Last 7 days"
                )
            }

            if summary.totalRecoveredPlaythroughs == 0 {
                Text("No suspended playthroughs have needed recovery yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(summary.mechanismCounts) { mechanismCount in
                        ReconciliationMechanismRowView(
                            mechanismCount: mechanismCount,
                            total: summary.totalRecoveredPlaythroughs
                        )
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ReconciliationMetricView: View {
    var value: Int
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ReconciliationMechanismRowView: View {
    var mechanismCount: HistoryReconciliationMechanismCount
    var total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(mechanismCount.title, systemImage: mechanismCount.systemImage)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(mechanismCount.count, format: .number)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            ProgressView(
                value: Double(mechanismCount.count),
                total: Double(max(total, 1))
            )
            .tint(tint)

            Text(mechanismCount.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        switch mechanismCount.mechanism {
        case .pointObservation:
            .blue
        case .wallClockContinuity:
            .orange
        case .musicKitPlayCount:
            .pink
        case nil:
            .gray
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
