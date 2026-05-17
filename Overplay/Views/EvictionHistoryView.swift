import SwiftData
import SwiftUI

struct EvictionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedTrack.title) private var tracks: [TrackedTrack]
    @State private var message: String?

    var body: some View {
        List {
            if evictedTracks.isEmpty {
                ContentUnavailableView(
                    "No Evictions",
                    systemImage: "checkmark.seal",
                    description: Text("Tracks evicted locally by Overplay will appear here.")
                )
            }

            ForEach(evictedTracks) { track in
                HStack(spacing: 12) {
                    ArtworkView(urlString: track.artworkURLTemplate, cornerRadius: 8)
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.headline)
                        Text(track.artistName)
                            .foregroundStyle(.secondary)
                        if let reason = track.evictionReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if let evictedAt = track.evictedAt {
                            Text(evictedAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Button("Restore") {
                        restore(track)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 6)
            }

            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Eviction History")
    }

    private var evictedTracks: [TrackedTrack] {
        tracks
            .filter(\.isEvicted)
            .sorted { ($0.evictedAt ?? .distantPast) > ($1.evictedAt ?? .distantPast) }
    }

    private func restore(_ track: TrackedTrack) {
        EvictionEngine.restore(track, context: modelContext)
        do {
            try modelContext.save()
            message = "Restored \(track.title)."
        } catch {
            message = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        EvictionHistoryView()
    }
    .modelContainer(PreviewContainer.make())
}
