import SwiftUI

struct PlaylistTrackRowView: View {
    var summary: TrackSummaryPresentation
    var playlistID: String
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    urlString: summary.artworkURLString,
                    pixelSize: 128,
                    playlistID: playlistID,
                    cornerRadius: 0
                )
                .frame(width: 72, height: 72)

                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.green, in: Circle())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TrackRowText(candidates: TrackTextVariants.candidates(for: summary.title))
                    .font(.headline)
                    .foregroundStyle(summary.isPlayable ? .primary : .secondary)
                HStack(alignment: .top, spacing: 8) {
                    TrackRowText(
                        candidates: TrackTextVariants.candidates(
                            for: [summary.artistName, summary.albumTitle].compactMap { value in
                                guard let value, !value.isEmpty else { return nil }
                                return value
                            },
                            separator: " - "
                        ),
                        lineLimit: 2
                    )
                    Text(summary.playSkipMetricLabel)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help("Plays: Overplay / Apple Music")
                        .accessibilityLabel(PlayCountPresentation.accessibilityLabel(
                            overplay: summary.playthroughCount, apple: summary.applePlayCount, skips: summary.skipCount
                        ))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let provenanceText = summary.provenanceText {
                    Text(provenanceText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    PlaylistTrackRowView(
        summary: TrackSummaryPresentation(
            id: UUID(),
            title: "Soft Machine",
            artistName: "Glass Coast",
            albumTitle: "Late Light",
            artworkURLString: nil,
            skipCount: 2,
            isPlayable: true
        ),
        playlistID: "preview-playlist",
        isCurrent: true
    )
    .padding()
}
