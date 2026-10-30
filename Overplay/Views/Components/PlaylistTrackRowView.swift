import SwiftUI

struct PlaylistTrackRowView: View {
    var summary: TrackSummaryPresentation
    var playlistID: String
    var isCurrent: Bool
    /// Off for an album's songs, which all share the album's artwork: the
    /// playing badge keeps a slot of its own at the leading edge.
    var showsArtwork = true

    var body: some View {
        HStack(spacing: 12) {
            if showsArtwork {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkView(
                        urlString: summary.artworkURLString,
                        pixelSize: 128,
                        playlistID: playlistID,
                        cornerRadius: 0
                    )
                    .frame(width: 72, height: 72)

                    if isCurrent {
                        NowPlayingBadgeView()
                            .padding(3)
                    }
                }
            } else {
                ZStack {
                    if isCurrent { NowPlayingBadgeView() }
                }
                .frame(width: 24)
                .padding(.leading, 12)
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
                    if summary.isTracked {
                        Text(summary.playSkipMetricLabel)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .help("Plays: the higher of Overplay’s and Apple Music’s")
                            .accessibilityLabel(PlayCountPresentation.accessibilityLabel(
                                overplay: summary.playthroughCount, apple: summary.applePlayCount, skips: summary.skipCount
                            ))
                    }
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
        .accessibilityElement(children: .combine)
        .accessibilityValue(summary.isPlayable ? "" : "Unavailable")
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
